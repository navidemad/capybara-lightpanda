# frozen_string_literal: true

require_relative "../test_helper"

# `visit` must not return before the page's own scripts ran: Stimulus, Turbo
# and Bootstrap's data-api load as module scripts, and an action sent before
# they wire their handlers is lost. go_to waits 2 s for Page.loadEventFired,
# then polls document.readyState. Since Lightpanda #4554 (11988) the document
# is `interactive` from the end of parsing, while deferred and module scripts
# are still pending, so `interactive` alone no longer proves the page ran.
#
# The other half: a page whose load event never comes (a subresource that
# hangs) must still count as loaded once DOMContentLoaded has fired, or
# every such visit costs the whole timeout.
describe "Browser#go_to readiness fallback" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "waits for a module script that arrives after the load-event wait" do
    session.visit("/lightpanda/visit_wait/late_module")

    assert_equal "ran", session.evaluate_script("document.getElementById('result').textContent"),
                 "visit returned while the module script was still pending"
  end

  it "returns once DOMContentLoaded fired when the load event is held back" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.visit("/lightpanda/visit_wait/slow_iframe")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, TestApp::VISIT_IFRAME_DELAY - 2,
                    "visit waited for the held-back load event (#{elapsed.round(2)} s)"
    assert_equal "ready", session.find(:css, "#ready").text
  end
end
