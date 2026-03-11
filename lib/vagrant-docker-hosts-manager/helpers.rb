# frozen_string_literal: true

require "i18n"

module VagrantDockerHostsManager
  module UiHelpers
    class MissingTranslationError < StandardError; end
    class UnsupportedLocaleError   < StandardError; end

    SUPPORTED      = [:en, :fr].freeze
    OUR_NAMESPACES = %w[messages. errors. log. help.].freeze

    EMOJI = {
      success:  "✅",
      info:     "🔍",
      ongoing:  "🔁",
      warning:  "⚠️",
      error:    "❌",
      version:  "💾",
      broom:    "🧹",
      question: "❓",
      bug:      "🐛"
    }.freeze

    module_function

    def setup_i18n!
      return if defined?(@i18n_setup) && @i18n_setup

      ::I18n.enforce_available_locales = false

      base  = File.expand_path("../../locales", __dir__)
      paths = Dir[File.join(base, "*.yml")]
      ::I18n.load_path |= paths
      ::I18n.available_locales = SUPPORTED

      default = ((ENV["VDHM_LANG"] || ENV["LANG"] || "en")[0, 2] rescue "en").to_sym
      ::I18n.default_locale = SUPPORTED.include?(default) ? default : :en

      ::I18n.backend.load_translations
      @i18n_setup = true
    end

    def set_locale!(lang)
      setup_i18n!
      sym = lang.to_s[0, 2].downcase.to_sym
      unless SUPPORTED.include?(sym)
        raise UnsupportedLocaleError,
              "#{EMOJI[:error]} Unsupported language: #{sym}. Available: #{SUPPORTED.join(", ")}"
      end
      ::I18n.locale = sym
      ::I18n.backend.load_translations
    end

    def setup_locale_from_config!(cfg)
      lang = (cfg.respond_to?(:locale) ? cfg.locale : nil) || ENV["VDHM_LANG"]
      return unless lang
      set_locale!(lang)
    rescue UnsupportedLocaleError
      set_locale!("en")
    end

    def t(key, **opts)
      ::I18n.t(key, **opts)
    end

    def t!(key, **opts)
      setup_i18n!
      k = key.to_s
      if our_key?(k) && !::I18n.exists?(k, ::I18n.locale)
        raise MissingTranslationError, "#{EMOJI[:error]} [#{::I18n.locale}] Missing translation for key: #{k}"
      end
      ::I18n.t(k, **opts)
    end

    def t_hash(key)
      setup_i18n!
      v = ::I18n.t(key, default: {})
      v.is_a?(Hash) ? v : {}
    end

    def exists?(key)
      ::I18n.exists?(key, ::I18n.locale)
    end

    def our_key?(k)
      OUR_NAMESPACES.any? { |ns| k.start_with?(ns) }
    end

    def e(key, no_emoji: false)
      return "" if no_emoji || ENV["VDHM_NO_EMOJI"] == "1"
      EMOJI[key] || ""
    end

    def say(ui, msg)
      ui&.info(msg) || puts(msg)
    end

    def warn(ui, msg)
      ui&.warn(msg) || puts(msg)
    end

    def error(ui, msg)
      ui&.error(msg) || warn(ui, msg)
    end

    def debug_enabled?
      ENV["VDHM_DEBUG"].to_s == "1"
    end

    def debug(ui, msg)
      return unless debug_enabled?
      say(ui, "#{e(:bug)} #{msg}")
    end
  end
end
