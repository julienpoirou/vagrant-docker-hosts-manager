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
require_relative "actions/apply"
require_relative "actions/cleanup"

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
end
