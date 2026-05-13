# frozen_string_literal: true

require_relative "../test_helper"

describe Capybara::Lightpanda::Keyboard do
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
