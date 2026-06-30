# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'pathname'
require 'vagrant-docker-hosts-manager/helpers'
require 'vagrant-docker-hosts-manager/util/json'
require 'vagrant-docker-hosts-manager/util/i18n'
require 'vagrant-docker-hosts-manager/util/hosts_file'
require 'vagrant-docker-hosts-manager/actions/apply'
require 'vagrant-docker-hosts-manager/actions/cleanup'

RSpec.describe 'VagrantDockerHostsManager::Action' do
  let(:ui) { double('ui', info: nil, warn: nil, error: nil) }
  let(:app) { double('app').tap { |a| allow(a).to receive(:call) } }

  def make_cfg(domain: 'app.test', ip: '127.0.0.1', domains: {}, container_name: nil, locale: nil, verbose: false)
    double('docker_hosts_cfg',
           domain: domain, ip: ip, domains: domains,
           container_name: container_name, locale: locale, verbose: verbose)
  end

  def make_env(cfg, hosts_path:, mid: 'MID-1')
    machine = double('machine',
                     id: mid,
                     config: double('config', docker_hosts: cfg))
    { machine: machine, ui: ui, vdhm_hosts_path: hosts_path }
  end


  before do
    allow(VagrantDockerHostsManager::Util::Json).to receive(:emit)
    allow(VagrantDockerHostsManager::UiHelpers).to receive(:setup_i18n!)
    allow(VagrantDockerHostsManager::Util::I18n).to receive(:setup!)
    allow(VagrantDockerHostsManager::Util::I18n).to receive(:env_flag).and_return(false)
  end

  describe 'Apply' do
    subject { VagrantDockerHostsManager::Action::Apply.new(app, nil) }

    it 'writes a hosts entry and calls next app' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        File.write(hosts, '')
        ENV['VDHM_HOSTS_PATH'] = hosts

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        subject.call(env)

        content = File.read(hosts)
        expect(content).to include('app.test')
        expect(content).to include('127.0.0.1')
        expect(app).to have_received(:call)
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end

    it 'does not write when dry-run is set' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        File.write(hosts, '')
        ENV['VDHM_HOSTS_PATH'] = hosts
        allow(VagrantDockerHostsManager::Util::I18n).to receive(:env_flag).with('VDHM_DRY_RUN').and_return(true)

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        subject.call(env)

        expect(File.read(hosts)).to be_empty
        expect(VagrantDockerHostsManager::Util::Json).to have_received(:emit)
          .with(hash_including(status: 'dry-run'))
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end

    it 'calls next app even when no entries are configured' do
      cfg = make_cfg(domain: nil, ip: nil, domains: {})
      env = make_env(cfg, hosts_path: nil)
      allow(I18n).to receive(:t).and_return('no entries')
      subject.call(env)
      expect(app).to have_received(:call)
    end
  end

  describe 'Cleanup' do
    subject { VagrantDockerHostsManager::Action::Cleanup.new(app, nil) }

    it 'removes a managed block and calls next app' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        content = <<~HOSTS
          # >>> vagrant-docker-hosts-manager MID-1 (managed) >>>
          127.0.0.1 app.test
          # <<< vagrant-docker-hosts-manager MID-1 (managed) <<<
        HOSTS
        File.write(hosts, content)
        ENV['VDHM_HOSTS_PATH'] = hosts

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        allow(I18n).to receive(:t).and_return('')
        subject.call(env)

        expect(File.read(hosts)).not_to include('app.test')
        expect(app).to have_received(:call)
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end

    it 'purges every managed block (any owner) when VDHM_PURGE_ON_DESTROY is set' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        content = <<~HOSTS
          127.0.0.1 keepme.local
          # >>> vagrant-docker-hosts-manager MID-1 (managed) >>>
          127.0.0.1 mine.test
          # <<< vagrant-docker-hosts-manager MID-1 (managed) <<<
          # >>> vagrant-docker-hosts-manager OTHER-VM (managed) >>>
          127.0.0.1 ghost.test
          # <<< vagrant-docker-hosts-manager OTHER-VM (managed) <<<
        HOSTS
        File.write(hosts, content)
        ENV['VDHM_HOSTS_PATH'] = hosts
        allow(VagrantDockerHostsManager::Util::I18n).to receive(:env_flag)
          .with('VDHM_PURGE_ON_DESTROY').and_return(true)

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        allow(I18n).to receive(:t).and_return('')
        subject.call(env)

        result = File.read(hosts)
        expect(result).to include('keepme.local')
        expect(result).not_to include('mine.test')
        expect(result).not_to include('ghost.test')
        expect(app).to have_received(:call)
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end

    it 'does not write when dry-run is set' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        original = "127.0.0.1 example.test\n"
        File.write(hosts, original)
        ENV['VDHM_HOSTS_PATH'] = hosts
        allow(VagrantDockerHostsManager::Util::I18n).to receive(:env_flag).with('VDHM_DRY_RUN').and_return(true)

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        subject.call(env)

        expect(File.read(hosts)).to eq(original)
        expect(VagrantDockerHostsManager::Util::Json).to have_received(:emit)
          .with(hash_including(status: 'dry-run'))
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end

    it 'calls next app even when nothing to remove' do
      Dir.mktmpdir do |tmp|
        hosts = File.join(tmp, 'hosts')
        File.write(hosts, '')
        ENV['VDHM_HOSTS_PATH'] = hosts

        cfg = make_cfg
        env = make_env(cfg, hosts_path: hosts)
        allow(I18n).to receive(:t).and_return('')
        subject.call(env)

        expect(app).to have_received(:call)
      ensure
        ENV.delete('VDHM_HOSTS_PATH')
      end
    end
  end
end
