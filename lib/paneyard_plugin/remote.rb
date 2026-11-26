require "net/http"
require "socket"
require "uri"

module PaneyardPlugin
  # A Paneyard running on another machine, named by PANEYARD_REMOTE_URL in
  # the plugin's .env, which this herdr's actions drive instead of starting a
  # daemon of their own. Its sessions run in that machine's herdr, against its
  # own checkouts, so a path crosses between the two: PANEYARD_REMOTE_PATHS
  # ("local=remote" prefixes, comma-separated, e.g. /Users/me=/home/me) says
  # where a checkout here is there.
  #
  # With PANEYARD_RUNNER_URL as well, this machine also hosts that
  # Paneyard's sessions: the plugin runs a runner-only process here
  # (bin/runner) and registers it there (register_runner) under runner_name,
  # with each of its workspaces that has a checkout here -- found through the
  # same path prefixes -- as that runner's checkout.
  class Remote
    # nil unless PANEYARD_REMOTE_URL is set.
    def self.from(settings)
      url = settings["PANEYARD_REMOTE_URL"].to_s.strip.delete_suffix("/")
      return if url.empty?

      new(url, settings["PANEYARD_REMOTE_PATHS"].to_s,
        runner_url: settings["PANEYARD_RUNNER_URL"], runner_name: settings["PANEYARD_RUNNER_NAME"])
    end

    attr_reader :url, :prefixes, :runner_url

    def initialize(url, prefixes, runner_url: nil, runner_name: nil)
      @url = url
      @runner_url = runner_url.to_s.strip.delete_suffix("/")
      @runner_url = nil if @runner_url.empty?
      @runner_name = runner_name.to_s.strip
      @prefixes = prefixes.split(",").filter_map do |pair|
        local, remote = pair.split("=", 2).map { |path| path.to_s.strip.delete_suffix("/") }
        [ local, remote ] unless local.to_s.empty? || remote.to_s.empty?
      end
    end

    def host
      URI(url).host || url
    rescue URI::InvalidURIError
      url
    end

    def to_remote(path) = translate(path, prefixes)
    def to_local(path) = translate(path, prefixes.map(&:reverse))

    # Whether this machine hosts sessions too (PANEYARD_RUNNER_URL).
    def runner?
      !runner_url.nil?
    end

    # The name it registers under: PANEYARD_RUNNER_NAME, else this machine's
    # short hostname (never "local", the orchestrator's own runner).
    def runner_name
      name = @runner_name.empty? ? Socket.gethostname.split(".").first.to_s.downcase : @runner_name
      name == "local" ? "#{name}-remote" : name
    end

    # [{ "workspace", "path" }] for each workspace (as Client#workspaces
    # lists them, with paths already on this machine) checked out here.
    def checkouts(workspaces)
      workspaces.filter_map do |workspace|
        path = workspace["repositoryPath"]
        next unless path.is_a?(String) && File.exist?(File.join(path, ".git"))

        { "workspace" => workspace.fetch("name"), "path" => path }
      end
    end

    # Its /up, which names the service so that some other app's /up is not
    # mistaken for it.
    def up?
      uri = URI("#{url}/up")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) do |http|
        http.get(uri.request_uri)
      end
      response.is_a?(Net::HTTPSuccess) && response["X-Paneyard-Service"] == "paneyard"
    rescue StandardError
      false
    end

    private

    # The first prefix that `path` is, or is under, swapped for its pair;
    # anything else as it is.
    def translate(path, pairs)
      return path unless path.is_a?(String)

      pairs.each do |from, to|
        return to + path.delete_prefix(from) if path == from || path.start_with?("#{from}/")
      end
      path
    end
  end
end
