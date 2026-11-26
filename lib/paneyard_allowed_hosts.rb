require "ipaddr"
require "uri"

# The Host names this app answers to, for `config.hosts` (production) and the
# MCP transports' own DNS-rebinding check.
#
# There is no auth (single-operator local tool), and Puma binding 127.0.0.1
# does not stop DNS rebinding: a page the operator visits can re-point its
# own name at 127.0.0.1 and become same-origin with the app. Its requests
# still carry its own name in `Host`, so answering loopback names only is
# what closes that.
#
# Needed by config/environments/production.rb before autoloading exists, so
# config/application.rb requires it and the autoloader ignores it.
module PaneyardAllowedHosts
  # "[::1]" as well as the IPAddr: Rails only unbrackets an IPv6 Host that
  # has a port.
  LOOPBACK = [ "localhost", IPAddr.new("127.0.0.1"), IPAddr.new("::1"), "[::1]" ].freeze

  module_function

  # Loopback, plus the names an operator has deliberately put in front of the
  # app: PANEYARD_ALLOWED_HOSTS (comma-separated; Rails' `config.hosts`
  # syntax, so a leading dot also allows subdomains), the host of
  # PANEYARD_RAILS_URL, the URL sessions are told to reach /mcp on, and the
  # host of PANEYARD_RUNNER_URL, a runner-only process's tailnet URL. IP
  # literals become IPAddr, which is how Rails matches `[::1]:3000`.
  def hosts(env = ENV)
    LOOPBACK + extra(env).flat_map do |host|
      address = ip(host)
      next [ host ] unless address

      address.ipv6? ? [ address, "[#{host}]" ] : [ address ]
    end
  end

  # Bare names, as the MCP transports' `allowed_hosts:` takes them.
  def extra(env = ENV)
    listed = env.fetch("PANEYARD_ALLOWED_HOSTS", "").split(",")
      .map { |host| host.strip.delete_prefix("[").delete_suffix("]") }.reject(&:empty?)
    listed += %w[PANEYARD_RAILS_URL PANEYARD_RUNNER_URL].filter_map { |key| url_host(env[key]) }
    listed.map(&:downcase).uniq
  end

  def url_host(url)
    host = URI(url.to_s).hostname
    host.nil? || host.empty? ? nil : host
  rescue URI::InvalidURIError
    nil
  end

  def ip(host)
    IPAddr.new(host)
  rescue IPAddr::InvalidAddressError
    nil
  end
end
