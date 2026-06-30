# frozen_string_literal: true

module VagrantDockerHostsManager
  module Action
    class Apply
      def initialize(app, _env) = (@app = app)

      def call(env)
        Util::I18n.setup!(env)
        cfg = env[:machine].config.docker_hosts
        ENV['VDHM_VERBOSE'] = '1' if cfg.respond_to?(:verbose) && cfg.verbose
        mid    = env[:machine].id || 'unknown'
        dry    = Util::I18n.env_flag('VDHM_DRY_RUN')
        ui     = env[:ui]
        hoster = Util::HostsFile.new(env, owner_id: mid)

        entries = compute_entries(env, cfg, ui)
        if entries.empty?
          UiHelpers.say(ui, ::I18n.t('vdhm.messages.no_entries'))
          return
        end

        if dry
          Util::Json.emit(action: 'apply', status: 'dry-run', data: { owner: mid, entries: entries })
          return
        end

        hoster.apply(entries)
        Util::Json.emit(action: 'apply', status: 'success', data: { owner: mid, entries: entries })
      rescue StandardError => e
        Util::Json.emit(action: 'apply', status: 'error', error: e.message, backtrace: e.backtrace&.first(3))
        UiHelpers.error(ui, "VDHM: #{e.message}")
      ensure
        @app.call(env)
      end

      private

      def compute_entries(_env, cfg, ui)
        entries = {}

        cfg.domains.each do |domain, ip|
          next if domain.to_s.strip.empty?

          if ip.nil? || ip.to_s.strip.empty?
            UiHelpers.warn(ui, ::I18n.t('vdhm.messages.missing_ip_for', domain: domain))
            next
          end
          entries[domain] = ip
        end

        if cfg.domain && !cfg.domain.strip.empty?
          ip = cfg.ip || begin
            Util::Docker.ip_for_container(cfg.container_name) if cfg.container_name && !cfg.container_name.strip.empty?
          end
          if ip && !ip.strip.empty?
            UiHelpers.say(ui, ::I18n.t('vdhm.messages.detected_ip', domain: cfg.domain, ip: ip))
            entries[cfg.domain] = ip
          else
            UiHelpers.warn(ui, ::I18n.t('vdhm.messages.no_ip_found', domain: cfg.domain, container: cfg.container_name))
          end
        end

        entries
      end
    end
  end
end
