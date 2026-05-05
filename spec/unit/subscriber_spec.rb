# frozen_string_literal: true

require "bundler/setup"
require "capybara/lightpanda/client/subscriber"

RSpec.describe Capybara::Lightpanda::Client::Subscriber do
  subject(:subscriber) { described_class.new }

  describe "#subscribe and #dispatch" do
    it "delivers events to subscribers" do
      received = nil
      subscriber.subscribe("Page.loadEventFired") { |params| received = params }
      subscriber.dispatch("Page.loadEventFired", { "timestamp" => 123 })
      expect(received).to eq({ "timestamp" => 123 })
    end

    it "supports multiple subscribers for the same event" do
      results = []
      subscriber.subscribe("Page.loadEventFired") { results << :first }
      subscriber.subscribe("Page.loadEventFired") { results << :second }
      subscriber.dispatch("Page.loadEventFired", {})
      expect(results).to eq(%i[first second])
    end

    it "does not deliver to unrelated events" do
      received = false
      subscriber.subscribe("Page.loadEventFired") { received = true }
      subscriber.dispatch("Network.requestWillBeSent", {})
      expect(received).to be false
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
      expect(results).to eq([:kept])
    end

    it "removes all handlers for an event when no block given" do
      received = false
      subscriber.subscribe("test") { received = true }
      subscriber.unsubscribe("test")
      subscriber.dispatch("test", {})
      expect(received).to be false
    end
  end

  describe "#subscribed?" do
    it "returns false for unknown events" do
      expect(subscriber.subscribed?("unknown")).to be false
    end

    it "returns true after subscribing" do
      subscriber.subscribe("test") {}
      expect(subscriber.subscribed?("test")).to be true
    end

    it "returns false after unsubscribing all" do
      subscriber.subscribe("test") {}
      subscriber.unsubscribe("test")
      expect(subscriber.subscribed?("test")).to be false
    end
  end

  describe "#clear" do
    it "removes all subscriptions" do
      subscriber.subscribe("a") {}
      subscriber.subscribe("b") {}
      subscriber.clear
      expect(subscriber.subscribed?("a")).to be false
      expect(subscriber.subscribed?("b")).to be false
    end
  end

  describe "#dispatch error isolation" do
    let(:silent) { described_class.new(on_error: ->(_event, _error) {}) }

    it "does not propagate a callback exception to the caller" do
      silent.subscribe("test") { raise "boom" }
      expect { silent.dispatch("test", {}) }.not_to raise_error
    end

    it "still invokes later callbacks after an earlier one raises" do
      results = []
      silent.subscribe("test") { raise "boom" }
      silent.subscribe("test") { results << :reached }
      silent.dispatch("test", {})
      expect(results).to eq([:reached])
    end

    it "logs the failing event name and exception via the configured logger" do
      logged = []
      logger = ->(event, error) { logged << [event, error.message] }
      isolated = described_class.new(on_error: logger)
      isolated.subscribe("test") { raise "boom" }
      isolated.dispatch("test", {})
      expect(logged).to eq([%w[test boom]])
    end

    it "does not propagate when the on_error sink itself raises" do
      raising_sink = ->(_event, _error) { raise "sink fail" }
      isolated = described_class.new(on_error: raising_sink)
      isolated.subscribe("test") { raise "boom" }
      expect { isolated.dispatch("test", {}) }.not_to raise_error
    end

    it "still invokes later callbacks after the sink raises" do
      raising_sink = ->(_event, _error) { raise "sink fail" }
      isolated = described_class.new(on_error: raising_sink)
      results = []
      isolated.subscribe("test") { raise "boom" }
      isolated.subscribe("test") { results << :reached }
      isolated.dispatch("test", {})
      expect(results).to eq([:reached])
    end
  end
end
