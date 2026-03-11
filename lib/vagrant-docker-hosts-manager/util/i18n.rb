# frozen_string_literal: true

require "i18n"
require_relative "../helpers"

module VagrantDockerHostsManager
  module Util
    module I18n
      @json = false

      module_function

      def setup!(env, forced: nil)
        UiHelpers.setup_i18n!

        if forced
          begin
            UiHelpers.set_locale!(forced)
          rescue UiHelpers::UnsupportedLocaleError
            UiHelpers.set_locale!("en")
          end
        end

        begin
          cfg = env[:machine]&.config&.docker_hosts
          if cfg&.respond_to?(:locale) && !cfg.locale.to_s.strip.empty?
            UiHelpers.setup_locale_from_config!(cfg)
          end
        rescue StandardError
          nil
        end

        begin
          if env[:ui] && env[:machine]&.config&.docker_hosts&.respond_to?(:verbose) &&
             env[:machine].config.docker_hosts.verbose
            env[:ui].info(::I18n.t("messages.lang_set", lang: ::I18n.locale))
          end
        rescue StandardError
          nil
        end
      end

      def set_json_mode(v) = (@json = !!v)
      def json? = !!@json
      def env_flag(name) = ENV[name].to_s == "1"
    end
  end
end
