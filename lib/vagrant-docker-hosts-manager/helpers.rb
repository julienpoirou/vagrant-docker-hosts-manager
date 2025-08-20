# frozen_string_literal: true

require "i18n"

module VagrantDockerHostsManager
  module UiHelpers
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

    def e(key, no_emoji: false)
      return "" if no_emoji || ENV["VDHM_NO_EMOJI"] == "1"
      EMOJI[key] || ""
    end

    def debug_enabled?
      ENV["VDHM_DEBUG"].to_s == "1"
    end

    def t(key, **opts)  = ::I18n.t(key, **opts)
    def exists?(key)    = ::I18n.exists?(key, ::I18n.locale)

    def say(ui, msg)    = (ui&.info(msg)  || puts(msg))
    def warn(ui, msg)   = (ui&.warn(msg)  || puts(msg))
    def error(ui, msg)  = (ui&.error(msg) || warn(ui, msg))

    def debug(ui, msg)
      return unless debug_enabled?
      say(ui, "#{e(:bug)} #{msg}")
    end
  end
end
