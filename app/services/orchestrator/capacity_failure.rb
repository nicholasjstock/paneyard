module Orchestrator
  # Shared provider-capacity detection for both drivers' CLI output --
  # extracted after the exact same Claude-only regex was independently
  # duplicated in WorkerReconcileJob and PlannerDecisionJob, and both
  # missed Codex's "hit your usage limit" wording (see git history for
  # the incidents this caused: a Codex committer that retried into the
  # same exhausted driver instead of pausing, and a Codex planner
  # decision that hard-failed a run outright instead of pausing it).
  module CapacityFailure
    module_function

    # The single source of truth for what counts as a capacity failure and
    # how to describe it. detected? (the pause-the-run gate) and
    # stop_reason_message (WorkerReconcileJob's human-readable stop_reason)
    # used to independently re-derive overlapping regexes -- they've now
    # both drawn from this one list since, so the gate and the message can
    # no longer silently drift out of sync with each other or with a future
    # wording change in either CLI's own output.
    SIGNALS = [
      [ /hit your session limit/i, "Claude session limit reached" ],
      [ /hit your usage limit/i, "Codex usage limit reached" ],
      # Codex can reject an individual model pool even when the account has
      # not exhausted its broader usage allowance. This is still transient:
      # keep the current handoff open and let the run tick retry it, rather
      # than treating a healthy plan as a terminal planner failure.
      [ /selected model is at capacity/i, "Codex model capacity unavailable" ],
      # \b429\b, not a bare substring: log output is full of UUIDs (session
      # ids, worker ids) and a bare "429" matches any of them that happen to
      # contain that digit sequence (e.g. a session id containing "...4295...")
      # -- confirmed as a real false positive that parked a run in
      # waiting_on_capacity after a chaperone that had actually completed
      # successfully. \b429\b only matches an isolated token, which a UUID's
      # unbroken hex run never produces.
      [ /rate limit|too many requests|\b429\b/i, "Claude rate limit reached" ]
    ].freeze

    def detected?(output)
      SIGNALS.any? { |pattern, _label| output.match?(pattern) }
    end

    def stop_reason_message(output)
      _pattern, label = SIGNALS.find { |pattern, _label| output.match?(pattern) }
      return nil unless label

      "#{label}; worker exited before completing its handoff."
    end

    def reset_at(output)
      claude_reset_at(output) || codex_reset_at(output) || 10.minutes.from_now
    end

    # Claude's wording states only a wall-clock time and zone ("resets 5pm
    # (Europe/Paris)"), implying "the next time this clock reads 5pm".
    def claude_reset_at(output)
      match = output.match(/resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*\(([^)]+)\)/i)
      return unless match

      hour = match[1].to_i
      minute = match[2].to_i
      meridiem = match[3]&.downcase
      hour = (hour % 12) + (meridiem == "pm" ? 12 : 0) if meridiem.present?
      zone = Time.find_zone(match[4]) || Time.zone
      now = Time.current.in_time_zone(zone)
      retry_at = zone.local(now.year, now.month, now.day, hour, minute)
      retry_at += 1.day if retry_at <= Time.current
      retry_at
    end

    # Codex's wording gives a full absolute date/time instead ("try again at
    # Jul 28th, 2026 7:03 PM"), with no zone -- treated as wall-clock time in
    # this process's own zone, same assumption the Claude fallback above
    # makes once it has resolved a zone.
    def codex_reset_at(output)
      match = output.match(/try again at\s+([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])/)
      return unless match

      month = Date::ABBR_MONTHNAMES.index(match[1].capitalize)
      return unless month

      hour = match[4].to_i % 12
      hour += 12 if match[6].downcase == "pm"
      Time.zone.local(match[3].to_i, month, match[2].to_i, hour, match[5].to_i)
    rescue ArgumentError
      nil
    end
  end
end
