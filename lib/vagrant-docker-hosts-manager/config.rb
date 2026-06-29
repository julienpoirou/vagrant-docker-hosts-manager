# frozen_string_literal: true

module VagrantDockerHostsManager
  # Vagrant configuration for managed host entries.
  #
  # @!attribute domains
  #   @return [Hash{String=>String}] Mapping of domain names to IP addresses.
  # @!attribute domain
  #   @return [String, nil] Single domain to resolve from `ip` or `container_name`.
  # @!attribute container_name
  #   @return [String, nil] Docker container used for automatic IP discovery.
  # @!attribute ip
  #   @return [String, nil] Static IPv4 address for `domain`.
  # @!attribute locale
  #   @return [String, nil] Optional locale code.
  class Config < Vagrant.plugin("2", :config)
    attr_accessor :domains
    attr_accessor :domain
    attr_accessor :container_name
    attr_accessor :ip
    attr_accessor :locale
    attr_accessor :verbose

    def initialize
      @domains        = UNSET_VALUE
      @domain         = UNSET_VALUE
      @container_name = UNSET_VALUE
      @ip             = UNSET_VALUE
      @locale         = UNSET_VALUE
      @verbose        = UNSET_VALUE
    end

    def finalize!
      @domains        = {}    if @domains == UNSET_VALUE
      @domain         = nil   if @domain == UNSET_VALUE
      @container_name = nil   if @container_name == UNSET_VALUE
      @ip             = nil   if @ip == UNSET_VALUE
      @locale         = nil   if @locale == UNSET_VALUE
      @verbose        = false if @verbose == UNSET_VALUE
    end

    def validate(_machine)
      errors = []

      return { "vagrant-docker-hosts-manager" => errors } unless configured?

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

    private

    def configured?
      (@domains.is_a?(Hash) && !@domains.empty?) ||
        present?(@domain) || present?(@container_name) || present?(@ip)
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
