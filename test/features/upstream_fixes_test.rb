# frozen_string_literal: true

require_relative "../test_helper"

# Upstream fixes the gem's floor (1.0.2 = 10965) guarantees and nothing else
# defends: lightpanda-io/browser#3755, #3757, #3759, #3849, #3874. Each one
# pins the behavior users get, so a floor regression fails here first.
describe "Lightpanda fixes in the floor" do
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  def page_error_messages(count)
    Capybara::Lightpanda::Utils::Wait.until(timeout: 2) { browser.page_errors.size >= count }
    browser.page_errors.map { |e| e[:message] }
  end

  describe "page_errors from callbacks (#3755, 10049)" do
    before { session.visit("/lightpanda/callback_errors") }

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

  describe "closed popover (#3757, 10052)" do
    before { session.visit("/lightpanda/callback_errors") }

    # Below 10052 a never-shown popover read as visible, so Capybara matched
    # its content and has_no_text? failed on a page Chrome shows clean.
    it "hides a popover until it is shown" do
      assert session.has_no_text?("popover secret")
      assert session.has_no_css?("#pop")

      session.find(:css, "#show-pop").click
      assert session.has_css?("#pop", text: "popover secret")
    end
  end

  describe "page_errors from a microtask (#3849, 10310)" do
    before { session.visit("/lightpanda/callback_errors") }

    # Below 10310 V8's microtask checkpoint swallowed the exception, so a
    # promise-chain handler (Turbo, Stimulus values callbacks) dying there
    # left page_errors empty.
    it "captures an exception thrown from queueMicrotask" do
      session.find(:css, "#microtask").click
      assert_includes page_error_messages(1).join("\n"), "microtask boom"
    end
  end

  describe "Ctrl+A selects a field's text (#3874, 10366)" do
    before { session.visit("/lightpanda/callback_errors") }

    # The usual "clear the field, then type" idiom. Below 10366 Ctrl+A did
    # nothing, so the field ended as "hello worlnew" instead of "new".
    it "replaces the whole value" do
      field = session.find(:css, "#prefilled")
      field.send_keys([:control, "a"], :backspace, "new")
      assert_equal "new", field.value
    end
  end

  describe "send_keys inside an iframe (#3759, 10057)" do
    before { session.visit("/lightpanda/with_input_frame") }

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
