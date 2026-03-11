# frozen_string_literal: true

require "vagrant"
require "i18n"

require_relative "version"
require_relative "config"
require_relative "command"
require_relative "helpers"
require_relative "util/hosts_file"
require_relative "util/docker"
require_relative "util/json"
require_relative "util/i18n"

begin
  I18n.enforce_available_locales = false
  gem_root = File.expand_path("../..", __dir__)
  I18n.load_path |= Dir[File.join(gem_root, "locales", "*.yml")]
  I18n.backend.load_translations
rescue StandardError
end

module VagrantDockerHostsManager
  class Plugin < Vagrant.plugin("2")
    name "vagrant-docker-hosts-manager"

    description <<~DESC
      Manage /etc/hosts (or Windows hosts) entries for Docker/Vagrant projects safely,
      with ownership markers, CLI, JSON output, and lifecycle hooks.
    DESC

    config(:docker_hosts) do
      Config
    end

    command("hosts") do
      Command
    end

    [:machine_action_up, :machine_action_provision, :machine_action_reload].each do |hook_name|
      action_hook(:vdhm_apply, hook_name) do |hook|
        hook.append(Action::Apply)
      end
    end

    action_hook(:vdhm_cleanup, :machine_action_destroy) do |hook|
      hook.prepend(Action::Cleanup)
    end
  end

  module Action
    class Apply
      def initialize(app, env) = (@app = app)

      def call(env)
        Util::I18n.setup!(env)
        cfg    = env[:machine].config.docker_hosts
        mid    = env[:machine].id || "unknown"
        dry    = Util::I18n.env_flag("VDHM_DRY_RUN")
        ui     = env[:ui]
        hoster = Util::HostsFile.new(env, owner_id: mid)

        entries = compute_entries(env, cfg, ui)
        if entries.empty?
          UiHelpers.say(ui, ::I18n.t("messages.no_entries"))
          return
        end

        if dry
          Util::Json.emit(action: "apply", status: "dry-run", data: { owner: mid, entries: entries })
          return
        end

        hoster.apply(entries)
        Util::Json.emit(action: "apply", status: "success", data: { owner: mid, entries: entries })
      rescue StandardError => e
        Util::Json.emit(action: "apply", status: "error", error: e.message, backtrace: e.backtrace&.first(3))
        UiHelpers.error(ui, "VDHM: #{e.message}")
      ensure
        @app.call(env)
      end

      private

      def compute_entries(env, cfg, ui)
        entries = {}

        cfg.domains.each do |domain, ip|
          next if domain.to_s.strip.empty?
          if ip.nil? || ip.to_s.strip.empty?
            UiHelpers.warn(ui, ::I18n.t("messages.missing_ip_for", domain: domain))
            next
          end
          entries[domain] = ip
        end

        if cfg.domain && !cfg.domain.strip.empty?
          ip = cfg.ip || begin
            if cfg.container_name && !cfg.container_name.strip.empty?
              Util::Docker.ip_for_container(cfg.container_name)
            end
          end
          if ip && !ip.strip.empty?
            UiHelpers.say(ui, ::I18n.t("messages.detected_ip", domain: cfg.domain, ip: ip))
            entries[cfg.domain] = ip
          else
            UiHelpers.warn(ui, ::I18n.t("messages.no_ip_found", domain: cfg.domain, container: cfg.container_name))
          end
        end

        entries
      end
    end

    class Cleanup
      def initialize(app, env) = (@app = app)

      def call(env)
        Util::I18n.setup!(env)
        mid    = env[:machine].id || "unknown"
        dry    = Util::I18n.env_flag("VDHM_DRY_RUN")
        ui     = env[:ui]
        hoster = Util::HostsFile.new(env, owner_id: mid)

        if dry
          Util::Json.emit(action: "cleanup", status: "dry-run", data: { owner: mid })
          return
        end

        removed = hoster.remove!
        Util::Json.emit(action: "cleanup", status: "success", data: { owner: mid, removed: removed })
      rescue StandardError => e
        Util::Json.emit(action: "cleanup", status: "error", error: e.message)
        UiHelpers.error(ui, "VDHM: #{e.message}")
      ensure
        @app.call(env)
      end
    end
  end
end
