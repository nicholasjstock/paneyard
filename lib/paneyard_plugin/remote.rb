require "net/http"
require "uri"

module PaneyardPlugin
  # A Paneyard running on another machine, named by PANEYARD_REMOTE_URL in
  # the plugin's .env, which this herdr's actions drive instead of starting a
  # daemon of their own. Its sessions run in that machine's herdr, against its
  # own checkouts, so a path crosses between the two: PANEYARD_REMOTE_PATHS
  # ("local=remote" prefixes, comma-separated, e.g. /Users/me=/home/me) says
  # where a checkout here is there.
  class Remote
    # nil unless PANEYARD_REMOTE_URL is set.
    def self.from(settings)
      url = settings["PANEYARD_REMOTE_URL"].to_s.strip.delete_suffix("/")
      return if url.empty?

      new(url, settings["PANEYARD_REMOTE_PATHS"].to_s)
    end

    attr_reader :url, :prefixes

    def initialize(url, prefixes)
      @url = url
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
