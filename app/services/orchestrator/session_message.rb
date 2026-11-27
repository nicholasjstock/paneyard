module Orchestrator
  # Types a message the operator asked to pass on into another run's live
  # session, through RunSessionRunner.prompt! -- the same steering wheel the
  # operator's own typing and the plugin use -- so the operator is no longer
  # the copy/paste transport between two sessions (nicholasjstock/paneyard#83).
  #
  # Deliberately a thin relay: no inbox, no queueing, no delivery retries. The
  # receiving CLI's own input handling deals with a message that arrives while
  # it is working, as it does when the operator types into it.
  #
  # What it does refuse is anything that would land somewhere other than the
  # agent's own input: a session still starting (its task prompt is not in
  # yet), a pane or CLI that is gone, and herdr's `blocked` agent status -- the
  # CLI waiting at a permission or approval prompt, which typed text would
  # answer.
  module SessionMessage
    module_function

    class Refused < StandardError; end

    # Long enough for a finding with its evidence; agent.prompt takes longer
    # the larger the text (see Runner::Herdr), and a session's whole task
    # prompt is a few KB.
    MAX_LENGTH = 16_000

    # `from_run` is the sending run (a run session on /mcp/run), or nil for
    # the operator's own client on /mcp/admin. Returns what herdr said the
    # recipient was doing just before the message went in.
    def call(run, message, from_run: nil)
      text = message.to_s.strip
      raise Refused, "message is empty" if text.empty?
      raise Refused, "message is #{text.length} characters; the limit is #{MAX_LENGTH}" if text.length > MAX_LENGTH
      raise Refused, "run #{run.run_id} is your own run; send a message to another run's session" if from_run && from_run.id == run.id

      session = live_session!(run)
      agent_status = session.agent_status
      deliver!(session, "#{provenance(from_run)}\n\n#{text}")

      { run_id: run.run_id, agent_status: }
    end

    def live_session!(run)
      session = run.live_session
      raise Refused, "run #{run.run_id} has no live session (it is #{run.status}); the operator can bring it back with Reopen session" unless session
      raise Refused, "run #{run.run_id}'s session is still starting; send the message once it is running" if session.status == "starting"

      begin
        RunSessionRunner.refresh!(session)
      rescue Runner::Unreachable => error
        raise Refused, "herdr did not answer (#{error.message}), so nothing was sent; the session is not presumed dead. Try again shortly"
      end

      if session.ended?
        raise Refused, "run #{run.run_id}'s session has ended (#{session.result.presence || 'its pane or CLI is gone'}); " \
          "the operator can bring it back with Reopen session"
      end
      if session.agent_status == "blocked"
        raise Refused, "run #{run.run_id}'s agent is waiting at a permission or approval prompt, which the message would " \
          "answer; nothing was sent. Ask the operator to deal with that prompt first"
      end
      session
    end

    def deliver!(session, text)
      RunSessionRunner.prompt!(session, text)
    rescue Runner::Unreachable => error
      raise Refused, "herdr did not answer while the message was being sent (#{error.message}); it may still have " \
        "arrived, so check run #{session.run.run_id}'s pane before sending it again"
    rescue Runner::Error, RunSessionRunner::Error => error
      raise Refused, "herdr would not deliver the message to run #{session.run.run_id}: #{error.message}"
    end

    # One line, so the recipient knows the text is not the operator typing to
    # it directly, and which run a finding came from.
    def provenance(from_run)
      source = from_run ? "run #{from_run.run_id}" : "the operator's session"
      "[Paneyard: message relayed from #{source}]"
    end
  end
end
