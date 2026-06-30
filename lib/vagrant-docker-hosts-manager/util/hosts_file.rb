# frozen_string_literal: true

require "base64"
require "tempfile"
require "time"
require "open3"

require_relative "../helpers"
require_relative "docker"
require_relative "verbose"

module VagrantDockerHostsManager
  module Util
    class HostsFile
      POSIX_PATH         = "/etc/hosts"
      WIN_SYS32_PATH     = "C:/Windows/System32/drivers/etc/hosts"
      WIN_SYSNATIVE_PATH = "C:/Windows/Sysnative/drivers/etc/hosts"
      WIN_SYSWOW64_PATH  = "C:/Windows/SysWOW64/drivers/etc/hosts"

      BLOCK_START_RE = /^\s*#\s*>>>\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*>>>\s*$/i
      BLOCK_STOP_RE  = /^\s*#\s*<<<\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*<<<\s*$/i
      ENTRY_RE       = /\A\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([^\s#]+)/

      def initialize(env, owner_id:)
        @env      = env || {}
        @owner_id = owner_id.to_s
        @ui       = env[:ui]
      end

      def override_path
        p = ENV["VDHM_HOSTS_PATH"].to_s.strip
        p.empty? ? nil : p
      end

      def path_candidates
        # VDHM_HOSTS_PATH overrides the default location on every platform
        # (used by tests and power users); honor it before anything else.
        return [override_path] if override_path
        return [POSIX_PATH] unless Gem.win_platform?

        # Sysnative lets a 32-bit Ruby process reach the real System32 hosts
        # file on 64-bit Windows; keep it before System32/SysWOW64.
        [WIN_SYSNATIVE_PATH, WIN_SYS32_PATH, WIN_SYSWOW64_PATH]
      end

      def real_path
        cand = path_candidates
        UiHelpers.debug(@ui, "Candidates: #{cand.inspect}")
        found = cand.find { |p| File.exist?(p) } || cand.first
        UiHelpers.debug(@ui, "Selected path: #{found}")
        found
      end

      def printable_path
        p = real_path
        Gem.win_platform? ? p.tr("/", "\\") : p
      end

      def block_name
        "vagrant-docker-hosts-manager #{@owner_id}"
      end

      def block_markers
        start = "# >>> #{block_name} (managed) >>>"
        stop  = "# <<< #{block_name} (managed) <<<"
        [start, stop]
      end

      def detect_newline(str)
        return "\r\n" if Gem.win_platform?
        str.include?("\r\n") ? "\r\n" : "\n"
      end

      def compose_block(entries, newline: "\n")
        start, stop = block_markers
        ts = begin
               Time.now.utc.iso8601
             rescue StandardError
               Time.now.utc.to_s
             end

        header = [
          start,
          "# Managed by Vagrant - do not edit manually",
          "# Timestamp: #{ts}"
        ]
        body = entries.map { |d, ip| "#{ip} #{d}" }

        (header + body + [stop]).join(newline) + newline
      end

      def pairs_to_hash(pairs)
        h = {}
        pairs.each do |ip, fqdn, _owner|
          ip   = ip.to_s.strip
          fqdn = fqdn.to_s.strip
          next if ip.empty? || fqdn.empty?
          h[fqdn] = ip
        end
        h
      end

      def normalize_entries(entries)
        entries
          .each_with_object({}) { |(d, ip), h| h[d.to_s.strip] = ip.to_s.strip }
          .reject { |d, ip| d.empty? || ip.empty? }
          .sort_by { |d, _ip| d }
          .to_h
      end

      def ensure_trailing_newline(str, nl)
        return "" if str.nil? || str.empty?
        str.end_with?(nl) ? str : (str + nl)
      end

      # Applies managed host entries to the hosts file.
      #
      # Rewrites only this plugin's managed block and preserves unmanaged lines.
      # Entries are normalized and sorted so repeated runs converge to the same
      # file content.
      #
      # @param entries [Hash{String=>String}] Mapping of FQDN to IP address.
      # @return [Integer] Number of managed entries present after applying changes.
      # @raise [RuntimeError] When elevated writes fail.
      def apply(entries)
        entries = normalize_entries(entries)
        if entries.empty?
          UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
            ::I18n.t("vdhm.messages.no_entries", default: "No hosts entries configured."))
          return 0
        end

        base    = read
        newline = detect_newline(base)
        cleaned = remove_block_from(base)
        cleaned = ensure_trailing_newline(cleaned, newline)

        existing_map = pairs_to_hash(list_pairs(:current))

        added = {}
        updated = {}
        unchanged = {}

        entries.each do |fqdn, ip|
          prev = existing_map[fqdn]
          if prev.nil?
            added[fqdn] = ip
            existing_map[fqdn] = ip
          elsif prev == ip
            unchanged[fqdn] = ip
          else
            updated[fqdn] = { from: prev, to: ip }
            existing_map[fqdn] = ip
          end
        end

        if added.empty? && updated.empty?
          UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
            ::I18n.t("vdhm.messages.no_change", default: "Nothing to apply. Already up-to-date."))
          return existing_map.size
        end

        merged  = normalize_entries(existing_map)
        content = cleaned + compose_block(merged, newline: newline)
        write(content)

        UiHelpers.say(@ui, "#{UiHelpers.e(:success)} " +
          ::I18n.t("vdhm.messages.applied", default: "Hosts entries applied."))
        UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
          ::I18n.t("vdhm.messages.apply_summary",
                  default: "Added: %{a}, Updated: %{u}, Unchanged: %{s}",
                  a: added.size, u: updated.size, s: unchanged.size))
        merged.size
      end

      # Removes matching entries from the current owner's managed block.
      #
      # With no filters this falls back to removing the whole current-owner block.
      #
      # @param ips [Array<String>] IP addresses to remove.
      # @param domains [Array<String>] Domain names to remove.
      # @return [Integer] Number of removed entries, or 1 when a whole block was removed.
      def remove_entries!(ips: [], domains: [])
        ips     = Array(ips).map(&:to_s).reject(&:empty?)
        domains = Array(domains).map(&:to_s).reject(&:empty?)
        return (remove! ? 1 : 0) if ips.empty? && domains.empty?

        pairs  = list_pairs(:current)
        before = pairs.length
        return 0 if before.zero?

        filtered = pairs.reject do |ip, fqdn, _|
          ips.include?(ip.to_s) || domains.include?(fqdn.to_s)
        end

        removed_count = before - filtered.length
        if removed_count <= 0
          UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
            ::I18n.t("vdhm.messages.remove_none",
              default: "No matching entry to remove."))
          return 0
        end

        base    = read
        newline = detect_newline(base)
        cleaned = remove_block_from(base)

        if filtered.empty?
          write(cleaned)
        else
          cleaned = ensure_trailing_newline(cleaned, newline)
          remaining_map = normalize_entries(pairs_to_hash(filtered))
          content = cleaned + compose_block(remaining_map, newline: newline)
          write(content)
        end

        UiHelpers.say(
          @ui,
          "#{UiHelpers.e(:broom)} " +
            ::I18n.t(
              "vdhm.messages.removed_count",
              default: "%{count} entries removed.",
              count: removed_count
            )
        )
        removed_count
      end

      # Removes the current owner's managed hosts block.
      #
      # @return [Boolean] Whether a block was removed.
      def remove!
        content = read
        newc = remove_block_from(content)
        removed = (newc != content)
        write(newc) if removed

        UiHelpers.say(@ui, removed ?
          "#{UiHelpers.e(:broom)} " + ::I18n.t("vdhm.messages.cleaned", default: "Managed hosts entries removed.") :
          "#{UiHelpers.e(:info)} "  + ::I18n.t("vdhm.messages.nothing_to_clean", default: "Nothing to clean."))
        removed
      end

      # Removes every block managed by this plugin, regardless of owner.
      #
      # @return [Boolean] Whether any managed block was removed.
      def remove_all_managed!
        content = read
        newc = strip_managed_blocks(content)
        removed = (newc != content)
        write(newc) if removed

        UiHelpers.say(@ui, removed ?
          "#{UiHelpers.e(:broom)} " + ::I18n.t("vdhm.messages.cleaned_all", default: "All managed hosts blocks removed.") :
          "#{UiHelpers.e(:info)} "  + ::I18n.t("vdhm.messages.nothing_to_clean", default: "Nothing to clean."))
        removed
      end

      def strip_managed_blocks(content)
        removing = false
        content.lines.reject do |line|
          if line.match?(BLOCK_START_RE)
            removing = true
            true
          elsif line.match?(BLOCK_STOP_RE)
            removing = false
            true
          else
            removing
          end
        end.join
      end

      def read
        # Hosts files are often edited by Windows tools with BOMs or legacy
        # encodings; normalize to UTF-8 before parsing managed blocks.
        pth = real_path
        UiHelpers.debug(@ui, "read(#{pth})")

        data = nil

        begin
          data = File.binread(pth)
          UiHelpers.debug(@ui, "File.binread ok, bytes=#{data.bytesize}, encoding=#{data.encoding}")
        rescue StandardError => e
          UiHelpers.debug(@ui, "File.binread error: #{e.class}: #{e.message}")
          data = nil
        end

        if (data.nil? || data.empty?) && Gem.win_platform?
          ps_path = pth.gsub("'", "''")
          ps_cmd  = "Get-Content -LiteralPath '#{ps_path}' -Raw"
          Verbose.log("powershell -Command #{ps_cmd}")
          out, err, st = Open3.capture3("powershell", "-NoProfile", "-NonInteractive", "-Command", ps_cmd)
          if st.success?
            data = out
            UiHelpers.debug(@ui, "Fallback PS read ok, bytes=#{data.bytesize}, encoding=#{data.encoding}")
          else
            UiHelpers.debug(@ui, "Fallback PS read failed: #{err}")
          end
        end

        return "" if data.nil?

        data = data.dup
        data.force_encoding(Encoding::BINARY)

        if data.start_with?("\xEF\xBB\xBF".b)
          UiHelpers.debug(@ui, "BOM detected, stripping")
          data = data.byteslice(3, data.bytesize - 3) || "".b
        end

        begin
          data = data.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
          UiHelpers.debug(@ui, "Transcoded to UTF-8 (direct), encoding=#{data.encoding}")
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
          UiHelpers.debug(@ui, "Direct UTF-8 encode failed: #{e.class}: #{e.message}, trying Windows-1252")
          begin
            data = data
                   .force_encoding("Windows-1252")
                   .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
            UiHelpers.debug(@ui, "Transcoded via Windows-1252 -> UTF-8, encoding=#{data.encoding}")
          rescue StandardError => e2
            UiHelpers.debug(@ui, "Windows-1252 fallback failed: #{e2.class}: #{e2.message}")
            data = data.force_encoding(Encoding::UTF_8)
          end
        end

        if UiHelpers.debug_enabled?
          head = data.lines.first(8) rescue []
          UiHelpers.debug(@ui, "Head(8):\n" + head.join)
        end

        data
      rescue StandardError => e
        UiHelpers.debug(@ui, "read() fatal: #{e.class}: #{e.message}")
        ""
      end

      def each_managed_entry(scope = :all)
        # A single scanner powers both current-owner and all-owner cleanup paths
        # so marker parsing rules stay identical.
        return enum_for(:each_managed_entry, scope) unless block_given?

        content = read
        return if content.to_s.empty?

        in_block = false
        owner    = nil

        content.each_line.with_index(1) do |raw, idx|
          line = raw.delete_suffix("\n").delete_suffix("\r")

          if (m = line.match(BLOCK_START_RE))
            in_block = true
            owner    = m[1].to_s.strip
            UiHelpers.debug(@ui, "start block(owner=#{owner}) at line #{idx}")
            next
          end

          if line.match?(BLOCK_STOP_RE)
            UiHelpers.debug(@ui, "stop  block(owner=#{owner}) at line #{idx}") if in_block
            in_block = false
            owner    = nil
            next
          end

          next unless in_block
          next unless scope == :all || owner == @owner_id

          if (m = line.match(ENTRY_RE))
            UiHelpers.debug(@ui, "  ip line: #{m[1]} #{m[2]} (owner=#{owner})")
            yield m[1], m[2], owner
          end
        end
      end

      def list_pairs(scope = :all)
        pairs = []
        each_managed_entry(scope) { |ip, fqdn, owner| pairs << [ip, fqdn, owner] }
        UiHelpers.debug(@ui, "list_pairs found #{pairs.length} pair(s)")
        pairs
      end

      def entries_in_blocks(scope = :current)
        each_managed_entry(scope).with_object({}) do |(ip, fqdn, _owner), out|
          arr = (out[fqdn] ||= [])
          arr << ip unless arr.include?(ip)
        end
      end

      def remove_block_from(content)
        start, stop = block_markers
        removing = false
        content.lines.reject do |line|
          if line.start_with?(start)
            removing = true
            true
          elsif line.start_with?(stop)
            removing = false
            true
          else
            removing
          end
        end.join
      end

      def elevated?
        if Gem.win_platform?
          cmd = %q{
            (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent()
            )).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
          }.strip
          Verbose.log("powershell -Command (check administrator role)")
          out, _err, st = Open3.capture3("powershell", "-NoProfile", "-NonInteractive", "-Command", cmd)
          st.success? && out.to_s.strip.downcase == "true"
        else
          begin
            Process.euid == 0
          rescue StandardError
            false
          end
        end
      end

      def write(content)
        Gem.win_platform? ? write_windows(content) : write_posix(content)
      end

      def write_posix(content)
        File.binwrite(real_path, content)
      rescue Errno::EACCES
        tf = Tempfile.new("vdhm-hosts")
        begin
          tf.binmode
          tf.write(content); tf.flush
          Verbose.log("sudo", "cp", tf.path, real_path)
          system("sudo", "cp", tf.path, real_path) || raise("sudo copy failed")
        ensure
          tf.close!
        end
      end

      def write_windows(content)
        # Try a direct write first; fall back to UAC only when the hosts file
        # rejects it. Base64/UTF-16LE keeps PowerShell quoting predictable.
        b64  = Base64.strict_encode64(
          content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        )
        dest = real_path.gsub("'", "''")

        ps = <<~POW
          $ErrorActionPreference = "Stop"
          try {
            $bytes = [System.Convert]::FromBase64String('#{b64}')
            [System.IO.File]::WriteAllBytes('#{dest}', $bytes)
            exit 0
          } catch {
            exit 1
          }
        POW
        encoded = Base64.strict_encode64(ps.encode("UTF-16LE"))

        Verbose.log("powershell -EncodedCommand (write hosts file: #{real_path})")
        _out, _err, st = Open3.capture3("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded)
        return if st.success?

        elev_ps = <<~POW
          $ErrorActionPreference = 'Stop'
          try {
            $p = Start-Process PowerShell -Verb RunAs -Wait -PassThru -ArgumentList '-NonInteractive','-NoProfile','-EncodedCommand','#{encoded}'
            exit $p.ExitCode
          } catch {
            exit 1
          }
        POW
        elev_encoded = Base64.strict_encode64(elev_ps.encode("UTF-16LE"))
        Verbose.log("powershell -EncodedCommand (elevated write hosts file via RunAs: #{real_path})")
        system("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", elev_encoded) ||
          raise("elevated write failed")
      end
    end
  end
end
