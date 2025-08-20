# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = "vagrant-docker-hosts-manager"
  s.version     = File.read(File.join(__dir__, "lib/vagrant-docker-hosts-manager/VERSION")).strip
  s.summary     = "Manage /etc/hosts (or Windows hosts) entries for Docker/Vagrant projects safely"
  s.description = "Adds `vagrant hosts` command and lifecycle hooks to apply/remove managed hosts " \
                  "entries with ownership markers, JSON output, i18n, and safe cleanup."
  s.authors     = ["Julien Poirou"]
  s.email       = ["julienpoirou@protonmail.com"]
  s.homepage    = "https://github.com/julienpoirou/vagrant-docker-hosts-manager"
  s.license     = "MIT"

  s.required_ruby_version = ">= 3.1"

  s.files = Dir[
    "lib/**/*",
    "locales/*.yml",
    "README.md",
    "LICENSE.md",
    "CHANGELOG.md"
  ]
  s.require_paths = ["lib"]

  s.add_dependency "i18n", ">= 1.8"

  s.add_development_dependency "rspec", "~> 3.12"
  s.add_development_dependency "rake", "~> 13.0"

  s.metadata = {
    "rubygems_mfa_required" => "true",
    "bug_tracker_uri"       => "https://github.com/julienpoirou/vagrant-docker-hosts-manager/issues",
    "changelog_uri"         => "https://github.com/julienpoirou/vagrant-docker-hosts-manager/blob/main/CHANGELOG.md",
    "source_code_uri"       => "https://github.com/julienpoirou/vagrant-docker-hosts-manager",
    "homepage_uri"          => "https://github.com/julienpoirou/vagrant-docker-hosts-manager"
  }
end
