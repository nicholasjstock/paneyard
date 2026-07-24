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

    def detected?(output)
      output.match?(/hit your session limit|rate limit|too many requests|429|hit your usage limit/i)
    end

    def reset_at(output)
      claude_reset_at(output) || codex_reset_at(output) || 30.minutes.from_now
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
