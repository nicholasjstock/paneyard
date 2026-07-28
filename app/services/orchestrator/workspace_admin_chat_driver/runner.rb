module Orchestrator
  module WorkspaceAdminChatDriver
    # Rails-owned lifecycle for a workspace admin-chat turn: PlannerDecisionJob's
    # sibling for this feature -- one structured (well, streamed) driver call
    # per turn, persisted and dispatched transactionally, with the CLI process
    # itself staying a stateless, one-shot subprocess (ClaudeProvider /
    # CodexProvider own its args and event normalization).
    module Runner
      module_function

      class ConcurrentTurnError < StandardError; end

      PROVIDERS = { "claude" => ClaudeProvider, "codex" => CodexProvider }.freeze

      # The admin chat's own cwd (Workspace#root_path) is deliberately the
      # workspace root, not the main checkout -- it needs to see every
      # active run's worktree, not just main. That root has no .git of its
      # own, so neither CLI's project-instructions convention is
      # auto-discovered the way it would be from inside a real checkout:
      # confirmed empirically (2026-07-28) via a bare `claude -p`/`codex
      # exec` from a workspace root -- both answered "no" when asked
      # whether they already had that content loaded. Each provider reads a
      # different file by its own native convention (Claude: CLAUDE.md,
      # confirmed via this very tool's own system prompt; Codex: AGENTS.md,
      # confirmed live -- a bare `codex exec` from inside the real checkout
      # quoted content back unprompted), so tell each the one it actually
      # consults rather than hedging with both. Told once per fresh session
      # (a resumed session already has it in context from the first turn;
      # CodexProvider's own module comment notes a resumed turn otherwise
      # behaves identically).
      PROJECT_INSTRUCTIONS_FILE = { "claude" => "CLAUDE.md", "codex" => "AGENTS.md" }.freeze

      def worktree_orientation(workspace, provider_name)
        "This directory (#{workspace.root_path}) is this workspace's root -- it holds #{Pathname(workspace.source_root).basename} " \
          "(the durable source checkout) alongside sibling worktrees for any runs in flight. It is not a git repository itself, " \
          "so #{PROJECT_INSTRUCTIONS_FILE.fetch(provider_name)} is not auto-discovered from here the way it would be from inside " \
          "a checkout. Read #{workspace.source_root}/#{PROJECT_INSTRUCTIONS_FILE.fetch(provider_name)} before making any " \
          "repository changes.\n\n"
      end

      # Creates the user/assistant message pair and enqueues the turn job
      # inside one lock+transaction, so two racing requests for the same chat
      # can't both observe active_turn_id blank and both start a turn.
      def start_turn!(chat:, content:, telegram_conversation: nil)
        raise ArgumentError, "content is required" if content.blank?

        turn_id = SecureRandom.uuid
        provider = chat.active_provider
        assistant_message = nil

        chat.with_lock do
          raise ConcurrentTurnError if chat.active?

          chat.update!(active_turn_id: turn_id, status: "running", last_error: nil)
          chat.messages.create!(role: "user", provider:, turn_id:, status: "completed", content:)
          assistant_message = chat.messages.create!(role: "assistant", provider:, turn_id:, status: "running", telegram_conversation:)
        end

        # Telegram polling processes an update while holding its durable
        # cursor transaction. The queue database is separate, so enqueueing
        # immediately lets a worker claim this job before that outer primary
        # database transaction has committed the message row. Defer through
        # all surrounding transactions so every queue worker can see it.
        ActiveRecord.after_all_transactions_commit do
          WorkspaceAdminChatTurnJob.perform_later(assistant_message.id)
        end
        assistant_message
      end

      # The actual turn: called from WorkspaceAdminChatTurnJob#perform, which
      # can run in a different OS process than the request that created
      # assistant_message (see ProcessStream's module comment) -- pid is
      # persisted the moment the CLI process exists so #cancel_turn!, called
      # from any process, has something durable to signal.
      #
      # Never raises out to the job on a driver-side failure (malformed
      # JSON, a non-zero exit, a cancel) -- those are normal turn outcomes
      # recorded on assistant_message. Only an unexpected internal error
      # re-raises, after still recording what happened so the chat isn't
      # left stuck "running".
      def perform_turn(assistant_message)
        chat = assistant_message.workspace_admin_chat
        provider_name = assistant_message.provider
        provider = PROVIDERS.fetch(provider_name)
        prompt = chat.messages.find_by(turn_id: assistant_message.turn_id, role: "user")&.content
        session_id = chat.session_id_for(provider_name)
        on_spawn = ->(pid) { assistant_message.update!(pid:, process_group_id: pid) }

        cli_prompt = session_id.blank? ? worktree_orientation(chat.workspace, provider_name) + prompt : prompt
        result = provider.run_turn(
          workspace_path: chat.workspace.root_path, prompt: cli_prompt, session_id:,
          model: chat.model_for(provider_name), on_spawn:
        ) { |event| assistant_message.apply_event!(event) }

        if session_id.present? && result[:error] && provider.session_missing?(result[:stderr])
          result = reconstruct_and_retry!(chat:, provider:, provider_name:, assistant_message:, prompt:, on_spawn:)
        end

        # Only ever write a *new, successfully observed* session id -- a
        # malformed line or a failed exit never nils out or otherwise
        # corrupts a session id this chat already had.
        chat.set_session_id!(provider_name, result[:session_id])

        assistant_message.update!(status: result[:cancelled] ? "cancelled" : (result[:error] ? "failed" : "completed"))
        chat.update!(status: result[:error] ? "failed" : "idle", last_error: result[:error] ? assistant_message.error_message : nil)
        DeliverTelegramAdminChatResponseJob.perform_later(assistant_message.id) if assistant_message.telegram_conversation
      rescue => e
        assistant_message.apply_event!({ type: "error", message: e.message })
        assistant_message.update!(status: "failed")
        chat&.update!(status: "failed", last_error: e.message)
        DeliverTelegramAdminChatResponseJob.perform_later(assistant_message.id) if assistant_message.telegram_conversation
        raise
      ensure
        chat&.update!(active_turn_id: nil)
      end

      # The stored session id pointed at a CLI session gone from local disk
      # (see ClaudeProvider/CodexProvider::SESSION_MISSING_PATTERN, confirmed
      # against both real CLIs) -- rather than leave the chat stuck failing
      # every subsequent turn until someone notices and clicks Reset, clear
      # it and retry once as a brand-new session, folding the chat's own
      # transcript into the prompt so context isn't simply dropped. Mirrors
      # what the pre-session-persistence WorkspaceChatRunner did on *every*
      # turn (see git history); here it's only a one-time fallback.
      def reconstruct_and_retry!(chat:, provider:, provider_name:, assistant_message:, prompt:, on_spawn:)
        assistant_message.apply_event!(
          type: "session_reconstructed",
          message: "#{provider_name.capitalize}'s prior session was gone -- retrying as a new session with chat history folded in."
        )
        chat.reset_session!(provider_name)

        reconstructed_prompt = reconstruction_prompt(chat:, provider_name:, assistant_message:, latest_prompt: prompt)
        provider.run_turn(
          workspace_path: chat.workspace.root_path, prompt: worktree_orientation(chat.workspace, provider_name) + reconstructed_prompt, session_id: nil,
          model: chat.model_for(provider_name), on_spawn:
        ) { |event| assistant_message.apply_event!(event) }
      end

      # Every prior message for this provider (each already carries an
      # explicit User:/Claude:/Codex: label so the reconstructed session
      # can't mistake one speaker for the other) except this exact turn's
      # own rows, which are folded in separately as "the operator's new
      # message" so it isn't duplicated into the transcript.
      def reconstruction_prompt(chat:, provider_name:, assistant_message:, latest_prompt:)
        prior = chat.messages.where(provider: provider_name).where.not(turn_id: assistant_message.turn_id).order(:created_at)
        return latest_prompt if prior.none?

        transcript = prior.map { |m| "#{m.role == "user" ? "User" : provider_name.capitalize}: #{m.content}" }.join("\n\n")

        <<~PROMPT
          Your prior #{provider_name.capitalize} session for this workspace was lost, so this is a brand-new session with no memory of the conversation below. Here is the earlier transcript for context, oldest first, each line labeled by who said it:

          #{transcript}

          Continue from there. The operator's new message:
          #{latest_prompt}
        PROMPT
      end

      # Sends the kill directly by pid (see ProcessStream.kill_process_group)
      # rather than through any in-process bookkeeping -- this can be, and
      # often is, a different OS process than the one actually running the
      # CLI child. true means a live pid was found and signaled; the job's
      # own perform_turn (in whichever process is running it) still owns
      # marking the message "cancelled" once its read loop actually ends.
      # false means there was nothing to signal (no pid recorded yet, or the
      # process it named is already gone -- a crashed job, most likely) --
      # clear the stuck slot directly so the chat isn't blocked forever.
      def cancel_turn!(chat)
        return false unless chat.active?

        assistant_message = chat.messages.find_by(turn_id: chat.active_turn_id, role: "assistant")
        pid = assistant_message&.pid

        if pid.present? && ProcessStream.process_group_alive?(pid)
          ProcessStream.kill_process_group(pid)
          true
        else
          chat.update!(active_turn_id: nil, status: "idle")
          false
        end
      end
    end
  end
end
