# frozen_string_literal: true

require_relative "../test_helper"

# Upstream fixes that are in the nightly but above the gem's floor (1.0.0 =
# 9994 still has the bugs): lightpanda-io/browser#3755, #3757, #3759. Each test
# skips below the build that fixed it, so it runs on the rolling nightly and
# pins the behavior the gem's users get there. Drop the gates when the floor
# moves past 10057 (the next tagged release).
describe "Lightpanda fixes above the floor" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  def require_build(build, why)
    current = browser.nightly_build
    return if current && current >= Gem::Version.new(build)

    skip "needs nightly >= #{build} (#{why}); running #{browser.version}"
  end

  def page_error_messages(count)
    Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.page_errors.size >= count }
    browser.page_errors.map { |e| e[:message] }
  end

  describe "page_errors from callbacks (#3755, build 10049)" do
    before do
      session.visit("/lightpanda/callback_errors")
      require_build(10_049, "#3755")
    end

    # Below 10049 these exceptions only bumped an internal counter, so a
    # handler dying in a setTimeout (Stimulus debounce, Turbo callbacks) left
    # page_errors empty and the failure surfaced as an unrelated ElementNotFound.
    %w[timer raf inline].each do |id|
      it "captures an exception thrown from #{id}" do
        session.find(:css, "##{id}").click
        assert_includes page_error_messages(1).join("\n"), "#{id} boom"
      end
    end
  end

  describe "closed popover (#3757, build 10052)" do
    before do
      session.visit("/lightpanda/callback_errors")
      require_build(10_052, "#3757")
    end

    # Below 10052 a never-shown popover read as visible, so Capybara matched
    # its content and has_no_text? failed on a page Chrome shows clean.
    it "hides a popover until it is shown" do
      assert session.has_no_text?("popover secret")
      assert session.has_no_css?("#pop")

      session.find(:css, "#show-pop").click
      assert session.has_css?("#pop", text: "popover secret")
    end
  end

  describe "send_keys inside an iframe (#3759, build 10057)" do
    before do
      session.visit("/lightpanda/with_input_frame")
      require_build(10_057, "#3759")
    end

    # Below 10057 Input.insertText targeted the top frame's activeElement,
    # which never becomes the <iframe>: the keys vanished without an error.
    it "types into the focused field of the frame" do
      session.within_frame("input-frame") do
        field = session.find(:css, "#frame-input")
        field.send_keys("hello")
        assert_equal "hello", field.value
      end
    end
  end
end
