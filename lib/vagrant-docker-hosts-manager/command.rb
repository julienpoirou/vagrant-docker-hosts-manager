# frozen_string_literal: true

require "optparse"
require_relative "helpers"

module VagrantDockerHostsManager
  class Command < Vagrant.plugin("2", :command)
    def execute
      opts = {
        json: false,
        dry:  false,
        lang: nil,
        no_emoji: false
      }

      raw_argv = @argv.dup
      help_topic = begin
        i = raw_argv.index { |x| x =~ /\A(?:help|--help|-h)\z/ }
        cand = (i && raw_argv[i + 1]) ? raw_argv[i + 1] : nil
        (cand && cand !~ /\A-/) ? cand : nil
      rescue
        nil
      end

      parser = OptionParser.new do |o|
        o.banner = "Usage: vagrant hosts <apply|remove|view|help|version> [options]"
        o.on("--json", "Machine-readable JSON output") { opts[:json] = true }
        o.on("--lang LANG", "Force language (en|fr)")  { |v| opts[:lang] = v }
        o.on("--no-emoji", "Disable emoji in CLI output") { opts[:no_emoji] = true }
        o.on("-h", "--help", "Show help") { print_help(@env.ui); return 0 }
      end

      argv = parse_options(parser)
      return 0 unless argv

      action = argv.shift
      env    = @env

      Util::I18n.setup!(env, forced: opts[:lang])
      Util::I18n.set_json_mode(opts[:json])
      ENV["VDHM_DRY_RUN"]  = "1" if opts[:dry]
      ENV["VDHM_NO_EMOJI"] = "1" if opts[:no_emoji]

      case action
      when nil, "", "help", "--help", "-h"
        topic = help_topic || argv.shift
        print_help(@env.ui, topic: topic, no_emoji: opts[:no_emoji])
        return 0
      when "version"
        if opts[:json]
          Util::Json.emit(action: "version", status: "success", data: { version: VagrantDockerHostsManager::VERSION })
        else
          emoji = UiHelpers.e(:version, no_emoji: opts[:no_emoji])
          line  = ::I18n.t("log.version_line",
                           default: "vagrant-docker-hosts-manager version %{version}",
                           version: VagrantDockerHostsManager::VERSION)
          UiHelpers.say(@env.ui, "#{emoji} #{line}")
        end
        return 0
      end

      machine = nil

      case action
      when "apply"
        begin
          ip_for_apply, host_for_apply =
            parse_strict_mapping_from_argv!(argv, @env.ui, opts[:no_emoji], json: opts[:json])
        rescue ArgumentError => e
          Util::Json.emit(action: "apply", status: "error", error: e.message) if opts[:json]
          return 1
        end

        with_target_vms(argv, single_target: true) { |m| machine = m }

        unless machine
          UiHelpers.error(
            @env.ui,
            "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
              ::I18n.t(
                "errors.no_machine",
                default: "No target machine found. Run this inside a Vagrant project or pass a VM name."
              )
          )
          Util::Json.emit(action: "apply", status: "error", error: "No target machine found") if opts[:json]
          return 1
        end

        if ip_for_apply || host_for_apply
          unless ip_for_apply && host_for_apply
            UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
              ::I18n.t("messages.missing_mapping",
                default: "Provide both IP and FQDN (e.g. `vagrant hosts apply 1.2.3.4 example.test`)."))
            return 1
          end
          unless ipv4?(ip_for_apply)
            UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
              ::I18n.t("messages.invalid_ip", default: "Invalid IPv4 address: %{ip}", ip: ip_for_apply))
            return 1
          end
          unless fqdn?(host_for_apply)
            UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
              ::I18n.t("messages.invalid_host", default: "Invalid host/FQDN: %{host}", host: host_for_apply))
            return 1
          end
        end

        cfg    = machine.config.docker_hosts
        mid    = machine.id || "unknown"
        hoster = Util::HostsFile.new({ machine: machine, ui: @env.ui }, owner_id: mid)

        unless ENV["VDHM_DRY_RUN"] == "1" || hoster.elevated?
          UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
            ::I18n.t("errors.not_admin",
              default: "Administrator/root privileges required to modify hosts at %{path}.",
              path: hoster.printable_path))
          return 1
        end

        entries = compute_entries(machine, cfg)
        entries[host_for_apply] = ip_for_apply if ip_for_apply && host_for_apply

        if entries.empty?
          UiHelpers.say(@env.ui, "#{UiHelpers.e(:info, no_emoji: opts[:no_emoji])} " +
            ::I18n.t("messages.no_entries", default: "No hosts entries configured."))
          Util::Json.emit(action: "apply", status: "noop", data: { reason: "no entries" })
          return 0
        end

        return 0 if opts[:dry] and Util::Json.emit(action: "apply", status: "dry-run", data: { entries: entries })

        hoster.apply(entries)
        Util::Json.emit(action: "apply", status: "success", data: { entries: entries })
        return 0

      when "remove"
        remove_key = parse_remove_key_from_argv!(argv)

        with_target_vms(argv, single_target: true) { |m| machine = m }

        unless machine
          UiHelpers.error(
            @env.ui,
            "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
              ::I18n.t(
                "errors.no_machine",
                default: "No target machine found. Run this inside a Vagrant project or pass a VM name."
              )
          )
          Util::Json.emit(action: "remove", status: "error", error: "No target machine found") if opts[:json]
          return 1
        end

        if remove_key && !(ipv4?(remove_key) || fqdn?(remove_key))
          UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
            ::I18n.t("messages.invalid_key",
              default: "Invalid IP or FQDN: %{key}", key: remove_key))
          UiHelpers.error(@env.ui, "  " + ::I18n.t("messages.remove_expected_format",
              default: "Expected IPv4 (e.g. 172.28.100.2) or FQDN (e.g. example.test)."))
          Util::Json.emit(action: "remove", status: "error",
            error: "invalid parameter format") if opts[:json]
          return 1
        end

        mid    = machine.id || "unknown"
        hoster = Util::HostsFile.new({ machine: machine, ui: @env.ui }, owner_id: mid)

        unless ENV["VDHM_DRY_RUN"] == "1" || hoster.elevated?
          UiHelpers.error(@env.ui, "#{UiHelpers.e(:error, no_emoji: opts[:no_emoji])} " +
            ::I18n.t("errors.not_admin",
              default: "Administrator/root privileges required to modify hosts at %{path}.",
              path: hoster.printable_path))
          return 1
        end

        if remove_key
          return 0 if opts[:dry] && Util::Json.emit(action: "remove", status: "dry-run",
                                                     data: { owner: mid, key: remove_key })

          removed = if ipv4?(remove_key)
                      hoster.remove_entries!(ips: [remove_key], domains: [])
                    else
                      hoster.remove_entries!(ips: [], domains: [remove_key])
                    end
          Util::Json.emit(action: "remove", status: "success",
                          data: { removed: removed, mode: "filtered" })
          return 0
        end

        return 0 if opts[:dry] && Util::Json.emit(action: "remove", status: "dry-run", data: { owner: mid })

        vm_label = (machine.name rescue nil) || mid
        unless confirm_all_removal?(@env.ui, vm_label, no_emoji: opts[:no_emoji])
          UiHelpers.say(@env.ui, "#{UiHelpers.e(:info, no_emoji: opts[:no_emoji])} " +
            ::I18n.t("messages.remove_all_cancelled", default: "Cancelled. Nothing removed."))
          Util::Json.emit(action: "remove", status: "cancelled", data: { owner: mid })
          return 0
        end

        removed_block = hoster.remove!
        Util::Json.emit(action: "remove", status: "success", data: { removed: removed_block })
        return 0

      when "view"
        hoster       = Util::HostsFile.new({ ui: @env.ui }, owner_id: "any")
        managed_map  = hoster.entries_in_blocks(:all)
        planned_map = {}

        begin
          vm_for_view = nil
          with_target_vms(argv.dup, single_target: true) { |m| vm_for_view = m }
          if vm_for_view
            cfg = vm_for_view.config.docker_hosts
            planned_map = compute_entries(vm_for_view, cfg)
          end
        rescue StandardError
          planned_map = {}
        end

        pairs = []
        seen  = {}

        planned_map.each do |fqdn, ip|
          next if fqdn.to_s.empty? || ip.to_s.empty?
          key = "#{ip}\0#{fqdn}"
          next if seen[key]
          pairs << [ip.to_s, fqdn.to_s]
          seen[key] = true
        end

        managed_map.each do |fqdn, ips|
          next if fqdn.to_s.empty?
          Array(ips).each do |ip|
            next if ip.to_s.empty?
            key = "#{ip}\0#{fqdn}"
            next if seen[key]
            pairs << [ip.to_s, fqdn.to_s]
            seen[key] = true
          end
        end

        if opts[:json]
          Util::Json.emit(
            action: "view",
            status: "success",
            data: { entries: pairs.map { |ip, fqdn| { ip: ip, host: fqdn } } }
          )
          return 0
        end

        emoji_info = UiHelpers.e(:info, no_emoji: opts[:no_emoji])

        if pairs.empty?
          UiHelpers.say(@env.ui, "#{emoji_info} " + ::I18n.t("messages.no_entries",
            default: "No hosts entries configured."))
          return 0
        end

        header =
          if planned_map.any?
            ::I18n.t("messages.view_header", default: "Planned hosts entries:")
          else
            ::I18n.t("messages.view_managed_header", default: "Managed hosts entries:")
          end

        UiHelpers.say(@env.ui, "#{emoji_info} #{header}")
        pad = pairs.map { |ip, _| ip.length }.max || 0
        pairs.each do |ip, fqdn|
          UiHelpers.say(@env.ui, "  • #{ip.ljust(pad)} -> #{fqdn}")
        end
        return 0

      else
        print_help(@env.ui, no_emoji: opts[:no_emoji])
        return 0
      end
    rescue => e
      Util::Json.emit(action: "command", status: "error", error: e.message)
      1
    end

    private

    def confirm_all_removal?(ui, vm_label, no_emoji:)
      prompt = ::I18n.t(
        "messages.confirm_remove_all",
        default: "This will remove ALL managed hosts entries for %{vm}. Continue? (yes/No)",
        vm: vm_label.to_s
      )

      line = "#{UiHelpers.e(:question, no_emoji: no_emoji)} #{prompt} "

      begin
        $stdout.print(line)
        $stdout.flush
        answer = ($stdin.gets || "").to_s
      rescue
        answer = ""
      ensure
        $stdout.puts ""
      end

      %w[y yes].include?(answer.strip.downcase)
    end

    def parse_strict_mapping_from_argv!(argv, ui, no_emoji, json: false)
      return [nil, nil] if argv.empty?

      if argv.length >= 2
        cand_ip, cand_host = argv[0], argv[1]

        unless ipv4?(cand_ip)
          msg = ::I18n.t("messages.invalid_ip", default: "Invalid IPv4 address: %{ip}", ip: cand_ip)
          UiHelpers.error(ui, "#{UiHelpers.e(:error, no_emoji: no_emoji)} #{msg}")
          raise ArgumentError, msg
        end

        unless fqdn?(cand_host)
          msg = ::I18n.t("messages.invalid_host", default: "Invalid host/FQDN: %{host}", host: cand_host)
          UiHelpers.error(ui, "#{UiHelpers.e(:error, no_emoji: no_emoji)} #{msg}")
          raise ArgumentError, msg
        end

        argv.shift(2)
        return [cand_ip, cand_host]
      end

      if ipv4?(argv[0])
        msg = ::I18n.t("messages.missing_mapping",
          default: "Provide both IP and FQDN (e.g. `vagrant hosts apply 1.2.3.4 example.test`).")
        UiHelpers.error(ui, "#{UiHelpers.e(:error, no_emoji: no_emoji)} #{msg}")
        raise ArgumentError, msg
      end

      [nil, nil]
    end

    def ipv4?(s)
      return false unless s.is_a?(String) && s =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/
      s.split(".").all? { |x| (0..255).cover?(x.to_i) }
    end

    def fqdn?(s)
      return false unless s.is_a?(String)
      s = s.strip
      return false if s.empty? || s.size > 253 || s.start_with?(".") || s.end_with?(".")
      s.split(".").all? { |lab| lab =~ /\A[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\z/ }
    end

    def parse_mapping_from_argv!(argv)
      return [nil, nil] if argv.length < 2
      cand_ip, cand_host = argv[0], argv[1]
      if ipv4?(cand_ip) && cand_host !~ /\A-/
        argv.shift(2)
        [cand_ip, cand_host]
      else
        [nil, nil]
      end
    end

    def parse_remove_key_from_argv!(argv)
      return nil if argv.empty?
      cand = argv[0]
      if ipv4?(cand) || cand =~ /\A[a-zA-Z0-9\.\-]+\z/
        argv.shift(1)
        cand
      else
        nil
      end
    end

    def compute_entries(machine, cfg)
      entries = {}

      (cfg.domains || {}).each do |domain, ip|
        next if domain.to_s.strip.empty?
        next if ip.to_s.strip.empty?
        entries[domain] = ip
      end

      if cfg.domain && !cfg.domain.strip.empty? && !entries.key?(cfg.domain)
        ip = cfg.ip.to_s.strip
        ip = Util::Docker.ip_for_container(cfg.container_name).to_s.strip if ip.empty? && !cfg.container_name.to_s.strip.empty?
        entries[cfg.domain] = ip unless ip.empty?
      end

      entries
    end

    def print_help(ui, topic: nil, no_emoji: false)
      return print_topic_help(ui, topic.to_s.downcase.strip, no_emoji: no_emoji) if topic && !topic.to_s.strip.empty?

      emoji_info = UiHelpers.e(:info, no_emoji: no_emoji)
      title = ::I18n.t("help.title",  default: "Vagrant Docker Hosts Manager")
      UiHelpers.say(ui, "#{emoji_info} #{title}")

      UiHelpers.say(ui, ::I18n.t("help.usage",
        default: "Usage: vagrant hosts <apply|remove|view|help|version> [options]"))
      UiHelpers.say(ui, "")

      UiHelpers.say(ui, ::I18n.t("help.commands_header", default: "Commands:"))
      cmds = ::I18n.t("help.commands", default: {})
      cmds = {} unless cmds.is_a?(Hash)
      cmds.each_value { |line| UiHelpers.say(ui, "  #{line}") }

      UiHelpers.say(ui, "")
      UiHelpers.say(ui, ::I18n.t("help.options_header", default: "Options:"))
      optsh = ::I18n.t("help.options", default: {})
      optsh = {} unless optsh.is_a?(Hash)
      optsh.each_value { |line| UiHelpers.say(ui, "  #{line}") }

      topics = (::I18n.t("help.topic", default: {}).is_a?(Hash) ? ::I18n.t("help.topic").keys.map(&:to_s) : [])
      topics = %w[apply remove view version help] if topics.empty?

      UiHelpers.say(ui, "")
      UiHelpers.say(ui, ::I18n.t("help.topics_header", default: "Help topics:"))
      UiHelpers.say(ui, "  vagrant hosts help <#{topics.join('|')}>")
    end

    def print_topic_help(ui, topic, no_emoji: false)
      base   = "help.topic.#{topic}"
      wrench = UiHelpers.e(:info, no_emoji: no_emoji)

      title      = ::I18n.t("#{base}.title",       default: topic)
      usage      = ::I18n.t("#{base}.usage",       default: nil)
      desc       = ::I18n.t("#{base}.description", default: nil)
      opts_hash  = ::I18n.t("#{base}.options",     default: {})
      examples   = ::I18n.t("#{base}.examples",    default: [])

      t_head   = ::I18n.t("help.topic_header",    default: "Help: vagrant hosts %{topic}", topic: topic)
      t_usage  = ::I18n.t("help.usage_label",     default: "Usage:")
      t_desc   = ::I18n.t("help.description_label", default: "Description:")
      t_opts   = ::I18n.t("help.options_label",   default: "Options:")
      t_exs    = ::I18n.t("help.examples_label",  default: "Examples:")

      UiHelpers.say(ui, "#{wrench} #{t_head}")

      UiHelpers.say(ui, "  #{t_usage}")
      UiHelpers.say(ui, "    #{usage || "vagrant hosts #{topic} [options]"}")

      if desc && !desc.strip.empty?
        UiHelpers.say(ui, "  #{t_desc}")
        UiHelpers.say(ui, "    #{desc}")
      end

      if opts_hash.is_a?(Hash) && !opts_hash.empty?
        UiHelpers.say(ui, "  #{t_opts}")
        opts_hash.each_value { |line| UiHelpers.say(ui, "    #{line}") }
      end

      if examples.is_a?(Array) && !examples.empty?
        UiHelpers.say(ui, "  #{t_exs}")
        examples.each { |ex| UiHelpers.say(ui, "    #{ex}") }
      end
    end
  end
end
