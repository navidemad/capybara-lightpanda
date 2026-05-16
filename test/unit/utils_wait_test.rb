# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/utils/wait"

describe Capybara::Lightpanda::Utils::Wait do
  it "returns the block's truthy value when it succeeds before timeout" do
    assert_equal :done, Capybara::Lightpanda::Utils::Wait.until(timeout: 0.1) { :done }
  end

  it "polls until the block becomes truthy" do
    calls = 0
    result = Capybara::Lightpanda::Utils::Wait.until(timeout: 1, interval: 0.01) do
      calls += 1
      calls >= 3 ? "ok" : nil
    end
    assert_equal "ok", result
    assert_operator calls, :>=, 3
  end

  it "raises Capybara::Lightpanda::TimeoutError when the block never returns truthy" do
    assert_raises(Capybara::Lightpanda::TimeoutError) do
      Capybara::Lightpanda::Utils::Wait.until(timeout: 0.05, interval: 0.01) { false }
    end
  end

  it "uses the provided message in the timeout error" do
    error = assert_raises(Capybara::Lightpanda::TimeoutError) do
      Capybara::Lightpanda::Utils::Wait.until(timeout: 0.02, interval: 0.01, message: "boom") { nil }
    end
    assert_includes error.message, "boom"
  end

  it "defaults the timeout message to mention the elapsed budget" do
    error = assert_raises(Capybara::Lightpanda::TimeoutError) do
      Capybara::Lightpanda::Utils::Wait.until(timeout: 0.02, interval: 0.01) { nil }
    end
    assert_match(/timed out after 0\.02s/, error.message)
  end

  describe ":ignore" do
    it "swallows a single listed exception class" do
      attempts = 0
      result = Capybara::Lightpanda::Utils::Wait.until(timeout: 1, interval: 0.01, ignore: ArgumentError) do
        attempts += 1
        raise ArgumentError, "transient" if attempts < 3

        "settled"
      end
      assert_equal "settled", result
      assert_equal 3, attempts
    end

    it "swallows any class in an Array of listed exceptions" do
      attempts = 0
      result = Capybara::Lightpanda::Utils::Wait.until(
        timeout: 1,
        interval: 0.01,
        ignore: [ArgumentError, KeyError]
      ) do
        attempts += 1
        raise KeyError, "missing" if attempts == 1
        raise ArgumentError, "bad" if attempts == 2

        :ready
      end
      assert_equal :ready, result
    end

    it "does not swallow exceptions outside the ignore list" do
      assert_raises(RuntimeError) do
        Capybara::Lightpanda::Utils::Wait.until(timeout: 1, interval: 0.01, ignore: ArgumentError) do
          raise "not ignored"
        end
      end
    end

    it "appends the last ignored exception's message to the timeout error" do
      error = assert_raises(Capybara::Lightpanda::TimeoutError) do
        Capybara::Lightpanda::Utils::Wait.until(timeout: 0.02, interval: 0.01, ignore: ArgumentError) do
          raise ArgumentError, "still flaky"
        end
      end
      assert_includes error.message, "still flaky"
    end
  end
end
