# frozen_string_literal: true

module VagrantDockerHostsManager
  module Action
    class Cleanup
      def initialize(app, _env) = (@app = app)

      def call(env)
        Util::I18n.setup!(env)
        cfg = env[:machine].config.docker_hosts
        ENV['VDHM_VERBOSE'] = '1' if cfg.respond_to?(:verbose) && cfg.verbose
        mid    = env[:machine].id || 'unknown'
        dry    = Util::I18n.env_flag('VDHM_DRY_RUN')
        purge  = Util::I18n.env_flag('VDHM_PURGE_ON_DESTROY')
        ui     = env[:ui]
        hoster = Util::HostsFile.new(env, owner_id: mid)

        if dry
          Util::Json.emit(action: 'cleanup', status: 'dry-run', data: { owner: mid, mode: purge ? 'all' : 'owner' })
          return
        end

        removed = purge ? hoster.remove_all_managed! : hoster.remove!
        Util::Json.emit(action: 'cleanup', status: 'success',
                        data: { owner: mid, removed: removed, mode: purge ? 'all' : 'owner' })
      rescue StandardError => e
        Util::Json.emit(action: 'cleanup', status: 'error', error: e.message)
        UiHelpers.error(ui, "VDHM: #{e.message}")
      ensure
        @app.call(env)
      end
    end
  end
end
