# frozen_string_literal: true

require "bundler/setup"
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

RSpec.describe Capybara::Lightpanda::Network do
  let(:browser) { FakeBrowser.new }
  subject(:network) { described_class.new(browser) }

  describe "#enable / #disable" do
    it "is idempotent" do
      network.enable
      network.enable
      enable_calls = browser.commands.count { |m, _| m == "Network.enable" }
      expect(enable_calls).to eq(1)
    end

    it "removes its event subscriptions on disable" do
      network.enable
      expect(browser.subscriber_count("Network.requestWillBeSent")).to eq(1)
      expect(browser.subscriber_count("Network.responseReceived")).to eq(1)

      network.disable
      expect(browser.subscriber_count("Network.requestWillBeSent")).to eq(0)
      expect(browser.subscriber_count("Network.responseReceived")).to eq(0)
    end

    it "sends Network.disable to the browser BEFORE unsubscribing locally" do
      network.enable
      browser.ops.clear
      network.disable

      disable_idx = browser.ops.index { |kind, m| kind == :command && m == "Network.disable" }
      first_off_idx = browser.ops.index { |kind, _| kind == :off }

      expect(disable_idx).not_to be_nil
      expect(first_off_idx).not_to be_nil
      # Browser stops emitting first; in-flight responseReceived events still
      # have a chance to land on the live handlers.
      expect(disable_idx).to be < first_off_idx
    end

    it "does not duplicate handlers across enable→disable→enable cycles" do
      network.enable
      network.disable
      network.enable

      expect(browser.subscriber_count("Network.requestWillBeSent")).to eq(1)
      expect(browser.subscriber_count("Network.responseReceived")).to eq(1)
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
      expect(network.traffic.size).to eq(1)
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
      expect(network.traffic).not_to be_empty

      # Browser#reset disposes the BrowserContext, which destroys the
      # subscriptions and the Network domain. Network#reset mirrors that
      # by dropping local state without sending Network.disable.
      network.reset
      expect(network.traffic).to be_empty

      # After reset, a fresh enable must re-issue Network.enable AND
      # re-install handlers, otherwise traffic tracking is silently dead.
      browser.commands.clear
      network.enable
      expect(browser.commands).to include(["Network.enable", {}])
      expect(browser.subscriber_count("Network.requestWillBeSent")).to eq(1)
    end
  end
end
