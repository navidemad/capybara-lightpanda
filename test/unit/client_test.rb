# frozen_string_literal: true

require_relative "../test_helper"
require "concurrent-ruby"
require "capybara/lightpanda/client"

# Constructing a real Client opens a WebSocket. For the close-time fail-fast
# behavior we only care about #fail_pending_commands operating on @pendings,
# so we bypass full init with `Client.allocate` + state injection.
describe Capybara::Lightpanda::Client do
  describe "#close fails pending commands fast" do
    let(:client) { Capybara::Lightpanda::Client.allocate }
    let(:pendings) { Concurrent::Hash.new }

    before do
      client.instance_variable_set(:@pendings, pendings)
    end

    it "resolves blocked IVars so callers fall through value!(timeout) immediately" do
      ivar = Concurrent::IVar.new
      pendings[1] = ivar

      # Before fix: the IVar stayed unresolved and a caller blocked here for
      # the full @options.timeout (often 30s) before raising DeadBrowserError.
      # After fix: try_set(nil) wakes the waiter; value!(short_timeout) returns
      # nil and the caller's @ws.closed? check raises immediately.
      waiter = Thread.new { ivar.value!(5) }

      client.send(:fail_pending_commands)

      assert_nil waiter.value
    end

    it "is a no-op for IVars that already carry a real response" do
      ivar = Concurrent::IVar.new
      response = { "id" => 1, "result" => { "ok" => true } }
      ivar.set(response)
      pendings[1] = ivar

      # try_set must not clobber a response that landed just before close.
      client.send(:fail_pending_commands)

      assert_equal response, ivar.value
    end

    it "handles an empty pendings hash" do
      client.send(:fail_pending_commands)
      pass
    end
  end

  describe "#handle_message" do
    let(:client) { Capybara::Lightpanda::Client.allocate }
    let(:pendings) { Concurrent::Hash.new }

    before do
      client.instance_variable_set(:@pendings, pendings)
    end

    it "keeps the first response when a duplicate frame arrives for the same id" do
      ivar = Concurrent::IVar.new
      pendings[7] = ivar
      first = { "id" => 7, "result" => { "ok" => true } }
      duplicate = { "id" => 7, "result" => { "ok" => false } }

      client.send(:handle_message, first)
      # Lightpanda occasionally emits malformed/duplicate frames (upstream
      # A41). With IVar#set this raised MultipleAssignmentError on the message
      # thread, where abort_on_exception kills the entire Ruby process.
      client.send(:handle_message, duplicate)

      assert_equal first, ivar.value
    end
  end

  # `timeout:` is the caller's budget for the whole command. It used to start
  # only after the frame was sent, so a send slowed by a busy browser or a
  # contended socket lock added its own duration on top: a 15 s command could
  # block 30 s.
  describe "#command deadline" do
    let(:client) { Capybara::Lightpanda::Client.allocate }
    let(:pendings) { Concurrent::Hash.new }

    def fake_ws(send_seconds, &on_send)
      ws = Object.new
      ws.define_singleton_method(:send_message) do |message, **|
        sleep send_seconds
        on_send&.call(message)
      end
      ws.define_singleton_method(:closed?) { false }
      ws
    end

    before do
      client.instance_variable_set(:@pendings, pendings)
      client.instance_variable_set(:@mutex, Mutex.new)
      client.instance_variable_set(:@command_id, 0)
      client.instance_variable_set(:@options, Capybara::Lightpanda::Options.new(timeout: 5))
    end

    it "counts the time spent sending against the command's timeout" do
      client.instance_variable_set(:@ws, fake_ws(0.4))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Capybara::Lightpanda::TimeoutError) { client.command("Page.enable", timeout: 0.5) }

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 0.75, "command took #{elapsed.round(2)}s against a 0.5s timeout"
    end

    it "still returns a response that arrived while the send used up the budget" do
      ws = fake_ws(0.3) do |message|
        id = JSON.parse(message)["id"]
        pendings[id].set({ "id" => id, "result" => { "ok" => true } })
      end
      client.instance_variable_set(:@ws, ws)

      assert_equal({ "ok" => true }, client.command("Page.enable", timeout: 0.2))
    end
  end
end
