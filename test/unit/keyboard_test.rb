# frozen_string_literal: true

require_relative "../test_helper"

# Captures Input.* CDP params so tests can assert the exact key events the
# browser would receive.
class FakeKeyboardBrowser
  attr_reader :events

  def initialize
    @events = []
  end

  def page_command(method, **params)
    @events << [method, params]
    {}
  end
end

describe Capybara::Lightpanda::Keyboard do
  let(:browser) { FakeKeyboardBrowser.new }
  let(:keyboard) { Capybara::Lightpanda::Keyboard.new(browser) }

  def key_events
    browser.events.filter_map { |method, params| params if method == "Input.dispatchKeyEvent" }
  end

  describe "#type" do
    # MODIFIERS has always advertised :ctrl (Capybara's send_keys spelling),
    # but KEYS lacked the entry — send_keys(:ctrl, "a") crashed with
    # NoMethodError on nil instead of typing. The alias must stay paired,
    # like :command/:meta.
    it "accepts :ctrl as a modifier (held form)" do
      keyboard.type(:ctrl, "a")

      down = key_events.first
      assert_equal "keyDown", down[:type]
      assert_equal "Control", down[:key]

      modified = key_events.find { |e| e[:modifiers] }
      assert_equal 2, modified[:modifiers]

      up = key_events.last
      assert_equal %w[keyUp Control], [up[:type], up[:key]]
    end

    it "accepts :ctrl inside an array group" do
      keyboard.type([:ctrl, "a"])

      assert(key_events.any? { |e| e[:key] == "Control" && e[:type] == "keyDown" })
      assert(key_events.any? { |e| e[:modifiers] == 2 })
      assert_equal %w[keyUp Control], key_events.last.values_at(:type, :key)
    end

    it "applies shift mapping to held-modifier chars" do
      keyboard.type(:shift, "1")

      modified = key_events.find { |e| e[:modifiers] && e[:type] == "keyDown" }
      assert_equal "!", modified[:key]
      assert_equal "1", modified[:unmodifiedText]
    end

    it "raises ArgumentError (not NoMethodError) for an unknown key symbol" do
      error = assert_raises(ArgumentError) { keyboard.type(:no_such_key) }
      assert_includes error.message, ":no_such_key"
    end

    it "releases array-grouped modifiers before the next argument — they don't leak" do
      keyboard.type([:shift, "a"], "b")

      # "b" arrives after the Shift keyUp, as plain insertText.
      shift_up_index = browser.events.index do |method, params|
        method == "Input.dispatchKeyEvent" && params[:type] == "keyUp" && params[:key] == "Shift"
      end
      insert_b_index = browser.events.index do |method, params|
        method == "Input.insertText" && params[:text] == "b"
      end
      assert shift_up_index < insert_b_index, "Shift release must precede the unmodified 'b'"
    end
  end

  describe ".shifted" do
    it "maps digits to their US-keyboard shifted symbols" do
      assert_equal "!", Capybara::Lightpanda::Keyboard.shifted("1")
      assert_equal "@", Capybara::Lightpanda::Keyboard.shifted("2")
      assert_equal ")", Capybara::Lightpanda::Keyboard.shifted("0")
    end

    it "maps punctuation to shifted symbols" do
      assert_equal "_", Capybara::Lightpanda::Keyboard.shifted("-")
      assert_equal "+", Capybara::Lightpanda::Keyboard.shifted("=")
      assert_equal "?", Capybara::Lightpanda::Keyboard.shifted("/")
      assert_equal "~", Capybara::Lightpanda::Keyboard.shifted("`")
    end

    it "uppercases letters via String#upcase fallback" do
      assert_equal "A", Capybara::Lightpanda::Keyboard.shifted("a")
      assert_equal "Z", Capybara::Lightpanda::Keyboard.shifted("z")
    end

    it "passes characters with no shifted variant through unchanged" do
      assert_equal " ", Capybara::Lightpanda::Keyboard.shifted(" ")
    end
  end
end
