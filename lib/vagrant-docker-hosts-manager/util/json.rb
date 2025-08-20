# frozen_string_literal: true

require "json"

module VagrantDockerHostsManager
  module Util
    module Json
      def self.emit(obj)
        return true unless Util::I18n.json?
        puts JSON.generate(obj)
        true
      end
    end
  end
end
