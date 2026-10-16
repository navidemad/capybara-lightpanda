# frozen_string_literal: true

require_relative "../test_helper"

# Clicking a mailto: or tel: link keeps the page, as in Chrome (which hands the
# URL to an external app).
#
# WHY THIS MATTERS: below Lightpanda #3940 (10536, now in the floor) the link's
# own activation navigated: on 1.0.0 `mailto:someone@host` became
# `http://mailto:someone@host/`, so the test left the page and fetched whatever
# host the address named; on nightlies 10261–10535 a `tel:` click lost the
# execution context and raised NoExecutionContextError after the full timeout.
# CLICK_JS must also not navigate to such a link itself, and must not cancel the
# click, so page code still sees an uncancelled one.
describe "Capybara::Lightpanda clicks on links to external schemes" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  before { session.visit("/lightpanda/external_links") }

  it "stays on the page for a mailto: link, even when the click lands on its child" do
    page_url = session.current_url

    session.find("#mail span").click

    assert_equal page_url, session.current_url
    assert session.evaluate_script("window.__kept"), "the page was reloaded or replaced"
  end

  it "stays on the page for a tel: link" do
    page_url = session.current_url

    session.click_link("Call us")

    assert_equal page_url, session.current_url
    assert session.evaluate_script("window.__kept"), "the page was reloaded or replaced"
  end

  it "lets the page's own listeners see an uncancelled click" do
    session.click_link("Email us")

    assert_equal [false], session.evaluate_script("window.__clicks")
  end
end
