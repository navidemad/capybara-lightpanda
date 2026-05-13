# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/network"

# Minimal stand-in for Capybara::Lightpanda::Browser. We only need command
# logging and the on/off pubsub used by Network#subscribe/#unsubscribe.
class FakeBrowser
  attr_reader :commands, :ops

  def initialize
    @commands = []
    @subscriptions = Hash.new { |h, k| h[k] = [] }
    # Records the order of CDP commands and on/off calls so tests can
    # assert that, e.g., Network.disable is sent BEFORE the local
    # unsubscribe.
    @ops = []
  end

  def command(method, **params)
    @commands << [method, params]
    @ops << [:command, method]
    {}
  end

  def page_command(method, **params)
    @commands << [method, params]
    @ops << [:page_command, method]
    {}
  end

  def on(event, &block)
    @subscriptions[event] << block
    @ops << [:on, event]
    block
  end

  def off(event, block)
    @subscriptions[event].delete(block)
    @ops << [:off, event]
  end

  def fire(event, params)
    @subscriptions[event].each { |cb| cb.call(params) }
  end

  def subscriber_count(event)
    @subscriptions[event].size
  end
end

describe Capybara::Lightpanda::Network do
  let(:browser) { FakeBrowser.new }
  let(:network) { Capybara::Lightpanda::Network.new(browser) }

  describe "#enable / #disable" do
    it "is idempotent" do
      network.enable
      network.enable
      enable_calls = browser.commands.count { |m, _| m == "Network.enable" }
      assert_equal 1, enable_calls
    end

    it "removes its event subscriptions on disable" do
      network.enable
      assert_equal 1, browser.subscriber_count("Network.requestWillBeSent")
      assert_equal 1, browser.subscriber_count("Network.responseReceived")

      network.disable
      assert_equal 0, browser.subscriber_count("Network.requestWillBeSent")
      assert_equal 0, browser.subscriber_count("Network.responseReceived")
    end

    it "sends Network.disable to the browser BEFORE unsubscribing locally" do
      network.enable
      browser.ops.clear
      network.disable

      disable_idx = browser.ops.index { |kind, m| kind == :command && m == "Network.disable" }
      first_off_idx = browser.ops.index { |kind, _| kind == :off }

      refute_nil disable_idx
      refute_nil first_off_idx
      # Browser stops emitting first; in-flight responseReceived events still
      # have a chance to land on the live handlers.
      assert_operator disable_idx, :<, first_off_idx
    end

    it "does not duplicate handlers across enable→disable→enable cycles" do
      network.enable
      network.disable
      network.enable

      assert_equal 1, browser.subscriber_count("Network.requestWillBeSent")
      assert_equal 1, browser.subscriber_count("Network.responseReceived")
    end

    it "records each request exactly once after enable→disable→enable" do
      network.enable
      network.disable
      network.enable

      browser.fire("Network.requestWillBeSent", {
                     "requestId" => "r1",
                     "request" => { "url" => "https://example.test/x", "method" => "GET" },
                     "timestamp" => 1.0,
                   })
      assert_equal 1, network.traffic.size
    end
  end

  describe "#pending_connections / #idle?" do
    it "counts requests with no response as pending" do
      network.enable
      browser.fire("Network.requestWillBeSent", {
                     "requestId" => "r1",
                     "request" => { "url" => "https://example.test/a", "method" => "GET" },
                     "timestamp" => 1.0,
                   })
      assert_equal 1, network.pending_connections
      refute_predicate network, :idle?

      browser.fire("Network.responseReceived", {
                     "requestId" => "r1",
                     "response" => { "status" => 200, "headers" => {}, "mimeType" => "text/html" },
                   })
      assert_equal 0, network.pending_connections
      assert_predicate network, :idle?
    end

    it "treats up to `connections` pending requests as idle" do
      network.enable
      2.times do |i|
        browser.fire("Network.requestWillBeSent", {
                       "requestId" => "r#{i}",
                       "request" => { "url" => "https://example.test/#{i}", "method" => "GET" },
                       "timestamp" => 1.0,
                     })
      end
      # The whole point of the predicate: callers polling a long-poll
      # connection can mark "≤1 pending" as effectively idle.
      assert network.idle?(2), "two pending with allowance of 2 should be idle"
      refute network.idle?(1), "two pending with allowance of 1 should not be idle"
    end
  end

  describe "#wait_for_idle!" do
    it "raises TimeoutError when traffic never settles" do
      network.enable
      browser.fire("Network.requestWillBeSent", {
                     "requestId" => "stuck",
                     "request" => { "url" => "https://example.test/stuck", "method" => "GET" },
                     "timestamp" => 1.0,
                   })
      # `wait_for_idle` returns false silently — the raising variant gives
      # callers a precondition they can rely on without a manual `or raise`.
      assert_raises(Capybara::Lightpanda::TimeoutError) do
        network.wait_for_idle!(timeout: 0.05)
      end
    end

    it "returns true when traffic is already idle" do
      network.enable
      assert_equal true, network.wait_for_idle!(timeout: 0.05)
    end
  end

  describe "#reset" do
    it "wipes traffic, drops handlers, and clears @enabled so the next enable re-arms" do
      network.enable
      browser.fire("Network.requestWillBeSent", {
                     "requestId" => "r1",
                     "request" => { "url" => "https://example.test/x", "method" => "GET" },
                     "timestamp" => 1.0,
                   })
      refute_empty network.traffic

      # Browser#reset disposes the BrowserContext, which destroys the
      # subscriptions and the Network domain. Network#reset mirrors that
      # by dropping local state without sending Network.disable.
      network.reset
      assert_empty network.traffic

      # After reset, a fresh enable must re-issue Network.enable AND
      # re-install handlers, otherwise traffic tracking is silently dead.
      browser.commands.clear
      network.enable
      assert_includes browser.commands, ["Network.enable", {}]
      assert_equal 1, browser.subscriber_count("Network.requestWillBeSent")
    end
  end
end
