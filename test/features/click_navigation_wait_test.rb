# frozen_string_literal: true

require_relative "../test_helper"

# A click that starts a full navigation must not return until the new
# document is there. Lightpanda emits Page.frameStartedLoading ~5 ms after
# the click but only swaps the execution context when the response lands, so
# a sniff that watched only Runtime.executionContextsCleared returned on the
# OLD page whenever the server took longer than the sniff window — and
# `current_url` / `assert_current_path(wait: 0)` read the page being left.
# Cuprite/Ferrum wait here; suites migrating from them rely on it.
#
# The /lightpanda/nav_wait/* routes sleep TestApp::NAV_WAIT_DELAY (0.3 s),
# well past the sniff window.
describe "Node#click waits for the navigation it starts" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/nav_wait") }
  after { session.reset_session! }

  it "waits for a slow link target" do
    session.find(:css, "#slow-link").click

    session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
    assert_equal "Slow Page", session.title
  end

  it "waits through a slow server-side redirect" do
    session.find(:css, "#redirect-link").click

    session.assert_current_path("/lightpanda/other", wait: 0)
  end

  it "waits for a target=_top link" do
    session.find(:css, "#top-link").click

    session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
  end

  it "waits for a window.location assignment from a click handler" do
    session.find(:css, "#js-nav").click

    session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
  end

  # The other half of the contract: waiting must be gated on a navigation
  # actually starting, or every click on a plain button pays for it.
  it "keeps an inert click fast" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.find(:css, "#inert").click
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.1, "inert click took #{(elapsed * 1000).round} ms"
  end

  # Same-document navigations never replace the execution context; if they
  # counted as "navigation started" the click would sit out the full timeout.
  it "does not block on a pushState click" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.find(:css, "#push").click
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    session.assert_current_path("/lightpanda/nav_wait/pushed", wait: 0)
    assert_operator elapsed, :<, 0.1, "pushState click took #{(elapsed * 1000).round} ms"
  end

  it "does not block on an in-page anchor click" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.find(:css, "#anchor").click
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_includes session.current_url, "#section"
    assert_operator elapsed, :<, 0.1, "anchor click took #{(elapsed * 1000).round} ms"
  end

  # A failed navigation emits neither a new context nor
  # Page.frameStoppedLoading — only Network.loadingFailed. Missing it would
  # hang every such click for the full driver timeout (10 s here).
  it "does not block on a navigation whose request fails" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.find(:css, "#refused").click
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    session.assert_current_path("/lightpanda/nav_wait", wait: 0)
    assert_operator elapsed, :<, 1, "failed-navigation click took #{(elapsed * 1000).round} ms"
  end
end
