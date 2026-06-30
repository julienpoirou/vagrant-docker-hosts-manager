# frozen_string_literal: true

require 'spec_helper'
require 'vagrant-docker-hosts-manager/helpers'
require 'vagrant-docker-hosts-manager/util/docker'
require 'vagrant-docker-hosts-manager/command'

RSpec.describe VagrantDockerHostsManager::Command do
  subject(:cmd) { described_class.allocate }

  let(:ui) { double('ui', info: nil, warn: nil, error: nil) }

  describe '#ipv4?' do
    it 'accepts well-formed IPv4 and rejects everything else' do
      expect(cmd.send(:ipv4?, '172.28.100.2')).to be(true)
      expect(cmd.send(:ipv4?, '0.0.0.0')).to be(true)
      expect(cmd.send(:ipv4?, '256.0.0.1')).to be(false)
      expect(cmd.send(:ipv4?, '1.2.3')).to be(false)
      expect(cmd.send(:ipv4?, '1.2.3.4.5')).to be(false)
      expect(cmd.send(:ipv4?, 'example.test')).to be(false)
      expect(cmd.send(:ipv4?, nil)).to be(false)
    end
  end

  describe '#fqdn?' do
    it 'accepts valid hostnames and rejects malformed ones' do
      expect(cmd.send(:fqdn?, 'example.test')).to be(true)
      expect(cmd.send(:fqdn?, 'a.b.c.example.test')).to be(true)
      expect(cmd.send(:fqdn?, 'host-1.test')).to be(true)
      expect(cmd.send(:fqdn?, '')).to be(false)
      expect(cmd.send(:fqdn?, '.example.test')).to be(false)
      expect(cmd.send(:fqdn?, 'example.test.')).to be(false)
      expect(cmd.send(:fqdn?, '-bad.test')).to be(false)
      expect(cmd.send(:fqdn?, "#{'a' * 64}.test")).to be(false)
    end
  end

  describe '#parse_strict_mapping_from_argv!' do
    it 'returns [nil, nil] and leaves argv untouched when empty' do
      argv = []
      expect(cmd.send(:parse_strict_mapping_from_argv!, argv, ui, true)).to eq([nil, nil])
      expect(argv).to eq([])
    end

    it 'consumes and returns a valid ip+host pair' do
      argv = ['172.28.100.2', 'app.test', 'extra']
      pair = cmd.send(:parse_strict_mapping_from_argv!, argv, ui, true)
      expect(pair).to eq(['172.28.100.2', 'app.test'])
      expect(argv).to eq(['extra'])
    end

    it 'raises when only an IP is given (incomplete mapping)' do
      expect { cmd.send(:parse_strict_mapping_from_argv!, ['172.28.100.2'], ui, true) }
        .to raise_error(ArgumentError)
    end

    it 'raises on an invalid ip or host in a 2-arg mapping' do
      expect { cmd.send(:parse_strict_mapping_from_argv!, ['999.0.0.1', 'app.test'], ui, true) }
        .to raise_error(ArgumentError)
      expect { cmd.send(:parse_strict_mapping_from_argv!, ['172.28.100.2', '-bad'], ui, true) }
        .to raise_error(ArgumentError)
    end
  end

  describe '#parse_remove_key_from_argv!' do
    it 'consumes an ip or fqdn key, or returns nil when absent' do
      argv = ['172.28.100.2']
      expect(cmd.send(:parse_remove_key_from_argv!, argv)).to eq('172.28.100.2')
      expect(argv).to eq([])

      argv = ['app.test', 'rest']
      expect(cmd.send(:parse_remove_key_from_argv!, argv)).to eq('app.test')
      expect(argv).to eq(['rest'])

      expect(cmd.send(:parse_remove_key_from_argv!, [])).to be_nil
    end
  end

  describe '#extract_help_topic' do
    it 'returns the word after a help token, ignoring flags' do
      expect(cmd.send(:extract_help_topic, %w[help apply])).to eq('apply')
      expect(cmd.send(:extract_help_topic, %w[--help remove])).to eq('remove')
      expect(cmd.send(:extract_help_topic, %w[help --json])).to be_nil
      expect(cmd.send(:extract_help_topic, %w[apply 1.2.3.4 app.test])).to be_nil
      expect(cmd.send(:extract_help_topic, [])).to be_nil
    end
  end

  describe '#collect_view_pairs' do
    it 'merges planned then managed entries, de-duplicating and skipping blanks' do
      planned = { 'app.test' => '1.1.1.1', 'blank.test' => '', '' => '2.2.2.2' }
      managed = { 'app.test' => '1.1.1.1', 'db.test' => %w[3.3.3.3 4.4.4.4] }
      pairs = cmd.send(:collect_view_pairs, planned, managed)
      expect(pairs).to eq([['1.1.1.1', 'app.test'], ['3.3.3.3', 'db.test'], ['4.4.4.4', 'db.test']])
    end

    it 'returns an empty array when both maps are empty' do
      expect(cmd.send(:collect_view_pairs, {}, {})).to eq([])
    end
  end

  describe '#validate_apply_mapping' do
    let(:opts) { { json: false, no_emoji: true } }

    before { cmd.instance_variable_set(:@env, double('env', ui: ui)) }

    it 'returns nil for a valid ip/host pair' do
      expect(cmd.send(:validate_apply_mapping, '172.28.100.2', 'app.test', opts)).to be_nil
    end

    it 'returns 1 for an incomplete, malformed ip, or malformed host mapping' do
      expect(cmd.send(:validate_apply_mapping, '172.28.100.2', nil, opts)).to eq(1)
      expect(cmd.send(:validate_apply_mapping, '999.0.0.1', 'app.test', opts)).to eq(1)
      expect(cmd.send(:validate_apply_mapping, '172.28.100.2', '-bad', opts)).to eq(1)
    end
  end

  describe '#compute_entries' do
    let(:cfg_class) { Struct.new(:domains, :domain, :ip, :container_name, keyword_init: true) }

    it 'collects the domains hash, skipping blank domains and ips' do
      cfg = cfg_class.new(domains: { 'a.test' => '1.1.1.1', 'b.test' => '', '' => '2.2.2.2' })
      expect(cmd.send(:compute_entries, nil, cfg)).to eq({ 'a.test' => '1.1.1.1' })
    end

    it 'adds the single domain with an explicit ip' do
      cfg = cfg_class.new(domains: {}, domain: 'app.test', ip: '172.28.100.9')
      expect(cmd.send(:compute_entries, nil, cfg)).to eq({ 'app.test' => '172.28.100.9' })
    end

    it 'falls back to the container IP when no explicit ip is set' do
      cfg = cfg_class.new(domains: {}, domain: 'app.test', ip: nil, container_name: 'web')
      allow(VagrantDockerHostsManager::Util::Docker)
        .to receive(:ip_for_container).with('web').and_return('172.28.100.42')
      expect(cmd.send(:compute_entries, nil, cfg)).to eq({ 'app.test' => '172.28.100.42' })
    end

    it 'does not override a domain already provided via the domains hash' do
      cfg = cfg_class.new(domains: { 'app.test' => '1.1.1.1' }, domain: 'app.test', ip: '9.9.9.9')
      expect(cmd.send(:compute_entries, nil, cfg)).to eq({ 'app.test' => '1.1.1.1' })
    end
  end
end
