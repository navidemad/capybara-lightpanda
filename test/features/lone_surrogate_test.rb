# frozen_string_literal: true

require_relative "../test_helper"

# A JS-computed string can end in half an emoji. Lightpanda sends it as a lone
# `\ud83d` escape that Ruby's json rejects; the reply frame used to be dropped
# and evaluate_script raised TimeoutError after the full command timeout.
# Chrome hands back U+FFFD for the same value.
describe "evaluate_script returning a lone surrogate" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/js_test") }
  after { session.reset_session! }

  it "returns the string with U+FFFD instead of timing out" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = session.evaluate_script('"a" + "\uD83D\uDE00".slice(0, 1) + "b"')
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "a\uFFFDb", result
    assert_operator elapsed, :<, 2, "the reply frame was dropped and the command waited out its timeout"
  end
end
