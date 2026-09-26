require "rails_helper"

RSpec.describe Run, type: :model do
  describe "sessions" do
    it "exposes only the live session as #live_session, and the newest as #latest_session" do
      run, first = create_run_and_session(prefix: "run-sessions")
      first.update!(status: "done", outcome: "done", ended_at: Time.current)
      _run, second = create_run_and_session(run:, prefix: "run-sessions")

      expect(run.live_session).to eq(second)
      expect(run.latest_session).to eq(second)

      second.update!(status: "closed", ended_at: Time.current)
      expect(run.reload.live_session).to be_nil
      expect(run.latest_session).to eq(second)
    end

    it "refuses a second live session for the same run, so one run can never hold two slots" do
      run, _session = create_run_and_session(prefix: "run-sessions")

      expect do
        create_run_and_session(run:, prefix: "run-sessions")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
