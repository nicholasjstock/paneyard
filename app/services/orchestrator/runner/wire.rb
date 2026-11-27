require "base64"

module Orchestrator
  module Runner
    # The JSON a remote runner call travels as, shared by both ends: the
    # orchestrator's Runner::Remote and the runner-only process's
    # Runner::Endpoint.
    #
    #   request   POST <runner url>/runner/call
    #             { "method", "args" => [...], "kwargs" => {...} }
    #   response  200 { "ok" => true, "result" => ... }
    #             200 { "ok" => false, "error" => { "class", "message",
    #                   "lost_prompts"? } }
    #
    # Only plain data crosses, as it already does in process (Runner::Local):
    # strings, numbers, booleans, nil, and hashes and arrays of them. A
    # binary string (an attachment's content, a moved run's bundle) is not valid JSON text, so it
    # crosses as { "$base64" => ... } and comes back out as a binary string.
    #
    # A session spec (open_session, launch_agent) is a symbol-keyed hash in
    # process; its top-level keys come back as symbols, and everything inside
    # it is string-keyed already (WorkspaceLayout.for).
    module Wire
      module_function

      PATH = "/runner/call".freeze
      BASE64 = "$base64".freeze

      # Runner::Local's whole interface, which is all a remote runner
      # answers: nothing here runs SQL, reads the database, or runs a command
      # the caller chose. spec/services/orchestrator/runner/wire_spec.rb keeps
      # it equal to Local's public methods. `id` is not here: a Remote names
      # itself.
      METHODS = %w[
        ping
        provision_worktree base_branch_problem branch_exists? branch_merged? verify_job_finished!
        worktree_registered? release_worktree remove_worktree reclaim_worktrees origin_url check_repository
        ensure_checkout
        check_projects_dir check_project create_project
        switch_checkout checkout_branch open_checkout_workspace
        open_session launch_agent agent_state send_prompt snapshot process_alive? terminate
        close_workspace close_workspace! notify
        available_models store_attachment attachments attachments_dir save_transcripts
        known_commits export_run import_run restore_transcripts
      ].freeze

      # The error classes that cross, by name. Anything else a runner raised
      # comes back as a plain Error.
      ERRORS = { "Unreachable" => Unreachable, "LaunchError" => LaunchError, "Error" => Error }.freeze

      def encode(value)
        case value
        when Hash then value.to_h { |key, item| [ key.to_s, encode(item) ] }
        when Array then value.map { |item| encode(item) }
        when Symbol then value.to_s
        when String then binary?(value) ? { BASE64 => Base64.strict_encode64(value) } : value
        when Pathname then value.to_s
        when Integer, Float, true, false, nil then value
        else raise ArgumentError, "a #{value.class} cannot cross to a runner: only plain data does"
        end
      end

      def decode(value)
        case value
        when Hash
          return Base64.strict_decode64(value.fetch(BASE64)) if value.keys == [ BASE64 ]

          value.transform_values { |item| decode(item) }
        when Array then value.map { |item| decode(item) }
        else value
        end
      end

      # Positional hashes are session specs, symbol-keyed at the top level.
      def decode_args(args)
        Array(args).map do |arg|
          decoded = decode(arg)
          decoded.is_a?(Hash) ? decoded.transform_keys(&:to_sym) : decoded
        end
      end

      def decode_kwargs(kwargs)
        (kwargs || {}).to_h { |key, value| [ key.to_sym, decode(value) ] }
      end

      def error_payload(error)
        name = ERRORS.find { |_, klass| error.is_a?(klass) }&.first || "Error"
        payload = { "class" => name, "message" => error.message.to_s }
        payload["lost_prompts"] = encode(error.lost_prompts) if error.respond_to?(:lost_prompts)
        payload
      end

      def error_from(payload)
        klass = ERRORS.fetch(payload["class"].to_s, Error)
        message = payload["message"].to_s
        return RemoteLaunchError.new(message, lost_prompts: decode(payload["lost_prompts"])) if klass == LaunchError && payload.key?("lost_prompts")

        klass.new(message)
      end

      def binary?(string)
        !string.valid_encoding? || (string.encoding == Encoding::BINARY && !string.ascii_only?)
      end

      # A LaunchError that carried its lost-prompt records across, as
      # SessionLauncher::PromptLost does in process (RunSessionRunner keeps
      # them on the session).
      class RemoteLaunchError < LaunchError
        attr_reader :lost_prompts

        def initialize(message, lost_prompts:)
          super(message)
          @lost_prompts = lost_prompts
        end
      end
    end
  end
end
