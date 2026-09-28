require "rails_helper"

RSpec.describe RemoteControl::Chunker do
  describe ".split" do
    it "leaves short text alone" do
      expect(described_class.split("hello\nworld", limit: 4000)).to eq([ "hello\nworld" ])
    end

    it "splits on line boundaries under the limit" do
      text = (1..50).map { |i| "line #{i}\n" }.join

      chunks = described_class.split(text, limit: 100)

      expect(chunks.map(&:length)).to all(be <= 100)
      expect(chunks.join("\n").scan(/line \d+/)).to eq((1..50).map { |i| "line #{i}" })
    end

    it "closes a fenced block at a split and reopens it with its info string" do
      text = "Intro\n```ruby\n#{(1..30).map { |i| "puts #{i}\n" }.join}```\nOutro\n"

      chunks = described_class.split(text, limit: 120)

      expect(chunks.size).to be > 1
      chunks.each { |chunk| expect(chunk.scan(/^```/).size).to be_even }
      expect(chunks[1]).to start_with("```ruby\n")
    end

    it "breaks a single overlong line rather than exceeding the limit" do
      chunks = described_class.split("x" * 1000, limit: 200)

      expect(chunks.map(&:length)).to all(be <= 200)
      expect(chunks.join).to eq("x" * 1000)
    end
  end

  describe ".tail" do
    it "keeps the newest lines that fit" do
      expect(described_class.tail("a\nb\nc\nd\n", limit: 4)).to eq("c\nd")
    end
  end
end
