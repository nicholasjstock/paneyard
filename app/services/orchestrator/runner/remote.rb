require "json"
require "net/http"
require "openssl"
require "uri"

module Orchestrator
  module Runner
    # A runner on another machine: the same public methods as Runner::Local,
    # each one a POST to that machine's runner-only process (bin/runner,
    # Runner::Endpoint), with the same plain data in and out (Runner::Wire).
    #
    # Errors come back as what the runner raised: Runner::Error,
    # Runner::LaunchError (with its lost-prompt records) or
    # Runner::Unreachable (its herdr never answered). A runner that cannot be
    # reached at all -- refused, timed out, a proxy's 502 because the process
    # is down, anything that is not the runner's own answer -- is
    # Runner::Unreachable too, which says nothing about its sessions, so
    # RunSessionRunner.refresh! treats a network blip as a blip.
    class Remote
      OPEN_TIMEOUT = 5
      # Most calls answer in well under a second. Launching an agent waits
      # for the CLI to come up and take its prompt (with restarts:
      # SessionLauncher), creating a project clones and pushes, and saving
      # transcripts copies files, so the ceiling is generous; a call that
      # hits it is Unreachable, not a failure of the thing asked for.
      READ_TIMEOUT = 60
      SLOW_READ_TIMEOUT = 600
      SLOW_METHODS = %w[launch_agent create_project provision_worktree save_transcripts available_models].freeze

      attr_reader :name, :url

      def initialize(name:, url:)
        @name = name
        @url = url.to_s.delete_suffix("/")
      end

      def id
        "remote:#{name}"
      end

      Wire::METHODS.each do |method|
        define_method(method) { |*args, **kwargs| call(method, args, kwargs) }
      end

      private

      def call(method, args, kwargs)
        guard!
        uri = URI("#{url}#{Wire::PATH}")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate("method" => method, "args" => Wire.encode(args), "kwargs" => Wire.encode(kwargs))
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT, read_timeout: read_timeout(method), write_timeout: OPEN_TIMEOUT) do |http|
          http.request(request)
        end
        answer(method, response)
      rescue URI::InvalidURIError, ArgumentError => error
        raise Error, "runner #{name.inspect} at #{url}: #{error.message}"
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error, Net::ProtocolError => error
        raise Unreachable, "runner #{name.inspect} at #{url} did not answer #{method}: #{error.class}: #{error.message}"
      end

      def answer(method, response)
        envelope = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          nil
        end
        unless envelope.is_a?(Hash) && envelope.key?("ok")
          raise Unreachable, "runner #{name.inspect} at #{url} answered #{method} with HTTP #{response.code}, " \
            "not a runner response: #{response.body.to_s[0, 200]}"
        end
        raise Wire.error_from(envelope.fetch("error", {})) unless envelope["ok"]

        Wire.decode(envelope["result"])
      end

      def read_timeout(method)
        SLOW_METHODS.include?(method) ? SLOW_READ_TIMEOUT : READ_TIMEOUT
      end

      def guard!
        Sandbox.guard_runner_url!(url)
      rescue Sandbox::Violation => error
        raise Error, error.message
      end
    end
  end
end
