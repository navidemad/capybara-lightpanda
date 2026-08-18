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

  describe "header setters" do
    # Cuprite/Ferrum parity: callers expect `network.headers = {…}` to "just
    # work" without remembering to flip `enable` on first. Previously the
    # CDP setExtraHTTPHeaders call landed before Network.enable and could be
    # silently dropped depending on browser state.
    it "auto-enables the Network domain on assignment" do
      network.headers = { "X-Test" => "1" }
      assert_includes browser.commands, ["Network.enable", {}]
    end

    it "auto-enables the Network domain on add_headers" do
      network.add_headers("X-Add" => "1")
      assert_includes browser.commands, ["Network.enable", {}]
    end

    it "auto-enables the Network domain on clear_headers" do
      network.clear_headers
      assert_includes browser.commands, ["Network.enable", {}]
    end
  end

  describe "thread safety" do
    # CDP events arrive on the message thread; main-thread callers read the
    # same @traffic array. A plain Array under concurrent push/find can yield
    # inconsistent counts on MRI and raise ConcurrentModificationError on
    # JRuby/TruffleRuby. The mutex around mutations and reads keeps the
    # collection consistent for callers like wait_for_idle.
    it "survives concurrent pushes and reads without losing entries" do
      network.enable

      writer = Thread.new do
        500.times do |i|
          browser.fire("Network.requestWillBeSent", {
                         "requestId" => "r#{i}",
                         "request" => { "url" => "https://example.test/#{i}", "method" => "GET" },
                         "timestamp" => i.to_f,
                       })
        end
      end

      reader_samples = []
      reader = Thread.new do
        100.times do
          reader_samples << network.pending_connections
        end
      end

      [writer, reader].each(&:join)

      assert_equal 500, network.traffic.size
      assert reader_samples.all? { |n| n.between?(0, 500) },
             "pending_connections returned out-of-range value: #{reader_samples.inspect}"
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

    it "clears extra_headers — the fresh BrowserContext never received them" do
      network.headers = { "X-Stale" => "1" }

      network.reset

      # Keeping the cache would make Driver#headers report values the browser
      # stopped sending the moment the context was disposed.
      assert_empty network.extra_headers
    end
  end

  # Network owns the navigation-response capture behind Browser#status_code /
  # #response_headers. Lightpanda omits `type` on responseReceived, so the
  # match runs through the remembered document requestId.
  describe "navigation response capture" do
    def fire_request(id, type: nil)
      params = {
        "requestId" => id,
        "request" => { "url" => "https://example.test/", "method" => "GET" },
        "timestamp" => 1.0,
      }
      params["type"] = type if type
      browser.fire("Network.requestWillBeSent", params)
    end

    def fire_response(id, status: 200)
      browser.fire("Network.responseReceived", {
                     "requestId" => id,
                     "response" => { "status" => status, "headers" => { "content-type" => "text/html" } },
                   })
    end

    it "remembers the last document response" do
      network.enable
      fire_request("doc1", type: "Document")
      fire_response("doc1", status: 301)

      assert_equal 301, network.last_navigation_response[:status]
      assert_equal "text/html", network.last_navigation_response[:headers]["content-type"]
    end

    it "ignores subresource responses — only the document request counts" do
      network.enable
      fire_request("doc1", type: "Document")
      fire_response("doc1", status: 200)
      fire_request("img1")
      fire_response("img1", status: 404)

      assert_equal 200, network.last_navigation_response[:status]
    end

    it "clears on reset so the fresh context starts with no phantom status" do
      network.enable
      fire_request("doc1", type: "Document")
      fire_response("doc1")

      network.reset

      assert_nil network.last_navigation_response
    end
  end

  describe "redirect chains" do
    # Chrome — and Lightpanda since #3175 (build ≥8602, in 0.3.7) — announces
    # every followed hop with a SECOND requestWillBeSent carrying the same
    # requestId plus the 3xx as `redirectResponse`, and never sends a
    # responseReceived for the 3xx itself. If the hop's event doesn't close the
    # previous entry, that entry stays pending forever: one redirect wedges
    # pending_connections at 1 and every wait_for_network_idle burns its full
    # timeout for the rest of the session. This is the Rails post-create /
    # post-login flow, so it must stay cheap.
    def fire_document_request(id, url, redirect_status: nil)
      params = {
        "requestId" => id,
        "type" => "Document",
        "request" => { "url" => url, "method" => "GET" },
        "timestamp" => 1.0,
      }
      if redirect_status
        params["redirectResponse"] = { "status" => redirect_status, "headers" => { "location" => url } }
      end
      browser.fire("Network.requestWillBeSent", params)
    end

    def fire_final_response(id, status: 200)
      browser.fire("Network.responseReceived", {
                     "requestId" => id,
                     "response" => { "status" => status, "headers" => {}, "mimeType" => "text/html" },
                   })
    end

    it "closes the previous hop from redirectResponse so a redirect leaves nothing pending" do
      network.enable
      fire_document_request("nav", "https://example.test/things")
      fire_document_request("nav", "https://example.test/things/1", redirect_status: 302)
      fire_final_response("nav")

      assert_equal 0, network.pending_connections
      assert network.idle?
      assert_equal([302, 200], network.traffic.map { |t| t.dig(:response, :status) })
    end

    it "keeps status_code on the final hop, not the 3xx" do
      network.enable
      fire_document_request("nav", "https://example.test/things")
      fire_document_request("nav", "https://example.test/things/1", redirect_status: 302)
      fire_final_response("nav", status: 200)

      assert_equal 200, network.last_navigation_response[:status]
    end

    it "resolves the response onto the newest open entry across a multi-hop chain" do
      network.enable
      fire_document_request("nav", "https://example.test/a")
      fire_document_request("nav", "https://example.test/b", redirect_status: 301)
      fire_document_request("nav", "https://example.test/c", redirect_status: 302)
      fire_final_response("nav", status: 404)

      assert_equal 0, network.pending_connections
      assert_equal(%w[a b c], network.traffic.map { |t| t[:url][-1] })
      assert_equal([301, 302, 404], network.traffic.map { |t| t.dig(:response, :status) })
    end

    it "still works below build 8602, where a chain is a single requestWillSent" do
      network.enable
      fire_document_request("nav", "https://example.test/things")
      fire_final_response("nav")

      assert_equal 0, network.pending_connections
      assert_equal([200], network.traffic.map { |t| t.dig(:response, :status) })
    end
  end

  describe "#enable failure rollback" do
    it "unsubscribes the just-installed handlers when Network.enable fails" do
      browser.expects(:command).with("Network.enable").raises(Capybara::Lightpanda::TimeoutError).once

      assert_raises(Capybara::Lightpanda::TimeoutError) { network.enable }
      # Orphaned handlers would double-count every request after the next
      # successful enable, wedging pending_connections above zero forever.
      assert_equal 0, browser.subscriber_count("Network.requestWillBeSent")

      browser.unstub(:command)
      network.enable
      browser.fire("Network.requestWillBeSent", {
                     "requestId" => "r1",
                     "request" => { "url" => "https://example.test/", "method" => "GET" },
                     "timestamp" => 1.0,
                   })
      assert_equal 1, network.traffic.size
    end
  end

  describe "traffic cap" do
    it "drops oldest entries past TRAFFIC_LIMIT — tracking is always on, the buffer must not grow unbounded" do
      network.enable
      (Capybara::Lightpanda::Network::TRAFFIC_LIMIT + 5).times do |i|
        browser.fire("Network.requestWillBeSent", {
                       "requestId" => "r#{i}",
                       "request" => { "url" => "https://example.test/#{i}", "method" => "GET" },
                       "timestamp" => i.to_f,
                     })
      end

      assert_equal Capybara::Lightpanda::Network::TRAFFIC_LIMIT, network.traffic.size
      assert_equal "r5", network.traffic.first[:request_id] # oldest five dropped
    end
  end
end
