# frozen_string_literal: true

require_relative "../test_helper"

# find_modal is woken by the dialog handler instead of polling.
#
# WHY THIS MATTERS: every accept_* / dismiss_* ends in find_modal, and the old
# 50 ms poll added up to 50 ms (25 ms on average) to each one after the dialog
# had already opened, for nothing (rubycdp/cuprite#394). The handler that
# queues the dialog now signals the waiter. The rest of the contract must hold:
# only a matching dialog is claimed, and a miss still reports the last dialog
# seen and disarms Lightpanda's pre-armed answer.
describe "Browser#find_modal wait" do
  let(:browser) do
    b = Capybara::Lightpanda::Browser.allocate
    b.instance_variable_set(:@options, Capybara::Lightpanda::Options.new)
    b.instance_variable_set(:@modal_messages, [])
    b.instance_variable_set(:@modal_messages_mutex, Mutex.new)
    b.instance_variable_set(:@modal_arrived, ConditionVariable.new)
    b.instance_variable_set(:@modal_handler_installed, false)
    b.instance_variable_set(:@modal_armed, true)
    b.instance_variable_set(:@unhandled_modal, nil)
    b
  end

  # The handler prepare_modals subscribes, captured so the test fires the real
  # one, as the message thread does on Page.javascriptDialogOpening.
  let(:dialog_opened) do
    handler = nil
    browser.stubs(:enable_page_events)
    browser.define_singleton_method(:on) { |_event, &block| handler = block }
    browser.send(:prepare_modals)
    ->(message, type = "confirm") { handler.call("type" => type, "message" => message) }
  end

  def seconds_to_claim(message)
    fire = dialog_opened
    waiter = Thread.new { browser.find_modal(:confirm, text: message, wait: 2) }
    sleep 0.02 # let the waiter block first
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fire.call(message)
    claimed = waiter.value
    [claimed, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  it "claims a dialog as soon as its event is handled, not on the next poll" do
    latencies = Array.new(10) do
      browser.instance_variable_set(:@modal_armed, true)
      claimed, latency = seconds_to_claim("Delete?")
      assert_equal "Delete?", claimed
      latency
    end

    median = latencies.sort[latencies.size / 2]
    assert_operator median, :<, 0.01, "median wake-up #{(median * 1000).round(1)} ms: still polling?"
  end

  it "keeps waiting past a dialog that doesn't match" do
    fire = dialog_opened
    waiter = Thread.new { browser.find_modal(:confirm, text: "Delete?", wait: 2) }
    sleep 0.02
    fire.call("Something else")
    sleep 0.02
    assert waiter.alive?, "a non-matching dialog must not end the wait"

    fire.call("Delete?")
    assert_equal "Delete?", waiter.value
  end

  it "reports the last dialog seen and disarms when nothing matches in time" do
    fire = dialog_opened
    fire.call("Something else")
    browser.instance_variable_set(:@modal_armed, true)
    browser.expects(:page_command).with("LP.handleJavaScriptDialog", accept: false)

    error = assert_raises(Capybara::ModalNotFound) { browser.find_modal(:confirm, text: "Delete?", wait: 0.05) }
    assert_match(/found 'Something else' instead/, error.message)
  end
end
