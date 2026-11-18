# frozen_string_literal: true

require_relative "../test_helper"

# A request that ends in Network.loadingFailed instead of a response.
#
# WHY THIS MATTERS: Lightpanda enforces CORS by default since upstream #3654
# (build 9883, in release 1.0.0). A blocked request never gets a response, so
# before the gem consumed Network.loadingFailed its traffic entry stayed open
# and every `wait_for_network_idle` after it burned its whole timeout — a
# suite with one misconfigured cross-origin call got slow everywhere and its
# idle waits silently returned false.
describe "Capybara::Lightpanda failed network requests" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "lets a native session inspect the browser's error document after a refused visit" do
    session.visit("http://127.0.0.1:#{TestApp::REFUSED_PORT}/unavailable")
    assert session.has_text?("Navigation failed")
    assert_nil session.status_code
  end

  it "reports a pending dialog on the refused Cuprite visit so the next visit can succeed" do
    Capybara::Lightpanda.register_cuprite_driver(:strict_navigation, raise_on_unhandled_modal: true,
                                                                     browser_path: ENV.fetch("LIGHTPANDA_BIN", nil))
    page = Capybara::Session.new(:strict_navigation, TestApp)
    page.visit("/lightpanda/simple")
    page.execute_script("setTimeout(() => { alert('pending'); document.body.dataset.done = 'yes' }, 0)")
    assert page.has_css?("body[data-done=yes]", visible: :all)

    error = assert_raises(Capybara::Lightpanda::UnhandledModalError) do
      page.visit("http://127.0.0.1:#{TestApp::REFUSED_PORT}/unavailable")
    end
    assert_includes error.message, "pending"
    page.visit("/lightpanda/simple")
    assert_equal "/lightpanda/simple", page.current_path
  ensure
    page&.driver&.quit
  end

  it "does not count a CORS-blocked request as in flight" do
    session.visit("/lightpanda/cross_origin_fetch")
    assert session.has_no_css?("#result", text: "pending")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    idle = session.driver.wait_for_network_idle(timeout: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert idle, "wait_for_network_idle timed out with #{session.driver.network.pending_connections} pending"
    assert_operator elapsed, :<, 1.5
  end

  it "records the failure reason on the traffic entry" do
    session.visit("/lightpanda/cross_origin_fetch")
    assert session.has_css?("#result", text: "blocked")

    entry = session.driver.network.traffic.find { |t| t[:url].to_s.end_with?("/lightpanda/cors_target") }

    refute_nil entry, "the blocked fetch should still be tracked"
    assert_nil entry[:response]
    assert_equal "CorsBlocked", entry[:error]
  end
end
