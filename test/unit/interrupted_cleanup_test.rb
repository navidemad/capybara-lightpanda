# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "timeout"

# Teardown must finish even when an interrupt cuts it short.
#
# WHY THIS MATTERS: a hung browser never answers the close frame, so each
# teardown step waits out its join (1 s) or its SIGTERM grace (3 s). A suite
# that wraps quit in Timeout.timeout, a Ctrl-C, or a Thread#raise lands its
# exception inside one of those waits. None of them is a StandardError, so the
# old `rescue StandardError` / `join(1) || kill` code skipped everything after
# the wait: Lightpanda kept running (untracked, so only the finalizer reaped it
# at exit), its threads and socket stayed open, and the Browser still claimed
# to be started (rubycdp/ferrum#738, #740).
describe "teardown interrupted by an outer timeout" do
  def sleeping_thread
    Thread.new { sleep }
  end

  describe Capybara::Lightpanda::Client::WebSocket do
    it "kills the reader and closes the socket when the join is interrupted" do
      ws = Capybara::Lightpanda::Client::WebSocket.allocate
      local, remote = UNIXSocket.pair
      reader = sleeping_thread
      ws.instance_variable_set(:@status, :open)
      ws.instance_variable_set(:@messages, Thread::Queue.new)
      ws.instance_variable_set(:@driver_mutex, Mutex.new)
      ws.instance_variable_set(:@driver, nil)
      ws.instance_variable_set(:@thread, reader)
      ws.instance_variable_set(:@socket, local)

      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { ws.close } }

      assert reader.join(1), "the reader thread outlived an interrupted close"
      assert_predicate local, :closed?
      assert_predicate ws, :closed?
    ensure
      remote&.close
    end
  end

  describe Capybara::Lightpanda::Client do
    it "kills the message thread and releases pending commands when the join is interrupted" do
      client = Capybara::Lightpanda::Client.allocate
      message_thread = sleeping_thread
      pending = Concurrent::IVar.new
      client.instance_variable_set(:@ws, stub(close: nil))
      client.instance_variable_set(:@message_thread, message_thread)
      client.instance_variable_set(:@subscriber, Capybara::Lightpanda::Client::Subscriber.new)
      client.instance_variable_set(:@pendings, Concurrent::Hash.new.merge!(1 => pending))

      assert_raises(Timeout::Error) { Timeout.timeout(0.2) { client.close } }

      assert message_thread.join(1), "the message thread outlived an interrupted close"
      assert_predicate pending, :complete?, "a caller blocked on its command would wait out its full timeout"
    end
  end

  describe "Capybara::Lightpanda::Process.terminate" do
    it "still sends SIGKILL and reaps when the SIGTERM grace wait is interrupted" do
      process_class = Capybara::Lightpanda::Process
      process_class.stubs(:signal)
      process_class.stubs(:reap_within).raises(Interrupt)
      process_class.expects(:signal).with(4242, "KILL")
      Process.expects(:wait).with(4242)

      assert_raises(Interrupt) { process_class.send(:terminate, 4242) }
    end

    it "sends no SIGKILL once SIGTERM reaped the child" do
      process_class = Capybara::Lightpanda::Process
      process_class.stubs(:reap_within).returns(true)
      process_class.expects(:signal).with(4242, "TERM")
      process_class.expects(:signal).with(4242, "KILL").never

      process_class.send(:terminate, 4242)
    end
  end

  describe Capybara::Lightpanda::Browser do
    it "stops the process and forgets the session when closing the client is interrupted" do
      browser = Capybara::Lightpanda::Browser.allocate
      process = mock("Process")
      process.expects(:stop)
      client = mock("Client")
      client.stubs(:close).raises(Interrupt)
      browser.instance_variable_set(:@client, client)
      browser.instance_variable_set(:@process, process)
      browser.instance_variable_set(:@started, true)
      browser.instance_variable_set(:@frame_stack, [])

      assert_raises(Interrupt) { browser.quit }

      assert_nil browser.process
      assert_nil browser.client
      refute browser.instance_variable_get(:@started), "a later start would return early on the closed client"
    end

    # The 3 s SIGTERM grace is the longest wait in quit, so it is where an
    # outer timeout most often lands; it runs inside quit's own ensure.
    it "forgets the session when the process stop itself is interrupted" do
      browser = Capybara::Lightpanda::Browser.allocate
      process = mock("Process")
      process.stubs(:stop).raises(Interrupt)
      browser.instance_variable_set(:@client, stub(close: nil))
      browser.instance_variable_set(:@process, process)
      browser.instance_variable_set(:@started, true)
      browser.instance_variable_set(:@frame_stack, [])

      assert_raises(Interrupt) { browser.quit }

      assert_nil browser.process
      refute browser.instance_variable_get(:@started)
    end
  end
end
