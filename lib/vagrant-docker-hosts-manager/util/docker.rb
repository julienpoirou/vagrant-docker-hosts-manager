# frozen_string_literal: true

require "open3"
require_relative "verbose"

module VagrantDockerHostsManager
  module Util
    module Docker
      module_function

      # Resolves the first IPv4 address exposed by Docker inspect for a container.
      #
      # @param name [String, #to_s] Docker container name or id.
      # @return [String, nil] First IPv4 address, or nil when Docker cannot resolve it.
      def ip_for_container(name)
        return nil if name.to_s.strip.empty?

        fmt = "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}"
        Verbose.log("docker", "inspect", "-f", fmt, name.to_s)
        out, _err, status = Open3.capture3("docker", "inspect", "-f", fmt, name.to_s)
        return nil unless status.success?
        out.split(/\s+/).find { |ip| ip =~ /\A\d{1,3}(\.\d{1,3}){3}\z/ }
      rescue StandardError
        nil
      end
    end
  end
end
