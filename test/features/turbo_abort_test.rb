# frozen_string_literal: true

require_relative "../test_helper"

# Issue #218: Turbo swallows an aborted fetch's AbortError, so neither
# turbo:before-fetch-response nor turbo:fetch-request-error follows its
# turbo:before-fetch-request. When the tracker only counted those two events,
# one aborted frame fetch left Browser#wait_for_idle waiting the full driver
# timeout on every later click. Real Turbo bundle, real Lightpanda.
describe "Turbo fetch aborted mid-flight" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "does not leave later clicks waiting for Turbo to go idle" do
    session.visit("/lightpanda/probe/turbo_frame_abort")
    session.execute_script(<<~JS)
      var frame = document.getElementById("slow-frame");
      frame.src = "/lightpanda/probe/slow_frame";
      setTimeout(function() { frame.removeAttribute("src"); }, 300);
    JS
    # Let the fetch start and be aborted (the endpoint answers after 3s).
    sleep 1

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.click_button("Plain")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2,
                    "click waited #{elapsed.round(2)}s: the aborted fetch kept the Turbo tracker busy"
    assert_equal 0, session.evaluate_script("window._lightpanda.turbo.pending()")
  end
end
