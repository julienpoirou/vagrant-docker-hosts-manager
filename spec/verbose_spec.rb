# frozen_string_literal: true

require "spec_helper"
require "vagrant-docker-hosts-manager/util/verbose"

RSpec.describe VagrantDockerHostsManager::Util::Verbose do
  around do |example|
    saved = ENV.fetch("VDHM_VERBOSE", nil)
    example.run
    ENV["VDHM_VERBOSE"] = saved
  end

  it "is disabled unless VDHM_VERBOSE is exactly \"1\"" do
    ENV["VDHM_VERBOSE"] = nil
    expect(described_class.enabled?).to be(false)
    ENV["VDHM_VERBOSE"] = "true"
    expect(described_class.enabled?).to be(false)
    ENV["VDHM_VERBOSE"] = "1"
    expect(described_class.enabled?).to be(true)
  end

  it "prints a shell-quoted argv to stderr when enabled" do
    ENV["VDHM_VERBOSE"] = "1"
    expect { described_class.log("docker", "inspect", "my app") }
      .to output(/\[VDHM\] docker inspect my\\ app/).to_stderr
  end

  it "prints a single string label verbatim" do
    ENV["VDHM_VERBOSE"] = "1"
    expect { described_class.log("powershell (write hosts file)") }
      .to output("[VDHM] powershell (write hosts file)\n").to_stderr
  end

  it "stays silent when disabled" do
    ENV["VDHM_VERBOSE"] = nil
    expect { described_class.log("docker", "inspect", "x") }.not_to output.to_stderr
  end
end
