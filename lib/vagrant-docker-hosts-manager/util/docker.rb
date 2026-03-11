# frozen_string_literal: true

require "open3"

module VagrantDockerHostsManager
  module Util
    module Docker
      module_function

      def ip_for_container(name)
        return nil if name.to_s.strip.empty?
        out, _err, status = Open3.capture3(
          "docker", "inspect", "-f",
          "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}",
          name.to_s
        )
        return nil unless status.success?
        out.split(/\s+/).find { |ip| ip =~ /\A\d{1,3}(\.\d{1,3}){3}\z/ }
      rescue StandardError
        nil
      end

      def shell_escape(str)
        if Gem.win_platform?
          %('#{str.to_s.gsub("'", "''")}')
        else
          %('#{str.to_s.gsub("'", "'\\''")}')
        end
      end
    end
  end
end
