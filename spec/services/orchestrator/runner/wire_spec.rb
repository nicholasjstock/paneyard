require "rails_helper"

RSpec.describe Orchestrator::Runner::Wire do
  it "carries exactly Runner::Local's public methods, so a remote runner answers what a local one does" do
    local = Orchestrator::Runner::Local.public_instance_methods(false).map(&:to_s) - %w[id runtime_root]

    expect(described_class::METHODS).to match_array(local)
  end

  it "round-trips plain data, with binary strings as base64 and nothing else allowed" do
    binary = "\x89PNG\r\n\x1A\n\x00\xFF".b
    value = { "name" => "a.png", content: binary, "sizes" => [ 1, 2.5, true, nil ], "path" => Pathname("/x") }

    wire = JSON.parse(JSON.generate(described_class.encode(value)))

    expect(wire["content"]).to eq("$base64" => Base64.strict_encode64(binary))
    decoded = described_class.decode(wire)
    expect(decoded).to eq("name" => "a.png", "content" => binary, "sizes" => [ 1, 2.5, true, nil ], "path" => "/x")
    expect(decoded["content"].encoding).to eq(Encoding::BINARY)
    expect { described_class.encode(Object.new) }.to raise_error(ArgumentError, /only plain data/)
    expect { described_class.encode(Run.new) }.to raise_error(ArgumentError)
  end

  it "gives a session spec its symbol keys back, and leaves what is inside it string-keyed" do
    spec = { run_id: "run-1", layout: [ { "name" => nil, "panes" => [ { "name" => "agent" } ] } ] }

    args = described_class.decode_args(JSON.parse(JSON.generate(described_class.encode([ spec, "w1:p1" ]))))

    expect(args).to eq([ spec, "w1:p1" ])
  end

  it "maps a runner's errors back onto the same classes, keeping lost-prompt records" do
    unreachable = described_class.error_from(described_class.error_payload(Orchestrator::Runner::Unreachable.new("no herdr")))
    lost = Orchestrator::Runner::SessionLauncher::PromptLost.new("never took it", lost_prompts: [ { "cli" => "claude" } ])
    launch = described_class.error_from(JSON.parse(JSON.generate(described_class.error_payload(lost))))
    other = described_class.error_from(described_class.error_payload(RuntimeError.new("boom")))

    expect(unreachable).to be_a(Orchestrator::Runner::Unreachable).and(have_attributes(message: "no herdr"))
    expect(launch).to be_a(Orchestrator::Runner::LaunchError).and(have_attributes(message: "never took it", lost_prompts: [ { "cli" => "claude" } ]))
    expect(other).to be_an_instance_of(Orchestrator::Runner::Error)
    expect(described_class.error_from("class" => "NoMethodError", "message" => "x")).to be_an_instance_of(Orchestrator::Runner::Error)
  end
end
