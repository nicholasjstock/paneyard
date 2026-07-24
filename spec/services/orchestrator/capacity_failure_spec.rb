require "rails_helper"

RSpec.describe Orchestrator::CapacityFailure do
  it "detects Claude's capacity wording" do
    expect(described_class.detected?("You've hit your session limit · resets 5pm (Europe/Paris)")).to be true
    expect(described_class.detected?("429 Too Many Requests")).to be true
  end

  it "detects Codex's capacity wording" do
    expect(described_class.detected?("ERROR: You've hit your usage limit. ... try again at Jul 28th, 2026 7:03 PM.")).to be true
  end

  it "does not detect an unrelated failure" do
    expect(described_class.detected?("NoMethodError: undefined method 'foo'")).to be false
  end

  it "parses Claude's wall-clock reset time" do
    reset_at = described_class.reset_at("hit your session limit · resets 5pm (Europe/Paris)")
    expect(reset_at.in_time_zone("Europe/Paris").hour).to eq(17)
  end

  it "parses Codex's absolute reset date/time" do
    reset_at = described_class.reset_at("try again at Jul 28th, 2026 7:03 PM.")
    expect(reset_at.year).to eq(2026)
    expect(reset_at.month).to eq(7)
    expect(reset_at.day).to eq(28)
    expect(reset_at.hour).to eq(19)
    expect(reset_at.min).to eq(3)
  end

  it "falls back to a 30-minute default when no reset time is present" do
    expect(described_class.reset_at("hit your usage limit")).to be_within(1.second).of(30.minutes.from_now)
  end
end
