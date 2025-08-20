# frozen_string_literal: true

require "open3"

module VagrantDockerHostsManager
  module Util
    module Docker
      module_function

      def ip_for_container(name)
        return nil if name.to_s.strip.empty?
        cmd = %(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}" #{shell_escape(name)})
        out, _err, status = Open3.capture3(cmd)
        return nil unless status.success?
        out.split(/\s+/).find { |ip| ip =~ /\A\d{1,3}(\.\d{1,3}){3}\z/ }
      rescue
        nil
      end

      def shell_escape(str)
        if Gem.win_platform?
          %("#{str.gsub('"', '\"')}")
        else
          %('#{str.gsub("'", "'\\\\''")}')
        end
      end
    end
  end
end
