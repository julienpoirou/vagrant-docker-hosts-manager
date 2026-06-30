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

  describe "#strip_managed_blocks (remove --all)" do
    it "drops every managed block regardless of owner, keeping unmanaged lines" do
      before = [
        "127.0.0.1 keepme.local",
        "# >>> vagrant-docker-hosts-manager aaaa1111 (managed) >>>",
        "# Managed by Vagrant - do not edit manually",
        "127.0.0.1 ghost-a.local",
        "# <<< vagrant-docker-hosts-manager aaaa1111 (managed) <<<",
        "# >>> vagrant-docker-hosts-manager bbbb2222 (managed) >>>",
        "127.0.0.1 ghost-b.local",
        "# <<< vagrant-docker-hosts-manager bbbb2222 (managed) <<<"
      ].join("\n") + "\n"

      out = hoster.send(:strip_managed_blocks, before)
      expect(out).to include("127.0.0.1 keepme.local")
      expect(out).not_to include("ghost-a.local")
      expect(out).not_to include("ghost-b.local")
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

  describe "scope handling across owners (unified scanner)" do
    def block_for(owner_id, lines, nl: "\n")
      ([
        "# >>> vagrant-docker-hosts-manager #{owner_id} (managed) >>>",
        "# Managed by Vagrant - do not edit manually",
      ] + lines + [
        "# <<< vagrant-docker-hosts-manager #{owner_id} (managed) <<<",
      ]).join(nl) + nl
    end

    it ":current only sees the current owner's block, :all sees every owner (CRLF tolerant)" do
      content =
        block_for(owner, ["1.1.1.1 mine.test"], nl: "\r\n") +
        "10.0.0.1 unmanaged.host\r\n" +
        block_for("other-vm", ["2.2.2.2 theirs.test"], nl: "\r\n")
      allow(hoster).to receive(:read).and_return(content)

      expect(hoster.list_pairs(:current)).to eq([["1.1.1.1", "mine.test", owner]])

      all = hoster.list_pairs(:all)
      expect(all).to include(["1.1.1.1", "mine.test", owner])
      expect(all).to include(["2.2.2.2", "theirs.test", "other-vm"])
      expect(all.map { |ip, _, _| ip }).not_to include("10.0.0.1")
    end

    it "de-duplicates repeated ips per domain in entries_in_blocks" do
      content = managed_block(["8.8.8.8 dns.test", "8.8.8.8 dns.test", "9.9.9.9 dns.test"])
      allow(hoster).to receive(:read).and_return(content)
      expect(hoster.entries_in_blocks(:current)).to eq({ "dns.test" => ["8.8.8.8", "9.9.9.9"] })
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

  describe "#write_windows elevation" do
    before do
      allow(Gem).to receive(:win_platform?).and_return(true)
      allow(hoster).to receive(:real_path).and_return("C:/Windows/System32/drivers/etc/hosts")
    end

    def ok_status = instance_double(Process::Status, success?: true)
    def fail_status = instance_double(Process::Status, success?: false)

    it "writes directly without launching UAC when already elevated" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok_status])
      expect(hoster).not_to receive(:system)
      expect { hoster.send(:write_windows, "127.0.0.1 a.test\n") }.not_to raise_error
    end

    it "propagates the elevated process exit code via -PassThru (not the launcher's)" do
      allow(Open3).to receive(:capture3).and_return(["", "denied", fail_status])
      captured = nil
      allow(hoster).to receive(:system) { |*args|
        captured = args
        true
      }

      hoster.send(:write_windows, "127.0.0.1 a.test\n")

      idx     = captured.index("-EncodedCommand")
      decoded = Base64.strict_decode64(captured[idx + 1]).force_encoding("UTF-16LE").encode("UTF-8")
      expect(decoded).to include("-PassThru")
      expect(decoded).to include("exit $p.ExitCode")
    end

    it "raises when the elevated write fails (UAC declined or write error)" do
      allow(Open3).to receive(:capture3).and_return(["", "denied", fail_status])
      allow(hoster).to receive(:system).and_return(false)
      expect { hoster.send(:write_windows, "127.0.0.1 a.test\n") }
        .to raise_error(/elevated write failed/)
    end
  end
end
