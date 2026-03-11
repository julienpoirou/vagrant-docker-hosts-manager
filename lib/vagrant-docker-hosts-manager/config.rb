# frozen_string_literal: true

module VagrantDockerHostsManager
  class Config < Vagrant.plugin("2", :config)
    attr_accessor :domains
    attr_accessor :domain
    attr_accessor :container_name
    attr_accessor :ip
    attr_accessor :locale
    attr_accessor :verbose

    def initialize
      @domains        = {}
      @domain         = nil
      @container_name = nil
      @ip             = nil
      @locale         = nil
      @verbose        = false
    end

    def finalize!; end

    def validate(_machine)
      errors = []

      if (@domains.nil? || @domains.empty?) && (@domain.nil? || @domain.strip.empty?)
        errors << "You must configure at least one domain: " \
                  "`config.docker_hosts.domain = \"example.test\"` or set " \
                  "`config.docker_hosts.domains = {\"example.test\" => \"172.28.0.10\"}`"
      end

      unless @domains.is_a?(Hash)
        errors << "`domains` must be a Hash of { \\\"domain\\\" => \\\"ip\\\" }"
      end

      if @ip && !@ip.to_s.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
        errors << "`ip` must be IPv4 like 172.28.0.10"
      end

      if @locale && !%w[en fr].include?(@locale.to_s[0, 2].downcase)
        errors << "`locale` must be 'en' or 'fr'."
      end

      { "vagrant-docker-hosts-manager" => errors }
    end
  end
end
