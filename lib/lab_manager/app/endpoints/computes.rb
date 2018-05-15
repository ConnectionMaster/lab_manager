require 'lab_manager/app/endpoints/base'

module LabManager
  class App
    module Endpoints
      # handles all endpoints related to Computes
      class Compute < Base
        REBOOT_TYPES = %w(soft hard managed)

        get '/' do
          # state = params[:state]
          scope = ::Compute.all
          %w(state name provider_name).each do |filter_key|
            value = params[filter_key]
            # TODO: is it safe? Have I check class to String || Array of Strings?
            # probably better solution would be use runsack
            next unless value
            scope = scope.where(filter_key => value)
          end
          scope.to_json
        end

        get '/:id' do
          begin
            ids = params[:id].to_s.split(',').each(&:to_i)
            computes = ::Compute.find(ids.count == 1 ? params[:id] : ids)
            Array.wrap(computes).map(
              &:reload_provider_data
            ) unless %w(false f 0).include?(params[:cached])
            computes.to_json
          rescue ActiveRecord::RecordNotFound => e
            halt 404, { message: e.message }.to_json
          end
        end

        post '/' do
          provider_name = params['provider_name']
          unless LabManager.config.providers.include?(provider_name)
            halt 422, { message: 'Uknown provider!' }.to_json
            return
          end
          ::Compute.create(params).to_json
        end

        delete '/:id' do
          compute = ::Compute.find(params[:id])
          compute.actions.create!(command: :terminate_vm).to_json
        end

        get '/:id/actions' do
          compute = ::Compute.find(params[:id])
          compute.actions.to_json
        end

        get '/:compute_id/actions/:id' do
          compute = ::Compute.find(params[:compute_id])
          compute.actions.find(params[:id]).to_json
        end

        get '/:id/processes' do
          # everything is asynchronous
          compute = ::Compute.find(params[:id])

          halt 422, {
            message: 'param user must be given'
          }.to_json if params[:user].blank?

          halt 422, {
            message: 'param password must be given'
          }.to_json if params[:password].nil?

          compute.actions.create!(
            command: :processes_vm,
            payload: {
              user: params[:user],
              password: params[:password]
            }
          ).to_json
        end

        # actions

        put '/:id/power_on' do
          compute = ::Compute.find(params[:id])
          compute.actions.create!(command: :poweron_vm).to_json
        end

        put '/:id/power_off' do
          compute = ::Compute.find(params[:id])
          compute.actions.create!(command: :poweroff_vm).to_json
        end

        put '/:id/shutdown' do
          compute = ::Compute.find(params[:id])
          compute.actions.create!(command: :shutdown_vm).to_json
        end

        put '/:id/reboot' do
          compute = ::Compute.find(params[:id])
          halt 422, {
            message: 'type shoule be one of: ' + REBOOT_TYPES.join(', ')
          }.to_json if params['type'] && !REBOOT_TYPES.include?(params['type'])

          compute.actions.create!(
            command: :reboot_vm,
            payload: { type: (params[:type] || 'managed') }
          ).to_json
        end

        put '/:id/execute' do
          compute = ::Compute.find(params[:id])
          compute.actions.create!(
            command: :execute_vm,
            payload: params.slice(
              'command',
              'args',
              'working_dir',
              'user',
              'password',
              'async'
            )
          ).to_json
        end

        # Snapshots
        # NOTE: maybe standlone middleware?

        get '/:id/snapshots' do
          compute = ::Compute.find(params[:id])
          compute.snapshots.to_json
        end

        post '/:id/snapshots' do
          compute = ::Compute.find(params[:id])

          halt 422, {
            message: 'param `name` has to be passed'
          }.to_json if params['name'].blank?
          halt 422, {
            message: 'only name is allowed param'
          }.to_json unless (params.keys - %w(name id splat captures)).empty?

          action = compute.actions.create!(
            command: 'take_snapshot_vm',
            payload: {
              name: params['name']
            }
          )

          action.to_json
        end

        get '/:id/snapshots/:snapshot_id' do
          compute = ::Compute.find(params[:id])
          snapshot = compute.snapshots.find(params[:snapshot_id])
          snapshot.to_json
        end

        post '/:id/snapshots/:snapshot_id/revert' do
          compute = ::Compute.find(params[:id])
          snapshot = compute.snapshots.find(params[:snapshot_id])

          action = compute.actions.create!(
            command: 'revert_snapshot_vm',
            payload: {
              snapshot_id: snapshot.id
            }
          )

          action.to_json
        end
      end
    end
  end
end
