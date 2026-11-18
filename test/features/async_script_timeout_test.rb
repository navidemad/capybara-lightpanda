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

  # Selenium and Cuprite give the callback the session's wait. Until 0.20 this
  # driver gave it its own 15 s command timeout and returned the late value,
  # so a helper written for Chrome hung where it should have failed. Pinned so
  # the budget can't silently drift back.
  it "gives the callback Capybara's wait, not the driver timeout" do
    session.visit("/lightpanda/simple")
    assert_operator session.driver.browser.options.timeout, :>, 2

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Capybara::Lightpanda::ScriptTimeoutError) do
      session.using_wait_time(0.5) do
        session.evaluate_async_script("setTimeout(arguments[0], 1500, 'late')")
      end
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.4
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
