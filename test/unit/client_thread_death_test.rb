# frozen_string_literal: true

require_relative "../test_helper"
require "concurrent-ruby"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/client"

# A dying transport thread must never take the host process down, and must
# release every caller blocked on a pending command right away. Before this,
# the message thread ran with abort_on_exception = true and no rescue, so any
# unexpected error in handle_message was re-raised on the main thread — a
# spec failure blamed on whatever call happened to be running, or a server
# dying with its `ensure` never reaching browser.quit (ferrum #632). And a
# connection dropped underneath the client left pendings unresolved until
# their full timeout (ferrum #630).
# Stand-in for Client::WebSocket: just the surface the message thread uses.
ThreadDeathFakeSocket = Struct.new(:messages, :status) do
  def mark_dead(status = :closed)
    self.status = status
    messages.close
  end

  def closed?
    %i[closed error].include?(status)
  end
end

describe Capybara::Lightpanda::Client do
  let(:client) { Capybara::Lightpanda::Client.allocate }
  let(:ws) { ThreadDeathFakeSocket.new(Queue.new, :open) }
  let(:pendings) { Concurrent::Hash.new }

  before do
    client.instance_variable_set(:@ws, ws)
    client.instance_variable_set(:@pendings, pendings)
    client.instance_variable_set(:@subscriber, Capybara::Lightpanda::Client::Subscriber.new)
  end

  it "survives an unexpected error in handle_message, marks the connection dead and releases pendings" do
    ivar = Concurrent::IVar.new
    pendings[1] = ivar
    # The exact shape of the ferrum repro: an errno the IO rescue never
    # listed, surfacing out of the frame pipeline.
    client.stubs(:handle_message).raises(Errno::ETIMEDOUT)

    _out, err = capture_io do
      client.send(:start_message_thread)
      ws.messages << { "id" => 1 }
      client.instance_variable_get(:@message_thread).join(2)
    end

    # The process — this test — is still alive, the death was reported, the
    # waiter is released with nil, and the socket now reads as dead so the
    # caller's next check raises DeadBrowserError rather than TimeoutError.
    assert_match(/message thread died.*ETIMEDOUT/, err)
    assert_nil ivar.value!(1)
    assert_predicate ws, :closed?
    assert_equal :error, ws.status
  end

  it "releases pendings when the connection dies underneath it (queue closed by the reader)" do
    ivar = Concurrent::IVar.new
    pendings[1] = ivar
    client.send(:start_message_thread)

    # Before: the waiter sat here for the full command timeout (30s by
    # default) because fail_pending_commands ran only from an orderly #close.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ws.mark_dead
    result = ivar.value!(5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_nil result
    assert_operator elapsed, :<, 1, "waiter should be released immediately, waited #{elapsed.round(2)}s"
    assert_predicate ws, :closed?
  end
end
