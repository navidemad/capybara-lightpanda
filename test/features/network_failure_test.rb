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
