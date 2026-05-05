# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/frame"

describe Capybara::Lightpanda::Frame do
  describe "#initialize" do
    it "captures id and optional metadata" do
      frame = Capybara::Lightpanda::Frame.new("FRAME_1", nil, name: "main", url: "https://x.test/")
      assert_equal "FRAME_1", frame.id
      assert_nil frame.parent_id
      assert_equal "main", frame.name
      assert_equal "https://x.test/", frame.url
      assert_nil frame.state
    end
  end

  describe "#main?" do
    it "is true when parent_id is nil" do
      assert_equal true, Capybara::Lightpanda::Frame.new("F").main?
    end

    it "is false when a parent is set" do
      assert_equal false, Capybara::Lightpanda::Frame.new("F", "PARENT").main?
    end
  end

  describe "mutable accessors" do
    it "allows updating name/url/state as events arrive" do
      frame = Capybara::Lightpanda::Frame.new("F")
      frame.name = "iframe1"
      frame.url = "https://x.test/iframe"
      frame.state = :stopped_loading
      assert_equal "iframe1", frame.name
      assert_equal "https://x.test/iframe", frame.url
      assert_equal :stopped_loading, frame.state
    end
  end
end
