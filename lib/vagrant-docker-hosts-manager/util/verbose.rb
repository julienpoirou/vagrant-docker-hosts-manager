# frozen_string_literal: true

require "shellwords"

module VagrantDockerHostsManager
  module Util
    module Verbose
      module_function

      def enabled?
        ENV["VDHM_VERBOSE"].to_s == "1"
      end

      def log(*args)
        return unless enabled?

        line = args.length == 1 && args.first.is_a?(String) ? args.first : args.map(&:to_s).shelljoin
        warn("[VDHM] #{line}")
      end
    end
  end
end
