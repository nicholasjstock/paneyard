require "json"

module Orchestrator
  module Runner
    # What a runner-only process (bin/runner, PANEYARD_ROLE=runner) serves at
    # /runner: this machine's Runner::Local, for the orchestrator's
    # Runner::Remote on another machine, as JSON (Runner::Wire).
    #
    # It answers Wire::METHODS and nothing else, with plain data in and out;
    # a runner error goes back as its class name and message rather than an
    # HTTP error, so the caller raises the same Runner::Error,
    # Runner::Unreachable or Runner::LaunchError it would have in process.
    #
    # No auth, like /mcp/admin (docs/multi-runner-plan.md, "No auth on the
    # tailnet"): Puma binds loopback, `tailscale serve` exposes it, and
    # config.hosts answers loopback names plus PANEYARD_ALLOWED_HOSTS only,
    # which stops DNS rebinding. A browser page could still aim a simple
    # cross-origin POST at 127.0.0.1, so this takes only application/json
    # (which a browser cannot send cross-origin without a CORS preflight that
    # nothing here answers) and refuses anything carrying an Origin.
    class Endpoint
      def initialize(runner: nil)
        @runner = runner
      end

      def call(env)
        request = Rack::Request.new(env)
        return reply(404, error("Error", "no such runner route #{request.path_info}")) unless request.path_info == "/call"
        return reply(405, error("Error", "POST only")) unless request.post?
        return reply(403, error("Error", "browsers may not call a runner")) if env["HTTP_ORIGIN"].present?
        return reply(415, error("Error", "Content-Type must be application/json")) unless request.media_type == "application/json"

        body = parse(request)
        return reply(400, error("Error", "the body must be a JSON object with a method")) unless body

        name = body["method"].to_s
        return reply(400, error("Error", "#{name.inspect} is not a runner method")) unless Wire::METHODS.include?(name)

        reply(200, dispatch(name, body))
      end

      private

      def runner
        @runner || Runner.local
      end

      def dispatch(name, body)
        args = Wire.decode_args(body["args"])
        kwargs = Wire.decode_kwargs(body["kwargs"])
        { "ok" => true, "result" => Wire.encode(runner.public_send(name, *args, **kwargs)) }
      rescue Runner::Error => failure
        { "ok" => false, "error" => Wire.error_payload(failure) }
      rescue ArgumentError, KeyError, TypeError, Sandbox::Violation => failure
        { "ok" => false, "error" => Wire.error_payload(Error.new("#{name}: #{failure.message}")) }
      rescue StandardError => failure
        Rails.logger.error("[Runner::Endpoint] #{name} raised #{failure.class}: #{failure.message}\n#{Array(failure.backtrace).first(10).join("\n")}")
        { "ok" => false, "error" => Wire.error_payload(Error.new("#{name} failed on the runner: #{failure.class}: #{failure.message}")) }
      end

      def parse(request)
        body = JSON.parse(request.body.read)
        body.is_a?(Hash) && body["method"].is_a?(String) ? body : nil
      rescue JSON::ParserError
        nil
      end

      def error(klass, message)
        { "ok" => false, "error" => { "class" => klass, "message" => message } }
      end

      def reply(status, payload)
        [ status, { "content-type" => "application/json", "cache-control" => "no-store" }, [ JSON.generate(payload) ] ]
      end
    end
  end
end
