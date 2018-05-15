require 'ostruct'
require 'spec_helper'
require 'rbvmomi'

describe Provider::VSphere do
  let(:connection_pool_mock) { double('connection_pool_mock') }
  let(:vsphere_mock) { double('vsphere_mock') }
  let(:vm_defaults) do
    {
      linked_clone: true,
      datacenter: 'doo',
      template_path: 'aoo/boo/coo',
      dest_folder: 'zoo/xoo/coo',
      cluster: 'kokoko',
      power_on: true,
      vm_clone_retry_count: 1
    }
  end

  let(:vm_clone_response) do
    {
      'power_state' => 'poweredOn',
      'vm_ref' => 'xxxx',
      'new_vm' => { 'id' => SecureRandom.uuid }
    }
  end

  let!(:provider) do
    Provider::VSphere.new(
      build(:compute, provider_name: :v_sphere, name: 'foo', image: 'AxAA')
    )
  end

  before(:each) do
    allow(Provider::VSphere).to receive(:connect) { connection_pool_mock }
    allow(vsphere_mock).to receive(:current_time) { DateTime.now }
    allow(connection_pool_mock).to receive(:with).and_yield(vsphere_mock)
    allow(Provider::VSphereConfig).to receive(:create_vm_defaults) { vm_defaults }
  end

  describe 'with_connection' do
    it 'creates new connection automatically when RbVmomi::Fault occured' do
      allow(vsphere_mock).to receive(:current_time) { fail RbVmomi::Fault.new('foo', nil) }
      allow(vsphere_mock).to receive(:abc) { true }
      expect(Fog::Compute).to receive(:new).once { double('new_connection', abc: true) }
      Provider::VSphere.with_connection { |vs| vs.abc }
    end

    it 'creates new connection automatically when Errno::EPIPE occured' do
      allow(vsphere_mock).to receive(:current_time) { fail Errno::EPIPE }
      allow(vsphere_mock).to receive(:abc) { true }
      expect(Fog::Compute).to receive(:new).once { double('new_connection', abc: true) }
      Provider::VSphere.with_connection { |vs| vs.abc }
    end

    it 'creates new connection automatically when EOFError occured' do
      allow(vsphere_mock).to receive(:current_time) { fail EOFError }
      allow(vsphere_mock).to receive(:abc) { true }
      expect(Fog::Compute).to receive(:new).once { double('new_connection', abc: true) }
      Provider::VSphere.with_connection { |vs| vs.abc }
    end

    it 'does not create new connection automatically when other error occured' do
      allow(vsphere_mock).to receive(:current_time) { fail Exception }
      allow(vsphere_mock).to receive(:abc) { true }
      expect(Fog::Compute).to_not receive(:new) { double('new_connection', abc: true) }
      expect do
        Provider::VSphere.with_connection { |vs| vs.abc }
      end.to raise_error Exception
    end
  end

  #only basic checks for now
  describe '#setup_network_interfaces' do
    it 'fails when no uuid param is given' do
      expect do
        provider.setup_network_interfaces( network_name:'b', connection: 'c')
      end.to raise_error(Provider::VSphere::SetupNetworkArgumentError)
    end
    it 'fails when no network_name is given' do
      expect do
        provider.setup_network_interfaces( uuid:'b', connection: 'c')
      end.to raise_error(Provider::VSphere::SetupNetworkArgumentError)
    end
    it 'fails when no connection param is given' do
      expect do
        provider.setup_network_interfaces( network_name:'b', uuid: 'c')
      end.to raise_error(Provider::VSphere::SetupNetworkArgumentError)
    end
    it 'fails when no param is given at all' do
      expect do
        provider.setup_network_interfaces({})
      end.to raise_error(Provider::VSphere::SetupNetworkArgumentError)
    end
    it 'wont fail when all params are given' do
      expect do
        provider.setup_network_interfaces({
          network_name:'a',
          uuid: 'b',
          connection: 'c'
        })
      end.not_to raise_error(Provider::VSphere::SetupNetworkArgumentError)
    end
  end

  describe '#create_vm' do
    it 'arguments are propagated to fog#clone_vm' do
      args = {
        name: 'a',
        datacenter: 'b',
        template_path: 'c',
        cluster: 'd',
        linked_clone: false,
        power_on: true,
        dest_folder: 'z'
      }
      expect(vsphere_mock).to receive(:vm_clone) do |param|
        expect(param['name']).to eq args[:name]
        expect(param['datacenter']).to eq args[:datacenter]
        expect(param['template_path']).to eq 'AxAA'
        expect(param['cluster']).to eq args[:cluster]
        expect(param['linked_clone']).to eq args[:linked_clone]
        expect(param['power_on']).to eq args[:power_on]
        expect(param['dest_folder']).to eq args[:dest_folder]

        vm_clone_response
      end

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm) {}
      provider.create_vm(args)
    end

    it 'template_path argument is propagated to fog#clone_vm when compute.image is nil' do
      args = {
        name: 'a',
        datacenter: 'b',
        template_path: 'c',
        cluster: 'd',
        linked_clone: false,
        power_on: true,
        dest_folder: 'z'
      }
      expect(vsphere_mock).to receive(:vm_clone) do |param|
        expect(param['name']).to eq args[:name]
        expect(param['datacenter']).to eq args[:datacenter]
        expect(param['template_path']).to eq 'c'
        expect(param['cluster']).to eq args[:cluster]
        expect(param['linked_clone']).to eq args[:linked_clone]
        expect(param['power_on']).to eq args[:power_on]
        expect(param['dest_folder']).to eq args[:dest_folder]

        vm_clone_response
      end

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm) {}
      provider.compute.image = nil
      provider.create_vm(args)
    end

    it 'default arguments are propagated to fog#clone_vm as well' do
      expect(vsphere_mock).to receive(:vm_clone) do |param|
        expect(param['datacenter']).to eq 'doo'
        expect(param['template_path']).to eq 'AxAA'
        expect(param['cluster']).to eq 'kokoko'
        expect(param['linked_clone']).to eq true
        expect(param['power_on']).to eq true
        expect(param['dest_folder']).to eq 'zoo/xoo/coo'

        vm_clone_response
      end

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm) {}
      provider.create_vm
    end

    it 'name is generated automatically when not provided' do
      expect(vsphere_mock).to receive(:vm_clone) do |param|
        expect(param['name']).to match(/^AxAA/)

        vm_clone_response
      end

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm) {}
      provider.create_vm
    end

    it 'add_machine_to_drs_rule is called when requested' do
      allow(vsphere_mock).to receive(:vm_clone) { vm_clone_response }

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm) {}
      expect(provider).to receive(:add_machine_to_drs_rule_impl) do |_obj, params|
        expect(params[:group]).to eq 'GroupFoo'
      end

      expect(provider).to receive(:machine_present_in_drs_rule?) do |_obj, params|
        expect(params[:group]).to eq 'GroupFoo'
      end

      provider.create_vm(add_to_drs_group: 'GroupFoo')
    end

    it 'power_on is called when machine is created in powered-off state' do
      allow(vsphere_mock).to receive(:vm_clone) do
        vm_clone_response.merge('power_state' => 'poweredOff')
      end

      allow(provider).to receive(:setup_network_interfaces) {}
      expect(provider).to receive(:poweron_vm).once
      provider.create_vm
    end

    it 'provider_data are set to underlying compute object' do
      allow(vsphere_mock).to receive(:vm_clone) { vm_clone_response }

      c = provider.compute
      allow(provider).to receive(:setup_network_interfaces) {}
      expect(provider).to receive(:poweron_vm).once
      provider.create_vm
      expect(c.provider_data['id']).to eq vm_clone_response['new_vm']['id']
    end

    it 'does not call terminate_vm when vm_clone fails' do
      allow(vsphere_mock).to receive(:vm_clone).and_raise(RbVmomi::Fault.new 'blah blah ', 'fooDDD')

      expect(provider).to receive(:terminate_vm).never
      expect { provider.create_vm }.to raise_error('fooDDD')
    end

    it 'calls terminate_vm when VM instance created but setup failed' do
      allow(vsphere_mock).to receive(:vm_clone) { vm_clone_response }

      allow(provider).to receive(:setup_network_interfaces) {}
      allow(provider).to receive(:poweron_vm).and_raise(RbVmomi::Fault.new 'blah blah', 'fooGGG')
      expect(provider).to receive(:terminate_vm).once
      expect { provider.create_vm }.to raise_error('fooGGG')
    end
  end

  describe '#poweron_vm' do
    it 'fails when provider data are not present' do
      provider.compute.provider_data = nil
      expect { provider.poweron_vm }.to raise_error(ArgumentError)
    end

    it 'uses correct id from provider_data field' do
      expect(vsphere_mock).to receive(:vm_power_on) do |param|
        expect(param['instance_uuid']).to eq('fooo')

        {
          'task_state' => 'success'
        }
      end

      expect(vsphere_mock).to receive(:get_virtual_machine).and_return({})
      provider.compute.provider_data = { 'id' => 'fooo' }
      provider.poweron_vm
    end

    it 'retries fog#vm_power_on call when it fails and finally raises error' do
      expect(vsphere_mock).to receive(:vm_power_on).at_least(:twice).and_return(
        'task_state' => 'failed'
      )

      provider.compute.provider_data = { 'id' => 'fooo' }
      expect { provider.poweron_vm }.to raise_error(Provider::VSphere::PowerOnError)
    end
  end

  describe '#terminate_vm' do
    it 'fails when provider data are not present' do
      provider.compute.provider_data = nil
      expect { provider.terminate_vm }.to raise_error(ArgumentError)
    end

    it 'uses correct id from provider_data field' do
      servers = double('servers')
      server = double('server to be terminated', destroy: { 'task_state' => 'success' })
      expect(servers).to receive(:get) do |param|
        expect(param).to eq 'fo'
        server
      end

      expect(vsphere_mock).to receive(:servers).and_return(servers)
      provider.compute.provider_data = { 'id' => 'fo' }
      provider.terminate_vm
    end

    it 'retries server#destroy call when it fails and finally raises error ' do
      servers = double('servers')
      server = double('server to be terminated', destroy: { 'task_state' => 'failed' })
      allow(servers).to receive(:get) { server }

      expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
      provider.compute.provider_data = { 'id' => 'fo' }
      expect(server).to receive(:destroy).at_least(:twice)
      expect { provider.terminate_vm }.to raise_error(Provider::VSphere::TerminateVmError)
    end
  end

  describe '#shutdown_vm' do
    let(:servers) { double('servers') }
    let(:server) { double('server to be terminated') }

    it 'fails when provider data are not present' do
      provider.compute.provider_data = nil
      expect { provider.shutdown_vm }.to raise_error(ArgumentError)
    end

    it 'fails when the machine does not exist' do
      expect(servers).to receive(:get).at_least(:once) { nil }

      provider.compute.provider_data = { 'id' => 'fo' }
      expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
      expect { provider.shutdown_vm }.to raise_error(Provider::VSphere::VmNotExistsError)
    end

    it 'does nothing when the machine is already powered off' do
      expect(server).to receive(:power_state).at_least(:once) { 'poweredOff' }
      expect(servers).to receive(:get).at_least(:once) { server }
      expect(provider).to receive(:set_provider_data).once
      expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
      expect(server).to receive(:stop).at_most(0).times
      provider.compute.provider_data = { 'id' => 'fo' }
      provider.shutdown_vm
    end

    context 'managed mode' do
      it 'calls server.stop with force when soft stop failed' do
        second_time = false
        expect(server).to receive(:power_state).at_least(:twice) do
          second_time ? 'poweredOff' : 'poweredOn'
        end
        expect(server).to receive(:stop).twice do |param|
          expect(param[:force]).to eq second_time
          second_time = true
          fail 'soft stop failed' if second_time
        end
        expect(servers).to receive(:get).at_least(:once) { server }

        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        expect(vsphere_mock).to receive(:get_virtual_machine).at_least(:once) do
          { 'power_state' => 'poweredOff' }
        end
        provider.compute.provider_data = { 'id' => 'fo' }
        provider.shutdown_vm
      end
    end

    context 'hard mode' do
      it 'calls server.stop with force' do
        expect(server).to receive(:power_state).at_least(:twice) { 'poweredOn' }
        expect(server).to receive(:stop).at_least(:once) do |param|
          expect(param[:force]).to eq true
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect { provider.shutdown_vm(mode: 'hard') }.to raise_error('Expected function called')
      end
    end

    context 'soft mode' do
      it 'calls server.stop without force' do
        expect(server).to receive(:power_state).at_least(:twice) { 'poweredOn' }
        expect(server).to receive(:stop).at_least(:once) do |param|
          expect(param[:force]).to eq false
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect { provider.shutdown_vm(mode: 'soft') }.to raise_error('Expected function called')
      end
    end

    context 'unknown mode' do
      it 'throws an exception' do
        expect(server).to receive(:power_state).at_least(:twice) { 'poweredOn' }
        expect(server).to receive(:stop).at_most(0).times do
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect do
          provider.shutdown_vm(mode: 'something unexpected')
        end.to raise_error(Provider::VSphere::ShutdownVmError)
      end
    end

    it 'refreshes provider data' do
      expect(server).to receive(:power_state).at_least(:once) { 'poweredOff' }
      expect(servers).to receive(:get).at_least(:once) { server }
      expect(provider).to receive(:set_provider_data).once
      expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
      provider.compute.provider_data = { 'id' => 'fo' }
      provider.shutdown_vm
    end
  end

  describe '#reboot_vm' do
    let(:servers) { double('servers') }
    let(:server) { double('server to be rebooted') }

    it 'fails when provider data are not present' do
      provider.compute.provider_data = nil
      expect { provider.reboot_vm }.to raise_error(ArgumentError)
    end

    it 'fails when the machine does not exist' do
      expect(servers).to receive(:get).at_least(:once) { nil }

      provider.compute.provider_data = { 'id' => 'fo' }
      expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
      expect { provider.shutdown_vm }.to raise_error(Provider::VSphere::VmNotExistsError)
    end

    context 'managed mode' do
      it 'calls server.reboot with force when soft reboot failed' do
        second_time = false
        expect(server).to receive(:reboot).at_least(:twice) do |param|
          expect(param[:force]).to eq second_time
          second_time = !second_time
          fail 'soft reboot failed' if second_time
        end

        expect(servers).to receive(:get).at_least(:once) { server }

        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        provider.reboot_vm
      end
    end

    context 'hard mode' do
      it 'calls server.reboot with force' do
        expect(server).to receive(:reboot).at_least(:once) do |param|
          expect(param[:force]).to eq true
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect { provider.reboot_vm(mode: 'hard') }.to raise_error('Expected function called')
      end
    end

    context 'soft mode' do
      it 'calls server.reboot without force' do
        expect(server).to receive(:reboot).at_least(:once) do |param|
          expect(param[:force]).to eq false
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect { provider.reboot_vm(mode: 'soft') }.to raise_error('Expected function called')
      end
    end

    context 'unknown mode' do
      it 'throws an exception' do
        expect(server).to receive(:reboot).at_most(0).times do
          fail 'Expected function called'
        end

        expect(servers).to receive(:get).at_least(:once) { server }
        expect(vsphere_mock).to receive(:servers).at_least(:once).and_return(servers)
        provider.compute.provider_data = { 'id' => 'fo' }
        expect do
          provider.reboot_vm(mode: 'something unexpected')
        end.to raise_error(Provider::VSphere::RebootVmError)
      end
    end
  end

  describe '#execute_vm' do
    context 'when not all required arguments given' do
      it 'raises an exception' do
        provider.compute.provider_data = { 'id' => 'aaa' }
        expect { provider.execute_vm(user: 'foo') }.to raise_exception(ArgumentError)
        expect { provider.execute_vm }.to raise_exception(ArgumentError)
      end
    end

    context 'when no provider_data given' do
      it 'raises an exception' do
        expect { provider.execute_vm }.to raise_exception(ArgumentError)
      end
    end

    context 'when all required arguments given' do
      it 'calls fog#vm_execute and returns pid' do
        args = {
          user: 'a',
          password: 'b',
          command: 'c',
          async: true
        }
        expect(vsphere_mock).to receive(:vm_execute) do |param|
          expect(param['user']).to eq args[:user]
          expect(param['password']).to eq args[:password]
          expect(param['command']).to eq args[:command]
          111_222
        end

        provider.compute.provider_data = { 'id' => 'aaa' }
        expect(provider.execute_vm(args)).to eq 111_222
      end

      it 'throws an exception when async=false' do
        args = {
          user: 'a',
          password: 'b',
          command: 'c',
          async: false
        }

        provider.compute.provider_data = { 'id' => 'aaa' }
        expect { provider.execute_vm(args) }.to raise_exception('not implemented yet')
      end
    end
  end

  describe '#upload_vm' do
    context 'when not all required arguments given' do
      it 'raises an exception' do
        expect { provider.upload_file_vm }.to raise_exception(ArgumentError)
      end
    end

    context 'when all required arguments given' do
      it 'calls implementation method' do
        args = {
          user: 'a',
          password: 'b',
          guest_file_path: 'c',
          host_file: File.new('Gemfile')
        }

        expect(provider).to receive(:upload_file_impl) do |param|
          expect(param['user']).to eq args[:user]
          expect(param['password']).to eq args[:password]
          expect(param['guest_file_path']).to eq args[:guest_file_path]
          expect(param['host_file']).to eq args[:host_file]
        end

        provider.compute.provider_data = { 'id' => 'aaa' }
        provider.upload_file_vm(args)
      end
    end
  end

  describe '#download_vm' do
    context 'when not all required arguments given' do
      it 'raises an exception' do
        expect { provider.download_file_vm }.to raise_exception(ArgumentError)
      end
    end

    context 'when all required arguments given' do
      it 'calls implementation method and returns file class' do
        args = {
          user: 'a',
          password: 'b',
          guest_file_path: 'c'
        }

        expect(provider).to receive(:download_file_impl) do |param|
          expect(param['user']).to eq args[:user]
          expect(param['password']).to eq args[:password]
          expect(param['guest_file_path']).to eq args[:guest_file_path]
          NamedStringIO.new('tempfile', 'FAKE DOWNLOADED FILE')
        end

        provider.compute.provider_data = { 'id' => 'aaa' }
        expect(provider.download_file_vm(args).read).to eq 'FAKE DOWNLOADED FILE'
      end
    end
  end

  describe '#processes_vm' do
    context 'when not all required arguments given' do
      it 'raises an exception when no args' do
        expect { provider.processes_vm }.to raise_exception(ArgumentError)
      end

      it 'raises an exception when only user given' do
        expect do
          provider.processes_vm({user: 'foo'})
        end.to raise_exception('password must be specified')
      end
    end

    context 'when all required arguments given' do
      it 'calls implementation method and returns its result' do
        expected = [ { a: 'b' }, { c: 'd' } ]
        expect(vsphere_mock).to receive(:servers) do
          double('servers', get: double('server', guest_processes: expected))
        end

        expect(provider.processes_vm({ user: 'd', password: 'e'})).to eq expected
      end
    end
  end

  describe '#set_provider_data' do
    context 'when underlying method throws specific exception' do
      it 'repeates the call three times and returns without exception' do
        provider.compute.provider_data = { id: '01234568' }
        expect(provider).to receive(:vm_data).exactly(3).times do
          fail Fog::Compute::Vsphere::NotFound
        end

        expect { provider.set_provider_data }.to_not raise_exception
      end
    end

    context 'when underlying method throws another exception' do
      it 'does not repeat the call and finishes with exception' do
        provider.compute.provider_data = { id: '01234568' }
        expect(provider).to receive(:vm_data).exactly(1).times do
          fail 'foo'
        end

        expect { provider.set_provider_data }.to raise_exception 'foo'
      end
    end

    context 'when provider_data hash doesn\'t contain id' do
      it 'doesn\'t call get_virtual_machine' do
        expect(vsphere_mock).not_to receive(:get_virtual_machine)
        provider.compute.provider_data = {}
        expect { provider.set_provider_data }.not_to raise_error
      end
    end
  end
end
