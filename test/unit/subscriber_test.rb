# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/client/subscriber"

describe Capybara::Lightpanda::Client::Subscriber do
  let(:subscriber) { Capybara::Lightpanda::Client::Subscriber.new }

  describe "#subscribe and #dispatch" do
    it "delivers events to subscribers" do
      received = nil
      subscriber.subscribe("Page.loadEventFired") { |params| received = params }
      subscriber.dispatch("Page.loadEventFired", { "timestamp" => 123 })
      assert_equal({ "timestamp" => 123 }, received)
    end

    it "supports multiple subscribers for the same event" do
      results = []
      subscriber.subscribe("Page.loadEventFired") { results << :first }
      subscriber.subscribe("Page.loadEventFired") { results << :second }
      subscriber.dispatch("Page.loadEventFired", {})
      assert_equal(%i[first second], results)
    end

    it "does not deliver to unrelated events" do
      received = false
      subscriber.subscribe("Page.loadEventFired") { received = true }
      subscriber.dispatch("Network.requestWillBeSent", {})
      assert_equal false, received
    end
  end

  describe "#unsubscribe" do
    it "removes a specific handler" do
      results = []
      handler = proc { results << :removed }
      subscriber.subscribe("test", &handler)
      subscriber.subscribe("test") { results << :kept }
      subscriber.unsubscribe("test", handler)
      subscriber.dispatch("test", {})
      assert_equal [:kept], results
    end

    it "removes all handlers for an event when no block given" do
      received = false
      subscriber.subscribe("test") { received = true }
      subscriber.unsubscribe("test")
      subscriber.dispatch("test", {})
      assert_equal false, received
    end
  end

  describe "#subscribed?" do
    it "returns false for unknown events" do
      assert_equal false, subscriber.subscribed?("unknown")
    end

    it "returns true after subscribing" do
      subscriber.subscribe("test") {}
      assert_equal true, subscriber.subscribed?("test")
    end

    it "returns false after unsubscribing all" do
      subscriber.subscribe("test") {}
      subscriber.unsubscribe("test")
      assert_equal false, subscriber.subscribed?("test")
    end
  end

  describe "#clear" do
    it "removes all subscriptions" do
      subscriber.subscribe("a") {}
      subscriber.subscribe("b") {}
      subscriber.clear
      assert_equal false, subscriber.subscribed?("a")
      assert_equal false, subscriber.subscribed?("b")
    end
  end

  describe "#dispatch error isolation" do
    let(:silent) { Capybara::Lightpanda::Client::Subscriber.new(on_error: ->(_event, _error) {}) }

    it "does not propagate a callback exception to the caller" do
      silent.subscribe("test") { raise "boom" }
      silent.dispatch("test", {})
      pass
    end

    it "still invokes later callbacks after an earlier one raises" do
      results = []
      silent.subscribe("test") { raise "boom" }
      silent.subscribe("test") { results << :reached }
      silent.dispatch("test", {})
      assert_equal [:reached], results
    end

    it "logs the failing event name and exception via the configured logger" do
      logged = []
      logger = ->(event, error) { logged << [event, error.message] }
      isolated = Capybara::Lightpanda::Client::Subscriber.new(on_error: logger)
      isolated.subscribe("test") { raise "boom" }
      isolated.dispatch("test", {})
      assert_equal [%w[test boom]], logged
    end

    it "does not propagate when the on_error sink itself raises" do
      raising_sink = ->(_event, _error) { raise "sink fail" }
      isolated = Capybara::Lightpanda::Client::Subscriber.new(on_error: raising_sink)
      isolated.subscribe("test") { raise "boom" }
      isolated.dispatch("test", {})
      pass
    end

    it "still invokes later callbacks after the sink raises" do
      raising_sink = ->(_event, _error) { raise "sink fail" }
      isolated = Capybara::Lightpanda::Client::Subscriber.new(on_error: raising_sink)
      results = []
      isolated.subscribe("test") { raise "boom" }
      isolated.subscribe("test") { results << :reached }
      isolated.dispatch("test", {})
      assert_equal [:reached], results
    end
  end
end
