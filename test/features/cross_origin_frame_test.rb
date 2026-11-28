# frozen_string_literal: true

require_relative "../test_helper"

# within_frame works on a cross-origin iframe.
#
# WHY THIS MATTERS: payment fields (Stripe Elements), video embeds and other
# third-party widgets live in an iframe from another origin. The page can't
# reach its document (contentDocument is null, contentWindow has no eval), and
# every frame path went through the <iframe> element: `find` inside found
# nothing and scripts raised TypeError, so those specs had to stay on Chrome.
# Lightpanda gives the frame its own execution context; the driver now finds
# and scripts there, as a Chrome driver does.
describe "Capybara::Lightpanda within a cross-origin frame" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/with_cross_origin_frames") }
  after { session.reset_session! }

  it "finds elements by CSS, XPath and text" do
    session.within_frame("versioned-frame") do
      assert_equal "v1", session.find(:css, "#version").text
      assert_equal "Next", session.find(:xpath, "//a[@id='next']").text
      assert session.has_link?("Leave frame")
      refute session.has_css?("#outside"), "the page's elements are not in the frame"
    end

    assert session.has_css?("#outside")
  end

  it "follows a link inside the frame and finds the new document" do
    session.within_frame("versioned-frame") do
      session.click_link("Next")

      assert session.has_css?("#version", text: "v2"), "the frame's new document was not found"
    end
  end

  it "fills in a field inside the frame" do
    session.within_frame("input-frame") do
      session.fill_in("frame-input", with: "4242 4242")

      assert_equal "4242 4242", session.find(:css, "#frame-input").value
    end
  end

  # Trusted keys follow the chain of focused <iframe> elements, and a
  # cross-origin frame's `frameElement` is null to the frame itself.
  it "types into a field inside the frame with send_keys" do
    session.within_frame("input-frame") do
      session.find(:css, "#frame-input").send_keys("abc")

      assert_equal "abc", session.find(:css, "#frame-input").value
    end
  end

  it "runs scripts in the frame, with arguments found in it" do
    session.within_frame("versioned-frame") do
      assert_equal "Frame v1", session.evaluate_script("document.title")
      assert_match %r{\Ahttp://localhost:\d+/lightpanda/frame_versioned\?v=1\z},
                   session.evaluate_script("location.href")

      version = session.find(:css, "#version")
      assert_equal "v1", session.evaluate_script("arguments[0].textContent", version)

      session.execute_script("document.getElementById('version').textContent = 'changed'")
      assert session.has_css?("#version", text: "changed")

      assert_equal 3, session.evaluate_async_script("arguments[0](1 + 2)")
    end

    assert_equal "Page with Cross-Origin Frames", session.evaluate_script("document.title")
  end

  it "reports the frame's URL and title" do
    session.within_frame("versioned-frame") do
      assert_equal "Frame v1", session.driver.frame_title
      assert_match %r{\Ahttp://localhost:\d+/}, session.driver.frame_url
    end
  end
end
