# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/frame"

RSpec.describe Capybara::Lightpanda::Frame do
  describe "#initialize" do
    it "captures id and optional metadata" do
      frame = described_class.new("FRAME_1", nil, name: "main", url: "https://x.test/")
      expect(frame.id).to eq("FRAME_1")
      expect(frame.parent_id).to be_nil
      expect(frame.name).to eq("main")
      expect(frame.url).to eq("https://x.test/")
      expect(frame.state).to be_nil
    end
  end

  describe "#main?" do
    it "is true when parent_id is nil" do
      expect(described_class.new("F").main?).to be true
    end

    it "is false when a parent is set" do
      expect(described_class.new("F", "PARENT").main?).to be false
    end
  end

  describe "mutable accessors" do
    it "allows updating name/url/state as events arrive" do
      frame = described_class.new("F")
      frame.name = "iframe1"
      frame.url = "https://x.test/iframe"
      frame.state = :stopped_loading
      expect(frame.name).to eq("iframe1")
      expect(frame.url).to eq("https://x.test/iframe")
      expect(frame.state).to eq(:stopped_loading)
    end
  end
end
