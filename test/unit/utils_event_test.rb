# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/utils/event"

describe Capybara::Lightpanda::Utils::Event do
  let(:event) { Capybara::Lightpanda::Utils::Event.new }

  it "starts unset with iteration 0" do
    assert_equal false, event.set?
    assert_equal 0, event.iteration
  end

  it "behaves like Concurrent::Event for set/wait" do
    event.set
    assert_equal true, event.set?
    assert_equal true, event.wait(0)
  end

  describe "#reset" do
    it "increments iteration counter on every reset" do
      before1 = event.iteration
      event.reset
      assert_equal before1 + 1, event.iteration
      event.reset
      assert_equal before1 + 2, event.iteration
    end

    it "increments iteration even when already unset" do
      event.set
      assert_equal 0, event.iteration
      event.reset
      assert_equal 1, event.iteration
      assert_equal false, event.set?
    end

    it "returns the new iteration value" do
      assert_equal 1, event.reset
      assert_equal 2, event.reset
    end
  end

  it "lets callers detect a set→reset→set race via iteration" do
    before = event.iteration
    event.set
    event.reset
    event.set
    after = event.iteration
    assert_operator after, :>, before
  end
end
