# frozen_string_literal: true

require_relative "../test_helper"

# The `window_size` option, applied via Browser#set_viewport ->
# Emulation.setDeviceMetricsOverride (upstream PR #2664).
#
# Why this matters, and what it deliberately does NOT claim: Lightpanda has no
# rendering engine, so this is a *JS-visible* viewport only. It moves
# window.innerWidth/innerHeight and the viewport `matchMedia` / `@media`
# evaluate against — enough for responsive branches to resolve at the requested
# size — while getBoundingClientRect stays synthetic and nothing reflows. The
# assertions below are therefore all about which CSS branch wins, never about
# geometry.
describe "Capybara::Lightpanda viewport" do
  Capybara.register_driver(:lightpanda_mobile) do |app|
    Capybara::Lightpanda::Driver.new(
      app,
      timeout: 10,
      window_size: [375, 667],
      browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    )
  end

  # Owns its own Lightpanda process, so it is memoized for the whole file and
  # torn down at exit — spawning a browser per example would dominate runtime.
  def self.mobile_session
    @mobile_session ||= Capybara::Session.new(:lightpanda_mobile, TestApp)
  end

  Minitest.after_run { @mobile_session&.driver&.quit }

  describe "default viewport" do
    let(:session) { TestSessions::Lightpanda }

    before { session.visit("/lightpanda/viewport") }
    after { session.reset_session! }

    # Mirrors Lightpanda's own Viewport.default. If this ever changes, wiring
    # window_size up has silently resized every existing suite.
    it "reports Lightpanda's native 1920x1080 to JS" do
      assert_equal 1920, session.evaluate_script("window.innerWidth")
      assert_equal 1080, session.evaluate_script("window.innerHeight")
    end

    it "resolves the desktop branch of a @media breakpoint" do
      refute session.evaluate_script("window.matchMedia('(max-width: 500px)').matches")

      assert session.find("#desktop-cta", visible: :all).visible?
      refute session.find("#mobile-cta", visible: :all).visible?
    end

    # Upstream #3378 (build 9207): Emulation.setDeviceMetricsOverride now
    # re-evaluates every MediaQueryList and fires `change` where `matches`
    # flipped. Before it, a mid-test resize moved innerWidth and what
    # matchMedia reports but no listener ever ran — responsive JS (nav
    # collapse, chart re-layout) silently kept its desktop state.
    #
    # What #3378 does NOT change, and this example deliberately does not
    # claim: the `@media` *cascade* of the already-loaded document. Lightpanda
    # fixes it at parse time (see Driver#resize_window_to's comment), so after
    # the resize the JS side says mobile while the CSS branch is still
    # desktop; only a navigation re-resolves it. The last two assertions pin
    # that documented resize-then-visit shape so the split can't drift
    # unnoticed (verified 2026-09-06 on main 9213).
    #
    # Build-gated rather than floor-guaranteed: the floor is pinned to release
    # 0.4.0 (= 9058) and cannot pass 9207 until upstream tags a newer release.
    # The skip keeps the pin honest on both channels instead of encoding a
    # behavior the floor does not promise.
    it "fires matchMedia change listeners when a resize crosses the breakpoint" do
      build = session.driver.browser.nightly_build
      skip "upstream #3378 (build 9207) is not in this Lightpanda" unless build && build >= Gem::Version.new("9207")

      assert_equal "", session.find("#mq-log").text

      session.current_window.resize_to(375, 667)

      assert_equal "change:true;", session.find("#mq-log").text
      assert session.evaluate_script("window.matchMedia('(max-width: 500px)').matches")
      # Cascade still desktop until the next navigation — documented, not a bug here.
      assert_equal "desktop-cta", session.find_link("Get started")[:id]

      session.visit("/lightpanda/viewport")

      assert_equal "mobile-cta", session.find_link("Get started")[:id]
    end
  end

  describe "explicit window_size" do
    let(:session) { self.class.mobile_session }

    before { session.visit("/lightpanda/viewport") }
    after { session.reset_session! }

    it "applies the configured size to window.innerWidth/innerHeight" do
      assert_equal 375, session.evaluate_script("window.innerWidth")
      assert_equal 667, session.evaluate_script("window.innerHeight")
    end

    # The payoff: a @media-gated element that is unreachable at 1920x1080
    # becomes the visible one, so Capybara acts on the mobile CTA.
    it "flips which @media branch is visible" do
      assert session.evaluate_script("window.matchMedia('(max-width: 500px)').matches")

      assert session.find("#mobile-cta", visible: :all).visible?
      refute session.find("#desktop-cta", visible: :all).visible?
    end

    # Both CTAs share link text, so an unapplied viewport raises Ambiguous here
    # instead of quietly matching the wrong one.
    it "makes the mobile CTA the unambiguous match by text" do
      assert_equal "mobile-cta", session.find_link("Get started")[:id]
    end

    # Driver#reset! disposes the BrowserContext; set_viewport re-runs on the
    # create_page that follows, so the override must survive a session reset.
    it "survives reset_session!" do
      session.reset_session!
      session.visit("/lightpanda/viewport")

      assert_equal 375, session.evaluate_script("window.innerWidth")
      assert_equal "mobile-cta", session.find_link("Get started")[:id]
    end
  end

  # A bad window_size must fail before Browser#initialize spawns a process,
  # otherwise the raise orphans a Lightpanda. Validation therefore lives in
  # Options#initialize (unit-tested there); this asserts the boundary holds
  # through the Driver, and that nothing was left running.
  describe "invalid window_size" do
    it "raises via the driver without spawning a browser" do
      driver = Capybara::Lightpanda::Driver.new(
        TestApp,
        timeout: 10,
        window_size: [0, 768],
        browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
      )

      error = assert_raises(ArgumentError) { driver.browser }

      assert_match(/window_size/, error.message)
      assert_nil driver.instance_variable_get(:@browser)
    end
  end
end
