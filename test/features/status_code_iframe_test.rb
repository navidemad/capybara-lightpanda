# frozen_string_literal: true

require_relative "../test_helper"

# Issue #221. Iframes load by default (LP.configureLoading subFrame: true) and
# Lightpanda types their document requests "Document" like the page's own, so
# the iframe that loaded last used to become the page: a 200 page embedding a
# 404 iframe reported status_code 404 and the iframe's headers.
describe "status_code on a page with an iframe" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "reports the top document's response, not the iframe's" do
    session.visit("/lightpanda/with_missing_frame")
    # The iframe's request lands after the page's; wait until it has.
    session.driver.wait_for_network_idle

    assert_equal 200, session.status_code
    assert_nil session.response_headers["X-Frame-Document"]
  end
end
