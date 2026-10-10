# frozen_string_literal: true

require_relative "../test_helper"

# go_back / go_forward must behave like the browser's back button: an entry
# created by history.pushState is restored in the SAME document (JS state
# kept, `popstate` fired), and only an entry from another document loads a
# page. Lightpanda's Page.navigateToHistoryEntry reloads even a pushState
# entry, which wiped SPA/Stimulus state and never fired `popstate` — so a
# "browser back button" system test could only fail there.
describe "Driver#go_back / #go_forward" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  # Lightpanda restores a pushState entry in place only when it differs from
  # the current URL by its fragment (`URL.eqlDocument`), so that is the shape
  # pinned here — the step-by-step wizards that keep their state in the hash.
  describe "between pushState entries that differ by fragment" do
    before do
      session.visit("/lightpanda/history")
      session.execute_script(<<~JS)
        window.__marker = "kept";
        window.__pops = [];
        addEventListener("popstate", (e) => __pops.push([location.hash, e.state]));
        history.pushState("a", "", "#a");
        history.pushState("b", "", "#b");
      JS
    end

    it "goes back in the same document and fires popstate" do
      session.go_back

      assert session.current_url.end_with?("/lightpanda/history#a"), session.current_url
      assert_equal "kept", session.evaluate_script("window.__marker")
      assert_equal [["#a", "a"]], session.evaluate_script("window.__pops")
    end

    it "goes forward in the same document and fires popstate" do
      session.go_back
      session.go_forward

      assert_equal "b", URI(session.current_url).fragment
      assert_equal "kept", session.evaluate_script("window.__marker")
      assert_equal [["#a", "a"], ["#b", "b"]], session.evaluate_script("window.__pops")
    end

    # Staying in the document must not cost a navigation wait.
    it "returns quickly" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      session.go_back
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 0.2, "same-document go_back took #{(elapsed * 1000).round} ms"
    end
  end

  # Entries whose paths differ (Turbo Drive visits, router pushState): through
  # 1.0.0 Lightpanda's history traversal treated any non-fragment difference as
  # cross-document and reloaded from the server (#3726). Our upstream #3763
  # (build 10239) traverses within the document by entry. Ungate when the
  # floor passes 10239.
  it "keeps the document between pushState entries with different paths" do
    browser = session.driver.browser
    unless browser.nightly_build && browser.nightly_build >= Gem::Version.new("10239")
      skip "needs nightly >= 10239 (lightpanda-io/browser#3763); running #{browser.version}"
    end

    session.visit("/lightpanda/history")
    session.execute_script(<<~JS)
      window.__marker = "kept";
      history.pushState({}, "", "/lightpanda/history/a");
      history.pushState({}, "", "/lightpanda/history/b");
    JS

    session.go_back

    session.assert_current_path("/lightpanda/history/a", wait: 0)
    assert_equal "kept", session.evaluate_script("window.__marker")
  end

  # The other half: an entry from another document is a real navigation, and
  # the call must not return until that page is there (the server sleeps
  # TestApp::NAV_WAIT_DELAY, well past wait_for_idle's sniff window).
  describe "between documents" do
    it "goes back to the previous page and waits for it" do
      session.visit("/lightpanda/nav_wait/slow")
      session.visit("/lightpanda/simple")

      session.go_back

      session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
      assert_equal "Slow Page", session.title
    end

    it "goes forward to the next page and waits for it" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/nav_wait/slow")
      session.go_back
      session.assert_current_path("/lightpanda/simple", wait: 0)

      session.go_forward

      session.assert_current_path("/lightpanda/nav_wait/slow", wait: 0)
      assert_equal "Slow Page", session.title
    end

    it "loads a fresh document when going back across a visit" do
      session.visit("/lightpanda/history")
      session.execute_script("window.__marker = 'stale'")
      session.visit("/lightpanda/simple")

      session.go_back

      session.assert_current_path("/lightpanda/history", wait: 0)
      assert_nil session.evaluate_script("window.__marker")
    end
  end
end
