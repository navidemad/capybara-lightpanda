# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/utils/attempt"

# Attempt is the single home for transient-error retry loops (Browser's
# NoExecutionContextError recovery, WebSocket's connect retry). These tests pin
# the contract callers rely on: only listed errors are retried, attempts are
# bounded, and anything else propagates immediately.
describe Capybara::Lightpanda::Utils::Attempt do
  let(:transient_error) { Class.new(StandardError) }
  let(:other_error) { Class.new(StandardError) }

  it "retries listed errors until the block succeeds" do
    calls = 0
    result = Capybara::Lightpanda::Utils::Attempt.with_retry(errors: transient_error, max: 3, wait: 0) do
      calls += 1
      raise transient_error if calls < 3

      :ok
    end

    assert_equal :ok, result
    assert_equal 3, calls
  end

  it "gives up after max attempts and re-raises so failures stay loud" do
    calls = 0
    assert_raises(transient_error) do
      Capybara::Lightpanda::Utils::Attempt.with_retry(errors: transient_error, max: 3, wait: 0) do
        calls += 1
        raise transient_error
      end
    end

    assert_equal 3, calls
  end

  it "does not swallow errors outside the list — a retry loop must not mask real bugs" do
    calls = 0
    assert_raises(other_error) do
      Capybara::Lightpanda::Utils::Attempt.with_retry(errors: transient_error, max: 3, wait: 0) do
        calls += 1
        raise other_error
      end
    end

    assert_equal 1, calls
  end

  it "accepts an array of error classes" do
    calls = 0
    result = Capybara::Lightpanda::Utils::Attempt.with_retry(errors: [transient_error, other_error], max: 3,
                                                             wait: 0) do
      calls += 1
      raise transient_error if calls == 1
      raise other_error if calls == 2

      :ok
    end

    assert_equal :ok, result
    assert_equal 3, calls
  end
end
