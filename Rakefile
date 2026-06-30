# frozen_string_literal: true

require "rake"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

YARD_RUNNER = [
  "bundle exec ruby",
  "-e \"ARGV.unshift('doc', '--quiet'); load Gem.bin_path('yard', 'yard')\""
].join(" ")

desc "Generate RubyDoc/YARD documentation"
task :doc do
  sh YARD_RUNNER
end

task default: :spec
