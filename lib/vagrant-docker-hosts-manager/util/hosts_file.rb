# frozen_string_literal: true

require "base64"
require "tempfile"
require "time"
require "open3"

require_relative "../helpers"
require_relative "docker"

module VagrantDockerHostsManager
  module Util
    class HostsFile
      POSIX_PATH         = "/etc/hosts"
      WIN_SYS32_PATH     = "C:/Windows/System32/drivers/etc/hosts"
      WIN_SYSNATIVE_PATH = "C:/Windows/Sysnative/drivers/etc/hosts"
      WIN_SYSWOW64_PATH  = "C:/Windows/SysWOW64/drivers/etc/hosts"

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
        return [POSIX_PATH] unless Gem.win_platform?
        return [override_path] if override_path
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

      def apply(entries)
        entries = normalize_entries(entries)
        if entries.empty?
          UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
            ::I18n.t("messages.no_entries", default: "No hosts entries configured."))
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
            ::I18n.t("messages.no_change", default: "Nothing to apply. Already up-to-date."))
          return existing_map.size
        end

        merged  = normalize_entries(existing_map)
        content = cleaned + compose_block(merged, newline: newline)
        write(content)

        UiHelpers.say(@ui, "#{UiHelpers.e(:success)} " +
          ::I18n.t("messages.applied", default: "Hosts entries applied."))
        UiHelpers.say(@ui, "#{UiHelpers.e(:info)} " +
          ::I18n.t("messages.apply_summary",
                  default: "Added: %{a}, Updated: %{u}, Unchanged: %{s}",
                  a: added.size, u: updated.size, s: unchanged.size))
        merged.size
      end

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
            ::I18n.t("messages.remove_none",
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
              "messages.removed_count",
              default: "%{count} entries removed.",
              count: removed_count
            )
        )
        removed_count
      end

      def remove!
        content = read
        newc = remove_block_from(content)
        removed = (newc != content)
        write(newc) if removed

        UiHelpers.say(@ui, removed ?
          "#{UiHelpers.e(:broom)} " + ::I18n.t("messages.cleaned", default: "Managed hosts entries removed.") :
          "#{UiHelpers.e(:info)} "  + ::I18n.t("messages.nothing_to_clean", default: "Nothing to clean."))
        removed
      end

      def read
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

      def list_pairs(scope = :all)
        content = read
        return [] if content.to_s.empty?

        start_re = /^\s*#\s*>>>\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*>>>\s*$/i
        stop_re  = /^\s*#\s*<<<\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*<<<\s*$/i
        ip_re    = /^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([^\s#]+)/

        out      = []
        in_block = false
        owner    = nil

        content.each_line.with_index(1) do |raw, idx|
          line = raw.delete_suffix("\n").delete_suffix("\r")

          if (m = line.match(start_re))
            in_block = true
            owner    = m[1].to_s.strip
            UiHelpers.debug(@ui, "start block(owner=#{owner}) at line #{idx}")
            next
          end

          if (m = line.match(stop_re))
            UiHelpers.debug(@ui, "stop  block(owner=#{owner}) at line #{idx}") if in_block
            in_block = false
            owner    = nil
            next
          end

          next unless in_block
          next unless scope == :all || owner == @owner_id

          if (m = line.match(ip_re))
            ip, fqdn = m[1], m[2]
            out << [ip, fqdn, owner]
            UiHelpers.debug(@ui, "  ip line: #{ip} #{fqdn} (owner=#{owner})")
          end
        end

        UiHelpers.debug(@ui, "list_pairs found #{out.length} pair(s)")
        out
      end

      def entries_in_blocks(scope = :current)
        content = read
        return {} if content.to_s.empty?

        start_prefix = "# >>> vagrant-docker-hosts-manager "
        stop_prefix  = "# <<< vagrant-docker-hosts-manager "

        in_block = false
        owner    = nil
        out      = {}

        content.each_line do |raw|
          line = raw.sub(/\r?\n\z/, "")
          lstr = line.lstrip

          if lstr.start_with?(start_prefix)
            in_block = true
            tail  = lstr[start_prefix.length..-1].to_s
            owner = tail.split(" (managed)").first.to_s.strip
            next
          end

          if lstr.start_with?(stop_prefix)
            in_block = false
            owner    = nil
            next
          end

          next unless in_block
          next unless scope == :all || owner == @owner_id

          if lstr =~ /\A\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([^\s#]+)/
            ip, fqdn = $1, $2
            if out.key?(fqdn)
              arr = out[fqdn].is_a?(Array) ? out[fqdn] : [out[fqdn]]
              arr << ip unless arr.include?(ip)
              out[fqdn] = arr
            else
              out[fqdn] = [ip]
            end
          end
        end

        out
      end

      def managed_blocks_dump(scope = :all)
        content = read
        return "" if content.to_s.empty?

        start_re = /^\s*#\s*>>>\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*>>>\s*$/i
        stop_re  = /^\s*#\s*<<<\s*vagrant-docker-hosts-manager\s+(.+?)\s*\(managed\)\s*<<<\s*$/i

        buff     = []
        cur      = []
        in_block = false
        owner    = nil

        content.each_line do |raw|
          line = raw.delete_suffix("\n").delete_suffix("\r")

          if (m = line.match(start_re))
            in_block = true
            owner    = m[1].to_s.strip
            cur = [line]
            next
          end

          if in_block
            cur << line
            if line.match?(stop_re)
              if scope == :all || owner == @owner_id
                buff << cur.join("\n")
              end
              in_block = false
              owner    = nil
              cur      = []
            end
          end
        end

        buff.join("\n\n\n")
      end

      def current_entries
        entries_in_blocks(:current)
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
          system("sudo", "cp", tf.path, real_path) || raise("sudo copy failed")
        ensure
          tf.close!
        end
      end

      def write_windows(content)
        b64  = Base64.strict_encode64(
          content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        )
        dest = real_path.gsub("'", "''")

        ps = <<~POW
          $ErrorActionPreference = "Stop"
          $bytes = [System.Convert]::FromBase64String('#{b64}')
          [System.IO.File]::WriteAllBytes('#{dest}', $bytes)
        POW
        encoded = Base64.strict_encode64(ps.encode("UTF-16LE"))
        _out, _err, st = Open3.capture3("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded)
        return if st.success?

        elev_ps      = "Start-Process PowerShell -Verb RunAs -Wait " \
                       "-ArgumentList '-NonInteractive', '-NoProfile', '-EncodedCommand', '#{encoded}'"
        elev_encoded = Base64.strict_encode64(elev_ps.encode("UTF-16LE"))
        system("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", elev_encoded) ||
          raise("elevated write failed")
      end
    end
  end
end
