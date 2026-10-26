# frozen_string_literal: true

require_relative "../test_helper"

describe "Node#trigger waits for click navigation" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/nav_wait") }
  after { session.reset_session! }

  # The click handler navigates to a response delayed beyond the driver's
  # sniff window. Assertions must not retry: callers need the destination
  # document immediately when trigger returns, just as they do with click.
  [:click, "click"].each do |event|
    it "waits for a slow click-handler navigation with #{event.inspect}" do
      session.find(:css, "#js-nav").trigger(event)

      session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
      assert_equal "Slow Page", session.title
    end
  end

  it "keeps an inert triggered click fast" do
    node = session.find(:css, "#inert")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    node.trigger(:click)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.1, "inert triggered click took #{(elapsed * 1000).round} ms"
  end

  it "does not wait for a new document after a pushState click" do
    node = session.find(:css, "#push")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    node.trigger(:click)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    session.assert_current_path("/lightpanda/nav_wait/pushed", wait: 0)
    assert_operator elapsed, :<, 0.1, "pushState triggered click took #{(elapsed * 1000).round} ms"
  end
end
