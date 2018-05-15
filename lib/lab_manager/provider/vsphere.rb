require 'fog'
require 'lab_manager/provider/vsphere_config'
require 'connection_pool'
require 'securerandom'
require 'retryable'
require 'active_support/hash_with_indifferent_access'
require 'lab_manager/named_stringio'

module Provider
  # VSphere provider implementation
  class VSphere
    RETRYABLE_CALLBACK = lambda do |ex|
      LabManager.logger.warn "Exception occured in retryable: #{ex}"
    end

    class << self
      def connect
        @vspehre ||= ConnectionPool.new(
          size: VSphereConfig.connection_pool.size,
          timeout: VSphereConfig.connection_pool.timeout
        ) do
          Fog::Compute.new(
            { provider: :vsphere }.merge(VSphereConfig.connection)
          )
        end
      end

      # This fucntion handles the possibility that the connection
      # might not be used for a long time and thus another usage
      # throws a "not authenticated" exception
      def with_connection
        connect.with do |conn|
          begin
            conn.current_time
          rescue RbVmomi::Fault, Errno::EPIPE, EOFError
            LabManager.logger.warn("Connection isn't working, created new one")
            conn = Fog::Compute.new( { provider: :vsphere }.merge(VSphereConfig.connection) )
          end
          yield conn
        end
      end

      def filter_machines_to_be_scheduled(
        created_machines: Compute.created.where(provider_name: 'v_sphere'),
        alive_machines: Compute.alive_vm.where(provider_name: 'v_sphere').order(:created_at),
        errored_machines: Compute.where(state: 'errored')
      )
        alive_with_errored = alive_machines.count + errored_machines.count

        limit = [0, VSphereConfig.scheduler.max_vm - alive_with_errored].max

        LabManager.logger.warn "allowed to be scheduled: #{limit}"
        LabManager.logger.warn("alive_machines: #{alive_machines.count}, created_machines: #{created_machines.count}, errored_machines: #{errored_machines.count}")

        created_machines.limit(limit)
      end
    end

    # custom exception raised when VmWare task to add machine to drs rule fails
    class SetDrsGroupError < RuntimeError
    end

    class CreateVMError < RuntimeError
    end

    class PowerOnError < RuntimeError
    end

    class TerminateVmError < RuntimeError
    end

    class ShutdownVmError < RuntimeError
    end

    class ArgumentError < ArgumentError
    end

    class VmNotExistsError < RuntimeError
    end

    class RebootVmError < RuntimeError
    end

    class SetupNetworkArgumentError < ArgumentError
    end

    attr_accessor :compute

    def initialize(compute)
      @compute = compute
    end

    def create_vm_options
      compute.create_vm_options
    end

    def setup_network_interfaces(opts)
      fail SetupNetworkArgumentError, "parameter is nil" unless opts
      %w{uuid network_name connection}.each do |required|
        fail SetupNetworkArgumentError, "argument #{required} not given " unless opts.key? required.to_sym
      end

      conn = opts[:connection].instance_variable_get('@connection'.to_sym)
      vm_mob_ref = conn.searchIndex.FindByUuid({
        :uuid => opts[:uuid],
        :vmSearch => true
      })

      vm_mob_ref.config.hardware.device.select do |vm_device|
        vm_device.class == RbVmomi::VIM::VirtualE1000 ||
        vm_device.class == RbVmomi::VIM::VirtualE1000e ||
        vm_device.class == RbVmomi::VIM::VirtualPCNet32 ||
        vm_device.class == RbVmomi::VIM::VirtualVmxnet ||
        vm_device.class == RbVmomi::VIM::VirtualVmxnet2 ||
        vm_device.class == RbVmomi::VIM::VirtualVmxnet3
      end.each do |device|

        device.backing = RbVmomi::VIM::VirtualEthernetCardNetworkBackingInfo(
          :deviceName => opts[:network_name]
        )
        config_spec = RbVmomi::VIM.VirtualDeviceConfigSpec(
          :operation => RbVmomi::VIM::VirtualDeviceConfigSpecOperation('edit'),
          :device => device
        )
        machine_config_spec = RbVmomi::VIM.VirtualMachineConfigSpec(
          :deviceChange => [config_spec]
        )
        vm_mob_ref.ReconfigVM_Task(
          :spec => machine_config_spec
        ).wait_for_completion()
      end
    end

    # TODO: what parameters are mandatory?
    # whould be nice to be able to validate before sending a request
    def create_vm(opts = {})
      opts = opts.with_indifferent_access.reverse_merge(
        VSphereConfig.create_vm_defaults.symbolize_keys || {}
      )

      opts[:template_path] = compute.image if compute.image

      VSphere.with_connection do |vs|
        dest_folder = opts[:dest_folder]
        vm_name = opts[:name] || "#{compute.image}-"\
          "#{SecureRandom.hex(4)}-#{Time.new.strftime("%Y%m%d")}"
        exception_cb = lambda do |_p1|
          LabManager.logger.warn(
            "Failed attempt to create virtual machine:  template_name: #{opts[:template_path]}"\
              ", vm_name: #{vm_name}"
          )
        end

        Retryable.retryable(
          tries: VSphereConfig.create_vm_defaults[:vm_clone_retry_count],
          on: [RbVmomi::Fault, CreateVMError, Fog::Compute::Vsphere::NotFound],
          exception_cb: exception_cb,
          sleep: ->(n) { Random.rand(n*3..n*3+10.0) }
        ) do
          LabManager.logger.info "creating machine with name: #{vm_name} options: #{opts.inspect}"
          machine = vs.vm_clone(
            'datacenter'    => opts[:datacenter],
            'datastore'     => opts[:datastore],
            'template_path' => opts[:template_path],
            'name'          => vm_name,
            'cluster'       => opts[:cluster],
            'linked_clone'  => opts[:linked_clone],
            'dest_folder'   => dest_folder,
            'power_on'      => opts[:power_on],
            'wait'          => true
          )

          setup_network_interfaces({
            uuid: machine['new_vm']['uuid'],
            connection: vs,
            network_name: VSphereConfig.create_vm_defaults[:network_interface_name]
          })

          fail CreateVMError, "Creation of (#{vm_name}) machine failed, retrying" unless machine || machine['vm_ref']
          set_provider_data(machine['new_vm'], vs: vs)
        end

        add_machine_to_drs_rule(
          vs,
          group: opts[:add_to_drs_group],
          machine: "#{dest_folder}/#{vm_name}",
          datacenter: opts[:datacenter]
        ) if opts[:add_to_drs_group]
      end
      poweron_vm unless  compute.provider_data['power_state'] == 'poweredOn'
    rescue
      # Try to free unsuccessfully started/configured/... VM
      begin
        terminate_vm
      rescue
        nil
      end if instance_uuid
      raise
    end

    def terminate_vm(_opts = {})
      fail ArgumentError, 'Virtual machine data not present' unless instance_uuid

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
          break unless server
          result = server.destroy['task_state']
          fail TerminateVmError, 'unexpected state: #{result}' unless
            result == 'success'
        end
      end
    end

    def poweron_vm
      fail ArgumentError, 'Virtual machine data not present' unless instance_uuid

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          task_result =  vs.vm_power_on(
            'instance_uuid' => instance_uuid
          )['task_state']
          fail PowerOnError, "Power-on task finished in state: #{task_result}" unless
            task_result == 'success'
        end
        set_provider_data(nil, vs: vs)
      end
    end

    def shutdown_vm(opts = {})
      fail ArgumentError, 'Virtual machine data not present' unless instance_uuid

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 6, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
          fail VmNotExistsError, 'Vm not exists!' unless server
          break if server.power_state == 'poweredOff'

          mode = opts && opts[:mode] ? opts[:mode] : 'managed'
          case mode
          when 'hard'
            server.stop(force: true)
          when 'soft'
            server.stop(force: false)
          when 'managed'
            begin
              server.stop(force: false)
            rescue => e
              LabManager.logger.warn 'The graceful shut down of the machine failed, '\
                "trying force off, #{e}"
              server.stop(force: true)
            end
          else
            fail ShutdownVmError, "Wrong mode specified: #{opts[:mode]}"
          end

          Retryable.retryable(tries: 23, sleep: 2) do
            fail ShutdownVmError, 'Waiting for finish of the shutdown command'\
              ' was not successful' unless
                vs.get_virtual_machine(server.id)['power_state'] == 'poweredOff'
          end
        end

        set_provider_data(nil, vs: vs)
      end
    end

    def reboot_vm(opts = {})
      fail ArgumentError, 'Virtual machine data not present' unless instance_uuid

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
          fail VmNotExistsError, 'Vm not exists!' unless server

          mode = opts[:mode] || 'managed'
          case mode
          when 'hard'
            server.reboot(instance_uuid: instance_uuid, force: true)
          when 'soft'
            server.reboot(instance_uuid: instance_uuid, force: false)
          when 'managed'
            begin
              server.reboot(instance_uuid: instance_uuid, force: false)
            rescue => e
              LabManager.logger.warn 'The graceful rebooting of the machine failed, '\
                "trying force reboot, #{e}"
              server.reboot(instance_uuid: instance_uuid, force: true)
            end
          else
            fail RebootVmError, "Reboot error, wrong mode: #{opts[:mode]}"
          end
        end
      end
    end

    def execute_vm(opts)
      opts = opts.with_indifferent_access
      fail ArgumentError, 'Virtual machine data not present' unless instance_uuid
      fail ArgumentError, 'user must be specified' unless opts[:user]
      fail ArgumentError, 'password must be specified' unless opts[:password]
      fail ArgumentError, 'command must be specified' unless opts[:command]

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          unless opts[:async]
            fail 'not implemented yet'
          else
            vs.vm_execute(
              'instance_uuid' => instance_uuid,
              'command' => opts[:command],
              'user' => opts[:user],
              'password' => opts[:password],
              'args' => opts[:args],
              'working_dir' => opts[:working_dir]
            )
          end
        end
      end
    end

    def upload_file_vm(opts)
      opts = opts.with_indifferent_access
      failed_opts = []
      failed_opts.push('Virtual machine data not present') unless instance_uuid
      failed_opts.push('user must be specified') unless opts[:user]
      failed_opts.push('password must be specified') unless opts[:password]
      failed_opts.push('guest_file_path must be specified') unless opts[:guest_file_path]
      failed_opts.push('host_file must be specified') unless opts[:host_file]
      fail ArgumentError, failed_opts.join(', ') unless failed_opts.empty?

      upload_file_impl(opts)
    end

    def download_file_vm(opts)
      opts = opts.with_indifferent_access
      failed_opts = []
      failed_opts.push('Virtual machine data not present') unless instance_uuid
      failed_opts.push('user must be specified') unless opts[:user]
      failed_opts.push('password must be specified') unless opts[:password]
      failed_opts.push('guest_file_path must be specified') unless opts[:guest_file_path]
      fail ArgumentError, failed_opts.join(', ') unless failed_opts.empty?

      download_file_impl(opts)
    end

    def take_snapshot_vm(opts)
      opts = opts.with_indifferent_access
      fail ArgumentError, 'Snapshot name must be specified' unless opts[:name]

      server = nil
      result_snapshot = nil

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
          server.take_snapshot(opts)
        end
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          # TODO: we need to implement fog-vsphere #snapshot.get(name: name)
          # for fasteer
          result_snapshot = server.snapshots.all(recursive: true).find do |t|
            t.name == opts[:name]
          end
        end
      end

      return nil unless result_snapshot

      {
        name: result_snapshot.name,
        ref: result_snapshot.ref,
        quiesced: result_snapshot.quiescedi,
        description: result_snapshot.description,
        create_time: result_snapshot.create_time,
        power_state: result_snapshot.power_state,
        ref: result_snapshot.ref,
        snapshot_name_chain: result_snapshot.snapshot_name_chain,
        ref_chain: result_snapshot.ref_chain
      }
    end

    def revert_snapshot_vm(opts)
      opts = opts.with_indifferent_access
      fail ArgumentError, 'Snapshot name must be specified' unless opts[:name]
      server = nil
      snapshot = nil
      VSphere.with_connection do |vs|

        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
        end

        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          snapshot = server.snapshots.all(recursive: true).find do |t|
            t.name == opts[:name]
          end
        end
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server.revert_snapshot(snapshot)
          set_provider_data(nil, vs: vs)
        end
      end
    end

    def processes_vm(opts)
      opts = opts.with_indifferent_access
      fail ArgumentError, 'user must be specified' unless opts[:user]
      fail ArgumentError, 'password must be specified' unless opts[:password]

      server = nil
      result = nil

      VSphere.with_connection do |vs|
        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          server = vs.servers.get(instance_uuid)
        end

        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          result = server.guest_processes(opts)
        end
      end

      result
    end

    def instance_uuid
      (compute.provider_data || {})['id']
    end

    def vm_data(vm_instance_data = nil, full: false, vs: nil)
      data_proc = lambda do |vs_|
        net_info = []
        if compute.provider_data && compute.provider_data['uuid']
          conn = vs_.instance_variable_get('@connection'.to_sym)
          vm = conn.searchIndex.FindByUuid({ uuid: compute.provider_data['uuid'], vmSearch: true })
          net_info = vm.guest.net.map do |net|
            {
              network: net.network,
              connected: net.connected,
              device_config_id: net.deviceConfigId,
              ip_addresses: net.ipConfig.ipAddress.each_with_object({}) do |ip, result|
                key = IPAddr.new(ip.ipAddress).ipv4? ? 'ipv4' : 'ipv6'
                result[key] ||= []
                result[key] << ip.ipAddress
                result
              end
            }
          end
        end

        vm_instance_data ||= vs_.get_virtual_machine(compute.provider_data['id'])
        vm_instance_data.each_with_object({}) do |(k, v), s|
          s[k] = case v
                 when Proc then full ? v.call : nil
                 when String then v
                 end
        end.merge(network_info: net_info)
      end

      if vs
        data_proc.call(vs)
      else
        VSphere.with_connection(&data_proc)
      end
    end

    def set_provider_data(vm_instance_data = nil, full: false, vs: nil)
      if vm_instance_data.nil?
        begin
          return compute.provider_data unless compute.provider_data.include? 'id'
          Retryable.retryable(
            tries: 3,
            sleep: 5,
            exception_cb: Provider::VSphere::RETRYABLE_CALLBACK,
            on: Fog::Compute::Vsphere::NotFound
          ) do
            compute.provider_data = vm_data(vm_instance_data, vs: vs, full: full)
          end
        rescue Fog::Compute::Vsphere::NotFound
          nil
        end
      else
        compute.provider_data = vm_data(vm_instance_data, vs: vs, full: full)
      end
    end

    def vm_state
      set_provider_data
      case compute.provider_data['power_state'].downcase
      when 'poweredon'
        return :power_on
      when 'poweredoff'
        return :power_off
      end

      fail 'Error, unexpected state of machine: '\
        "compute_id=#{compute.id}, vsphere_uuid=#{instance_uuid}"
    end

    private

    def add_machine_to_drs_rule(vs, group:, machine:, datacenter:)
      Retryable.retryable(tries: 5, on: SetDrsGroupError, exception_cb: RETRYABLE_CALLBACK) do
        add_machine_to_drs_rule_impl(vs, group: group, machine: machine, datacenter: datacenter)
        fail SetDrsGroupError, "Cannot set machine #{machine} to drsGroup #{group}" unless
          machine_present_in_drs_rule?(vs, group: group, machine: machine, datacenter: datacenter)
      end
    end

    def add_machine_to_drs_rule_impl(vs, group:, machine:, datacenter:)
      conn = vs.instance_variable_get('@connection'.to_sym)
      dc = conn.serviceInstance.find_datacenter(datacenter)
      vm = dc.find_vm(machine)
      cluster = vm.runtime.host.parent

      group = cluster.configurationEx.group.find { |g| g.name == group }
      vms = group.vm.each_with_object([vm]) do |v, res|
        res << v
      end
      group.vm = vms
      cluster_group_spec = RbVmomi::VIM.ClusterGroupSpec(
        operation: RbVmomi::VIM.ArrayUpdateOperation('edit'),
        info: group
      )

      cluster.ReconfigureComputeResource_Task(
        spec: RbVmomi::VIM.ClusterConfigSpecEx(groupSpec: [cluster_group_spec]),
        modify: true
      ).wait_for_completion
    end

    def machine_present_in_drs_rule?(vs, group:, machine:, datacenter:)
      conn = vs.instance_variable_get('@connection'.to_sym)
      dc = conn.serviceInstance.find_datacenter(datacenter)
      vm = dc.find_vm(machine)
      cluster = vm.runtime.host.parent

      group = cluster.configurationEx.group.find { |g| g.name == group }
      machine_short_name = machine.sub!(%r{^.*\/}, '')
      !(group.vm.find { |v| v.name == machine_short_name }).nil?
    end

    def download_file_impl(opts)
      VSphere.with_connection do |vs|
        conn = vs.instance_variable_get('@connection'.to_sym)

        auth = RbVmomi::VIM::NamePasswordAuthentication(
          username: opts[:user],
          password: opts[:password],
          interactiveSession: false
        )

        file_manager = conn.serviceContent.guestOperationsManager.fileManager

        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          file_info = file_manager.InitiateFileTransferFromGuest(
            vm: vm_data['mo_ref'],
            auth: auth,
            guestFilePath: opts[:guest_file_path]
          )

          uri = URI.parse(file_info.url)

          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: VSphereConfig.guest_operations[:use_ssl] || true,
            verify_mode: VSphereConfig.guest_operations[:verify_mode].constantize ||
              OpenSSL::SSL::VERIFY_NONE
          ) do |http|
            req = Net::HTTP::Get.new(uri)
            res = http.request req

            unless Net::HTTPSuccess === res
              fail "Error: #{res.inspect} :: retrieving via #{uri}"
            end

            NamedStringIO.new('tempfile', res.body)
          end
        end
      end
    end

    def upload_file_impl(opts)
      VSphere.with_connection do |vs|
        conn = vs.instance_variable_get('@connection'.to_sym)

        auth = RbVmomi::VIM::NamePasswordAuthentication(
          username: opts[:user],
          password: opts[:password],
          interactiveSession: false
        )

        file_manager = conn.serviceContent.guestOperationsManager.fileManager

        Retryable.retryable(tries: 3, exception_cb: RETRYABLE_CALLBACK) do
          endpoint = file_manager.InitiateFileTransferToGuest(
            vm: vm_data['mo_ref'],
            auth: auth,
            guestFilePath: opts[:guest_file_path],
            overwrite: opts[:overwrite] || false,
            fileAttributes: RbVmomi::VIM::GuestWindowsFileAttributes.new,
            fileSize: opts[:host_file].size
          )

          uri = URI.parse(endpoint)

          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: VSphereConfig.guest_operations[:use_ssl] || true,
            verify_mode:
              VSphereConfig.guest_operations[:verify_mode].constantize ||
                OpenSSL::SSL::VERIFY_NONE
          ) do |http|
            req = Net::HTTP::Put.new(uri)
            req.body = opts[:host_file].read
            req['Content-Type'] = 'application/octet-stream'
            req['Content-Length'] = opts[:host_file].size
            res = http.request(req)
            unless Net::HTTPSuccess === res
              fail "Error: #{res.inspect} :: #{res.body} :: sending  via #{endpoint} "\
                "with a size #{opts[:hostFile].size}"
            end
          end
        end
      end
    end
  end
end
