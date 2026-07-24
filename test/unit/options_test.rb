# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/options"

describe Capybara::Lightpanda::Options do
  describe "defaults" do
    let(:options) { Capybara::Lightpanda::Options.new }

    it "uses default host" do
      assert_equal "127.0.0.1", options.host
    end

    it "uses an OS-assigned ephemeral port by default" do
      assert_equal 0, options.port
    end

    it "uses default timeout" do
      assert_equal 15, options.timeout
    end

    it "uses default handshake_timeout" do
      assert_equal 5, options.handshake_timeout
    end

    it "uses default process_timeout" do
      assert_equal 10, options.process_timeout
    end

    # window_size is applied for real (Browser#set_viewport ->
    # Emulation.setDeviceMetricsOverride), so the default deliberately mirrors
    # Lightpanda's own Viewport.default rather than Cuprite's 1024x768 —
    # otherwise wiring the option up would have silently shrunk the viewport of
    # every existing suite and flipped `@media` branches under it.
    it "defaults window_size to Lightpanda's native viewport" do
      assert_equal [1920, 1080], options.window_size
    end

    it "accepts an explicit window_size" do
      assert_equal [375, 667], Capybara::Lightpanda::Options.new(window_size: [375, 667]).window_size
    end

    # Validated at construction, not at apply time: Browser#initialize spawns
    # the process before create_page runs, so raising later would orphan a
    # Lightpanda. Upstream also reads a 0 dimension as "keep the current one",
    # so a silently-forwarded bad value would half-apply a viewport.
    [
      ["a zero dimension", [0, 768]],
      ["a negative dimension", [1024, -1]],
      ["non-integer dimensions", %w[1024 768]],
      ["a single dimension", [1024]],
      ["nil", nil],
    ].each do |label, value|
      it "rejects #{label} for window_size" do
        error = assert_raises(ArgumentError) { Capybara::Lightpanda::Options.new(window_size: value) }
        assert_match(/window_size/, error.message)
      end
    end

    it "accepts headless for cuprite compatibility" do
      assert_equal true, options.headless
    end

    it "defaults browser_path to nil" do
      assert_nil options.browser_path
    end
  end

  describe "overrides" do
    it "accepts options hash" do
      options = Capybara::Lightpanda::Options.new(host: "0.0.0.0", port: 9333, timeout: 30)
      assert_equal "0.0.0.0", options.host
      assert_equal 9333, options.port
      assert_equal 30, options.timeout
    end

    it "accepts browser_path" do
      options = Capybara::Lightpanda::Options.new(browser_path: "/usr/bin/lightpanda")
      assert_equal "/usr/bin/lightpanda", options.browser_path
    end
  end

  describe "#ws_url" do
    it "computes from host and port when not set" do
      options = Capybara::Lightpanda::Options.new(host: "localhost", port: 1234)
      assert_equal "ws://localhost:1234/", options.ws_url
    end

    it "returns explicit value when set" do
      options = Capybara::Lightpanda::Options.new(ws_url: "ws://custom:5555/")
      assert_equal "ws://custom:5555/", options.ws_url
    end
  end

  describe "#ws_url?" do
    it "returns false when ws_url not explicitly set" do
      options = Capybara::Lightpanda::Options.new
      assert_equal false, options.ws_url?
    end

    it "returns true when ws_url explicitly set" do
      options = Capybara::Lightpanda::Options.new(ws_url: "ws://custom:5555/")
      assert_equal true, options.ws_url?
    end
  end

  describe "#to_h" do
    it "includes all standard options" do
      options = Capybara::Lightpanda::Options.new
      hash = options.to_h
      %i[host port timeout handshake_timeout process_timeout window_size browser_path headless].each do |key|
        assert_includes hash.keys, key
      end
    end

    it "excludes ws_url when not explicitly set" do
      options = Capybara::Lightpanda::Options.new
      refute_includes options.to_h.keys, :ws_url
    end

    it "includes ws_url when explicitly set" do
      options = Capybara::Lightpanda::Options.new(ws_url: "ws://custom:5555/")
      assert_equal "ws://custom:5555/", options.to_h[:ws_url]
    end

    it "round-trips through Options.new" do
      original = Capybara::Lightpanda::Options.new(host: "0.0.0.0", port: 1234, timeout: 30)
      restored = Capybara::Lightpanda::Options.new(original.to_h)
      assert_equal "0.0.0.0", restored.host
      assert_equal 1234, restored.port
      assert_equal 30, restored.timeout
      assert_equal false, restored.ws_url?
    end
  end
end
