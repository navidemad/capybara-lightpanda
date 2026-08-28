# frozen_string_literal: true

require_relative "../test_helper"

# Records the order of the three things Node#send_keys does, so a test can
# assert the settle step happens *after* the keys are delivered.
class FakeSendKeysBrowser
  attr_reader :calls, :keyboard

  def initialize
    @calls = []
    @keyboard = FakeSendKeysKeyboard.new(self)
  end

  def record(name)
    @calls << name
  end

  def with_default_context_wait
    yield
  end

  def call_function_on(_object_id, declaration, *_args, **_opts)
    @calls << (declaration.include?("focus()") ? :focus : :other_call)
    nil
  end

  def wait_for_idle
    @calls << :wait_for_idle
  end
end

class FakeSendKeysKeyboard
  def initialize(browser)
    @browser = browser
  end

  def type(*keys)
    @browser.record([:type, keys])
  end
end

class FakeSendKeysDriver
  attr_reader :browser

  def initialize(browser)
    @browser = browser
  end
end

describe "Capybara::Lightpanda::Node#send_keys" do
  let(:browser) { FakeSendKeysBrowser.new }
  let(:node) { Capybara::Lightpanda::Node.new(FakeSendKeysDriver.new(browser), "obj-1") }

  # WHY THIS IS PINNED AT THE MECHANISM LEVEL RATHER THAN BEHAVIOURALLY:
  # since upstream #3264 (build >= 8842) a CDP key event is *trusted*, so
  # Enter on a submit input and Space on a checkbox synthesize a real
  # activation click — which means send_keys can now start a navigation.
  # Node#click has always ended with wait_for_idle for exactly that reason;
  # send_keys did not, because before #3264 it could not navigate anything.
  # The result was a suite-order-dependent failure in
  # test/features/keyboard_activation_test.rb: current_url was read against
  # the outgoing document and returned the *old* path.
  #
  # It is pinned here, not as a feature test, because the behavioural version
  # is inherently racy in both directions — over loopback the navigation
  # usually lands within a few ms, so the unfixed code passes most of the
  # time, and no fixture can make it fail deterministically without also
  # exceeding what wait_for_idle actually guarantees (a 50 ms sniff window;
  # see the note on Browser#wait_for_idle). What must not regress is the
  # *contract*: keys are delivered, then the driver settles.
  it "settles the page after delivering the keys, like #click does" do
    node.send_keys(:enter)

    assert_equal [:focus, [:type, [:enter]], :wait_for_idle], browser.calls
  end

  # The settle must come last. Waiting before the keys are delivered would
  # look identical in a passing suite and restore the original bug.
  it "settles after, not before, the keystrokes" do
    node.send_keys("hi")

    typed_at = browser.calls.index { |c| c.is_a?(Array) && c.first == :type }

    assert_operator browser.calls.index(:wait_for_idle), :>, typed_at
  end
end
