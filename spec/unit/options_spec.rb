# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/options"

RSpec.describe Capybara::Lightpanda::Options do
  describe "defaults" do
    subject(:options) { described_class.new }

    it "uses default host" do
      expect(options.host).to eq("127.0.0.1")
    end

    it "uses default port" do
      expect(options.port).to eq(9222)
    end

    it "uses default timeout" do
      expect(options.timeout).to eq(15)
    end

    it "uses default process_timeout" do
      expect(options.process_timeout).to eq(10)
    end

    it "uses default window_size" do
      expect(options.window_size).to eq([1024, 768])
    end

    it "defaults headless to true" do
      expect(options.headless).to be true
    end

    it "defaults browser_path to nil" do
      expect(options.browser_path).to be_nil
    end
  end

  describe "overrides" do
    it "accepts options hash" do
      options = described_class.new(host: "0.0.0.0", port: 9333, timeout: 30)
      expect(options.host).to eq("0.0.0.0")
      expect(options.port).to eq(9333)
      expect(options.timeout).to eq(30)
    end

    it "accepts browser_path" do
      options = described_class.new(browser_path: "/usr/bin/lightpanda")
      expect(options.browser_path).to eq("/usr/bin/lightpanda")
    end
  end

  describe "#ws_url" do
    it "computes from host and port when not set" do
      options = described_class.new(host: "localhost", port: 1234)
      expect(options.ws_url).to eq("ws://localhost:1234/")
    end

    it "returns explicit value when set" do
      options = described_class.new(ws_url: "ws://custom:5555/")
      expect(options.ws_url).to eq("ws://custom:5555/")
    end
  end

  describe "#ws_url?" do
    it "returns false when ws_url not explicitly set" do
      options = described_class.new
      expect(options.ws_url?).to be false
    end

    it "returns true when ws_url explicitly set" do
      options = described_class.new(ws_url: "ws://custom:5555/")
      expect(options.ws_url?).to be true
    end
  end

  describe "#to_h" do
    it "includes all standard options" do
      options = described_class.new
      hash = options.to_h
      expect(hash).to include(:host, :port, :timeout, :process_timeout, :window_size, :browser_path, :headless)
    end

    it "excludes ws_url when not explicitly set" do
      options = described_class.new
      expect(options.to_h).not_to have_key(:ws_url)
    end

    it "includes ws_url when explicitly set" do
      options = described_class.new(ws_url: "ws://custom:5555/")
      expect(options.to_h[:ws_url]).to eq("ws://custom:5555/")
    end

    it "round-trips through Options.new" do
      original = described_class.new(host: "0.0.0.0", port: 1234, timeout: 30)
      restored = described_class.new(original.to_h)
      expect(restored.host).to eq("0.0.0.0")
      expect(restored.port).to eq(1234)
      expect(restored.timeout).to eq(30)
      expect(restored.ws_url?).to be false
    end
  end
end
