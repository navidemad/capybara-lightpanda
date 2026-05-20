# frozen_string_literal: true

require_relative "../test_helper"

# The live-browser registry guarantees that browsers abandoned at process exit
# (Capybara keeps the shared browser alive across a suite and nothing calls
# #quit) get their CDP WebSocket closed BEFORE the Process is SIGTERMed.
# Lightpanda swallows a single SIGTERM while a CDP connection is live, so without
# this the only thing reaping the binary is the 3s SIGKILL escalation (and,
# before that escalation existed, a hard hang). These tests pin the registry
# contract the at_exit handler relies on.
class BrowserTeardownTest < Minitest::Test
  Browser = Capybara::Lightpanda::Browser

  class FakeBrowser
    attr_reader :quits

    def initialize
      @quits = 0
    end

    def quit
      @quits += 1
    end

    def quit?
      @quits.positive?
    end
  end

  class BoomBrowser
    def quit
      raise "kaboom"
    end
  end

  def teardown
    # Drain anything registered here so the real at_exit (installed on the first
    # #track) finds an empty registry when the test process itself exits.
    Browser.instance_variable_get(:@live).dup.each { |b| Browser.untrack(b) }
  end

  def test_quit_all_quits_each_tracked_browser
    a = FakeBrowser.new
    b = FakeBrowser.new
    Browser.track(a)
    Browser.track(b)

    Browser.quit_all

    assert a.quit?, "quit_all must #quit the first tracked browser"
    assert b.quit?, "quit_all must #quit the second tracked browser"
  end

  def test_track_is_idempotent_so_quit_runs_once_per_browser
    a = FakeBrowser.new
    Browser.track(a)
    Browser.track(a)

    Browser.quit_all

    assert_equal 1, a.quits, "a browser tracked twice must still be quit once"
  end

  def test_untrack_excludes_a_browser_from_quit_all
    a = FakeBrowser.new
    Browser.track(a)
    Browser.untrack(a)

    Browser.quit_all

    refute a.quit?, "an untracked (already #quit) browser must not be quit again"
  end

  def test_quit_all_continues_after_a_raising_quit
    Browser.track(BoomBrowser.new)
    ok = FakeBrowser.new
    Browser.track(ok)

    Browser.quit_all # must not raise

    assert ok.quit?, "a raising #quit must not strand later browsers"
  end

  def test_first_track_installs_the_at_exit_handler
    Browser.track(FakeBrowser.new)

    assert Browser.instance_variable_get(:@at_exit_installed),
           "the first tracked browser must install the at_exit teardown hook"
  end
end
