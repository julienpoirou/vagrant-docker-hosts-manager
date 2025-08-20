# frozen_string_literal: true

require "i18n"

module VagrantDockerHostsManager
  module Util
    module I18n
      SUPPORTED = [:en, :fr].freeze
      @json = false

      module_function

      def setup!(env, forced: nil)
        ::I18n.enforce_available_locales = false

        gem_root = File.expand_path("../..", __dir__)
        paths    = Dir[File.join(gem_root, "locales", "*.yml")]
        ::I18n.load_path |= paths
        ::I18n.available_locales = SUPPORTED
        ::I18n.backend.load_translations

        lang = forced || ENV["VDHM_LANG"] || ENV["LANG"] || "en"
        sym  = lang.to_s[0, 2].downcase.to_sym
        ::I18n.locale = SUPPORTED.include?(sym) ? sym : :en

        begin
          if env[:ui] && env[:machine] && env[:machine].config.docker_hosts.respond_to?(:verbose) &&
             env[:machine].config.docker_hosts.verbose
            env[:ui].info(::I18n.t("messages.lang_set", lang: ::I18n.locale))
          end
        rescue StandardError
        end
      end

      def set_json_mode(v) = (@json = !!v)
      def json? = !!@json
      def env_flag(name) = ENV[name].to_s == "1"
    end
  end
end
