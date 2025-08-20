# spec/hosts_file_spec.rb
# frozen_string_literal: true

require "spec_helper"
require "vagrant-docker-hosts-manager/helpers"
require "vagrant-docker-hosts-manager/util/docker"
require "vagrant-docker-hosts-manager/util/hosts_file"

RSpec.describe VagrantDockerHostsManager::Util::HostsFile do
  let(:ui) { double("ui", info: nil, warn: nil, error: nil) }
  let(:env) { { ui: ui } }
  let(:owner) { "unknown" }
  let(:hoster) { described_class.new(env, owner_id: owner) }

  def managed_block(lines, nl: "\n", ts: "2025-01-01T00:00:00Z")
    ([
      "# >>> vagrant-docker-hosts-manager #{owner} (managed) >>>",
      "# Managed by Vagrant - do not edit manually",
      "# Timestamp: #{ts}",
    ] + lines + [
      "# <<< vagrant-docker-hosts-manager #{owner} (managed) <<<",
    ]).join(nl) + nl
  end

  describe "#detect_newline" do
    it "returns CRLF on Windows" do
      allow(Gem).to receive(:win_platform?).and_return(true)
      expect(hoster.send(:detect_newline, "a\nb\r\nc")).to eq("\r\n")
      expect(hoster.send(:detect_newline, "a\nb\n")).to eq("\r\n")
    end

    it "returns LF on POSIX unless CRLF present" do
      allow(Gem).to receive(:win_platform?).and_return(false)
      expect(hoster.send(:detect_newline, "a\nb\n")).to eq("\n")
      expect(hoster.send(:detect_newline, "a\r\nb\r\n")).to eq("\r\n")
    end
  end

  describe "#compose_block" do
    it "produces a dense block (no blank lines) with LF" do
      allow(Gem).to receive(:win_platform?).and_return(false)
      out = hoster.send(:compose_block, { "a.test" => "1.1.1.1", "b.test" => "2.2.2.2" }, newline: "\n")
      lines = out.split("\n")
      expect(lines[0]).to eq("# >>> vagrant-docker-hosts-manager #{owner} (managed) >>>")
      expect(lines[1]).to eq("# Managed by Vagrant - do not edit manually")
      expect(lines[2]).to match(/^# Timestamp:/)
      expect(lines).to include("1.1.1.1 a.test")
      expect(lines).to include("2.2.2.2 b.test")
      expect(lines[-1]).to eq("# <<< vagrant-docker-hosts-manager #{owner} (managed) <<<")
      expect(lines.any?(&:empty?)).to be(false)
    end

    it "produces CRLF lines on Windows" do
      allow(Gem).to receive(:win_platform?).and_return(true)
      out = hoster.send(:compose_block, { "a.test" => "1.1.1.1" }, newline: "\r\n")
      expect(out).to include("\r\n")
      expect(out).not_to include("\n\n")
    end
  end

  describe "#normalize_entries" do
    it "strips, rejects blanks and sorts by domain" do
      entries = { "  b.test " => " 2.2.2.2 ", "a.test" => "1.1.1.1", "" => "3.3.3.3" }
      norm = hoster.send(:normalize_entries, entries)
      expect(norm.keys).to eq(%w[a.test b.test])
      expect(norm["b.test"]).to eq("2.2.2.2")
    end
  end

  describe "block editing end-to-end" do
    before { allow(Gem).to receive(:win_platform?).and_return(false) }

    it "applies new entries with no extra blank lines and merges on second apply" do
      initial = ""
      written = nil

      allow(hoster).to receive(:read).and_return(initial)
      allow(hoster).to receive(:write) { |content| written = content }
      allow(hoster).to receive(:list_pairs).with(:current).and_return([])

      count = hoster.apply({ "flowfind.noesi.local" => "172.28.100.2" })
      expect(count).to eq(1)
      expect(written).to include("172.28.100.2 flowfind.noesi.local")
      expect(written.scan(/\n\n/).size).to eq(0)

      allow(hoster).to receive(:read).and_return(written)
      allow(hoster).to receive(:list_pairs).with(:current).and_return([["172.28.100.2", "flowfind.noesi.local", owner]])

      written2 = nil
      allow(hoster).to receive(:write) { |content| written2 = content }

      count2 = hoster.apply({ "flowfind5.noesi.local" => "172.28.100.4" })
      expect(count2).to eq(2)
      expect(written2).to include("172.28.100.2 flowfind.noesi.local")
      expect(written2).to include("172.28.100.4 flowfind5.noesi.local")
      lines = written2.split("\n")
      expect(lines.any?(&:empty?)).to be(false)
    end

    it "remove_entries! removes by ip or domain and reports count" do
      content = managed_block(["172.28.100.2 flowfind.noesi.local", "172.28.100.4 flowfind5.noesi.local"])
      allow(hoster).to receive(:read).and_return(content)
      allow(hoster).to receive(:write) { |_c| }

      expect(hoster.list_pairs(:current)).to include(["172.28.100.2", "flowfind.noesi.local", owner])

      removed = hoster.remove_entries!(ips: ["172.28.100.2"], domains: [])
      expect(removed).to eq(1)

      allow(hoster).to receive(:read).and_return(content)
      removed2 = hoster.remove_entries!(ips: [], domains: ["flowfind5.noesi.local"])
      expect(removed2).to eq(1)
    end
  end

  describe "#remove_block_from" do
    it "drops only the managed block for the current owner" do
      before = [
        "127.0.0.1 localhost",
        managed_block(["1.1.1.1 a.test"], ts: "X").strip,
        "10.0.0.1 gateway"
      ].join("\n") + "\n"

      out = hoster.send(:remove_block_from, before)
      expect(out).to include("127.0.0.1 localhost")
      expect(out).to include("10.0.0.1 gateway")
      expect(out).not_to include("a.test")
      expect(out).not_to include("(managed)")
    end
  end

  describe "#entries_in_blocks / #list_pairs" do
    it "parses ip+fqdn lines within managed block" do
      content = managed_block(["8.8.8.8 dns.test", "9.9.9.9 dns2.test"])
      allow(hoster).to receive(:read).and_return(content)
      expect(hoster.entries_in_blocks(:current)).to eq({
        "dns.test" => ["8.8.8.8"],
        "dns2.test" => ["9.9.9.9"]
      })
      expect(hoster.list_pairs(:current)).to include(["8.8.8.8", "dns.test", owner])
    end
  end

  describe "#elevated?" do
    it "returns true on POSIX when euid is 0" do
      allow(Gem).to receive(:win_platform?).and_return(false)
      allow(Process).to receive(:euid).and_return(0)
      expect(hoster.elevated?).to be(true)
    end

    it "returns false on POSIX when euid is not 0" do
      allow(Gem).to receive(:win_platform?).and_return(false)
      allow(Process).to receive(:euid).and_return(1000)
      expect(hoster.elevated?).to be(false)
    end

    it "checks via PowerShell on Windows" do
      allow(Gem).to receive(:win_platform?).and_return(true)
      allow(Open3).to receive(:capture3)
        .and_return(["true", "", instance_double(Process::Status, success?: true)])
      expect(hoster.elevated?).to be(true)

      allow(Open3).to receive(:capture3)
        .and_return(["false", "", instance_double(Process::Status, success?: true)])
      expect(hoster.elevated?).to be(false)
    end
  end
end
