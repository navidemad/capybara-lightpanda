# frozen_string_literal: true

require_relative "../test_helper"

# Capybara's Window API against Lightpanda's single-window model.
#
# Capybara's own `:windows` battery stays in `capybara_skip` because it needs
# several independent windows, which Lightpanda can't serve (one target per CDP
# connection, upstream #1962). What IS reachable is the slice real Rails suites
# lean on: resizing to exercise a responsive breakpoint. Before this,
# `page.current_window.resize_to(...)` raised NotSupportedByDriverError from
# Capybara::Driver::Base, so a suite had to pin one viewport for the whole run
# via the `window_size` driver option. viewport_test.rb covers that static
# path; this covers changing it at runtime.
#
# The contract has a sharp edge that the tests below pin deliberately: a resize
# updates `matchMedia` at once but does not re-resolve `@media` for the
# document already on screen. Resize, then visit.
describe "Capybara::Lightpanda window API" do
  let(:session) { TestSessions::Lightpanda }
  let(:driver) { session.driver }

  before { session.visit("/lightpanda/viewport") }
  after { session.reset_session! }

  describe "handles" do
    it "reports exactly one window, keyed by the CDP target id" do
      assert_equal [driver.current_window_handle], driver.window_handles
      assert_equal driver.browser.target_id, driver.current_window_handle
    end

    it "treats switching to the current window as a no-op" do
      # Capybara calls this when restoring the original window after a
      # `within_window`-style block; it must not raise for the only window.
      driver.switch_to_window(driver.current_window_handle)
    end

    it "rejects a handle that is not the current window" do
      error = assert_raises(Capybara::Lightpanda::NoSuchPageError) do
        driver.switch_to_window("not-a-real-target")
      end
      assert_match(/single window/, error.message)
    end

    # Capybara::Window#current? rescues this class rather than calling a
    # predicate, so it has to be a class and not a raised instance.
    it "exposes no_such_window_error as a rescuable class" do
      assert_equal Capybara::Lightpanda::NoSuchPageError, driver.no_such_window_error
      assert_operator driver.no_such_window_error, :<, Exception
    end
  end

  describe "resizing" do
    it "updates innerWidth and what matchMedia reports, immediately" do
      session.current_window.resize_to(375, 667)

      assert_equal 375, session.evaluate_script("window.innerWidth")
      assert session.evaluate_script('window.matchMedia("(max-width: 500px)").matches')

      session.current_window.resize_to(1440, 900)

      assert_equal 1440, session.evaluate_script("window.innerWidth")
      refute session.evaluate_script('window.matchMedia("(max-width: 500px)").matches')
    end

    # The payoff: both breakpoints exercised in one example, which the static
    # `window_size` driver option can't do. The re-visit is load-bearing, not
    # incidental — see the next test.
    it "flips which @media branch renders, when the page is visited after the resize" do
      session.current_window.resize_to(375, 667)
      session.visit("/lightpanda/viewport")
      assert_equal "mobile-cta", session.find_link("Get started")[:id]

      session.current_window.resize_to(1440, 900)
      session.visit("/lightpanda/viewport")
      assert_equal "desktop-cta", session.find_link("Get started")[:id]
    end

    # Pins the upstream limitation so we notice if it ever gets fixed: the
    # cascade is resolved when the document is parsed and a metrics change
    # doesn't invalidate it, so matchMedia and the rendered branch disagree
    # until the next navigation. If this test starts failing, Lightpanda
    # learned to re-cascade — drop it and fold the assertion into the test
    # above (and simplify Driver's "-- Window Support --" comment).
    it "does NOT re-resolve @media for the document already on screen" do
      assert_equal "desktop-cta", session.find_link("Get started")[:id]

      session.current_window.resize_to(375, 667)

      assert session.evaluate_script('window.matchMedia("(max-width: 500px)").matches'),
             "matchMedia should be live even though the cascade is not"
      assert_equal "desktop-cta", session.find_link("Get started")[:id],
                   "cascade unexpectedly re-resolved — upstream may have fixed this"
    end

    # Window#resize_to polls #size until two consecutive reads agree, and
    # raises Capybara::WindowError if they never do — so size must reflect the
    # new viewport immediately, not eventually.
    it "reports the new size straight back through Capybara" do
      session.current_window.resize_to(800, 600)

      assert_equal [800, 600], session.current_window.size
      assert_equal [800, 600], driver.window_size(driver.current_window_handle)
    end

    it "reads the viewport from the page rather than echoing the last write" do
      session.current_window.resize_to(1024, 768)
      # Move it behind the driver's back; #size must notice.
      driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 640, height: 480)

      assert_equal [640, 480], session.current_window.size
    end

    it "restores the configured size on maximize and fullscreen" do
      configured = driver.browser.options.window_size

      session.current_window.resize_to(320, 480)
      driver.maximize_window(driver.current_window_handle)
      assert_equal configured, driver.window_size(driver.current_window_handle)

      session.current_window.resize_to(320, 480)
      driver.fullscreen_window(driver.current_window_handle)
      assert_equal configured, driver.window_size(driver.current_window_handle)
    end

    it "refuses to resize a window that is not the current one" do
      assert_raises(Capybara::Lightpanda::NoSuchPageError) do
        driver.resize_window_to("not-a-real-target", 800, 600)
      end
    end
  end

  describe "unsupported multi-window operations" do
    # These raise rather than pretending, and the message has to say what to do
    # instead — a bare NotSupportedByDriverError sends people to the issue tracker.
    it "explains why a second window cannot be opened" do
      error = assert_raises(Capybara::NotSupportedByDriverError) { driver.open_new_window }
      assert_match(/single target|1962/, error.message)
      assert_match(/Capybara session/, error.message)
    end

    it "explains why the only window cannot be closed" do
      error = assert_raises(Capybara::NotSupportedByDriverError) do
        driver.close_window(driver.current_window_handle)
      end
      assert_match(/reset!/, error.message)
    end
  end
end
