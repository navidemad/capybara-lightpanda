# frozen_string_literal: true

require_relative "../test_helper"

describe "Async script deadlines" do
  let(:session) { Capybara::Session.new(:lightpanda, TestApp) }

  after { session.driver.quit }

  it "lets a callback outlive the normal CDP command timeout" do
    session.visit("/lightpanda/simple")
    session.driver.browser.options.timeout = 0.25
    value = session.using_wait_time(2) do
      session.evaluate_async_script("setTimeout(arguments[0], 450, 'saved')")
    end
    assert_equal "saved", value
  end

  it "reports a connection lost while waiting for a callback" do
    session.visit("/lightpanda/simple")
    browser = session.driver.browser
    started = Queue.new
    browser.on("Runtime.consoleAPICalled") do |event|
      started << true if event.dig("args", 0, "value") == "waiting for callback"
    end
    pending = Thread.new do
      session.evaluate_async_script("console.log('waiting for callback')")
    rescue Capybara::Lightpanda::Error => e
      e
    end

    assert started.pop(timeout: 2), "the async command must be in flight"
    browser.client.close
    assert_instance_of Capybara::Lightpanda::DeadBrowserError, pending.value
  ensure
    pending&.join
  end
end
