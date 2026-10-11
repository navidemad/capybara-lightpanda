# frozen_string_literal: true

require_relative "../test_helper"

# A link clicked inside an iframe navigates that iframe, not the whole page.
#
# `CLICK_JS` drives `<a href>` navigation itself by assigning a location. It
# runs through `Runtime.callFunctionOn`, and Lightpanda runs that in the top
# document's context even for an iframe node, so a bare `window.location`
# was the top window's: `click_link` inside `within_frame` replaced the whole
# page with the frame's target (the iframe, and everything around it, gone),
# and a `#fragment` link in a frame did the same, since its URL never matched
# the top page's. Chrome navigates the frame. The location now comes from the
# link's own document, and `target="_top"` / `"_parent"` still leave the frame.
describe "Capybara::Lightpanda link clicks inside an iframe" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  before { session.visit("/lightpanda/with_versioned_frame") }

  it "navigates the frame and leaves the page around it in place" do
    page_url = session.current_url

    session.within_frame("versioned-frame") do
      session.click_link("Next")
      assert session.has_css?("#version", text: "v2")
    end

    assert_equal page_url, session.current_url
    assert session.has_css?("#versioned-frame", wait: 0)
  end

  it "follows a fragment link within the frame's own document" do
    page_url = session.current_url

    session.within_frame("versioned-frame") do
      session.click_link("Jump")
      assert_equal "#bottom", URI(session.driver.frame_url).fragment&.prepend("#")
      assert session.has_css?("#version", text: "v1", wait: 0)
    end

    assert_equal page_url, session.current_url
  end

  it "navigates the top page for a target=_top link" do
    session.within_frame("versioned-frame") { session.click_link("Leave frame") }

    assert session.has_title?("Frame v2")
    assert session.has_no_css?("#versioned-frame")
  end
end
