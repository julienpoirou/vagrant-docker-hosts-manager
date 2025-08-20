# frozen_string_literal: true

require "rspec"
require "i18n"

candidates = [
  File.expand_path("../lib", __dir__),
  File.expand_path("../../lib", __dir__),
  File.expand_path(File.join(Dir.pwd, "lib")),
  File.expand_path(File.join(Dir.pwd, ".vagrant.d", "plugins", "vagrant-docker-hosts-manager", "lib")),
]

candidates.uniq.each do |p|
  $LOAD_PATH.unshift(p) if Dir.exist?(p) && !$LOAD_PATH.include?(p)
end

module Vagrant
  def self.plugin(*)
    Class.new
  end
end

begin
  require "vagrant-docker-hosts-manager/util/docker"
rescue LoadError
  module VagrantDockerHostsManager
    module Util
      module Docker
        def self.shell_escape(s) = "'" + s.to_s.gsub("'", "''") + "'"
        def self.ip_for_container(_name) = ""
      end
    end
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

I18n.enforce_available_locales = false
I18n.available_locales = [:en, :fr]
I18n.default_locale = :en
I18n.backend.store_translations(:en, {})
I18n.backend.store_translations(:fr, {})
