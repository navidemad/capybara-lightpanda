# frozen_string_literal: true

require_relative "../test_helper"

# Comprehensive test suite for capybara-lightpanda.
#
# Tests use CSS selectors and direct DOM APIs to avoid depending on
# Capybara's complex XPath label matchers (which require a full XPath engine).
#
# Test ordering note: Network and cookie tests come early because Lightpanda's
# beta browser can become unresponsive after many rapid CDP interactions.
# Tests that are "heavier" (forms, dynamic content, clicks) come later.

describe Capybara::Lightpanda::Driver do
  let(:session) { TestSessions::Lightpanda }
  let(:driver) { session.driver }
  let(:browser) { driver.browser }

  after { session.reset_session! }

  # ───────────────────────────────────────────────
  # Driver setup & lifecycle
  # ───────────────────────────────────────────────

  describe "driver setup" do
    it "returns true for needs_server?" do
      assert_equal true, driver.needs_server?
    end

    it "returns true for wait?" do
      assert_equal true, driver.wait?
    end

    it "provides invalid_element_errors for Capybara retry logic" do
      # Exactly the errors the gem can raise — no MouseEventFailed/
      # CoordinatesNotFoundError equivalents exist: Lightpanda has no rendering
      # engine, clicks dispatch through JS, so no coordinate-based mouse path
      # can fail. Capybara retrying on an error we never raise would mask bugs.
      assert_equal [
        Capybara::Lightpanda::NodeNotFoundError,
        Capybara::Lightpanda::NoExecutionContextError,
        Capybara::Lightpanda::ObsoleteNode,
      ], driver.invalid_element_errors
    end

    it "exposes the browser object" do
      assert_kind_of Capybara::Lightpanda::Browser, driver.browser
    end

    it "lazily initializes @browser as nil" do
      fresh_driver = Capybara::Lightpanda::Driver.new(TestApp, driver.options)
      assert_nil fresh_driver.instance_variable_get(:@browser)
    end

    it "captures the Lightpanda version and nightly build after start" do
      assert_kind_of String, browser.version
      assert_match(/\d+\.\d+\.\d+/, browser.version)
      assert_kind_of Gem::Version, browser.nightly_build
      assert_operator browser.nightly_build, :>=, Capybara::Lightpanda::Process::MINIMUM_NIGHTLY_BUILD
    end
  end

  # ───────────────────────────────────────────────
  # Navigation
  # ───────────────────────────────────────────────

  describe "navigation" do
    it "visits a page and reads the title" do
      session.visit("/lightpanda/simple")
      assert_equal "Simple Page", session.title
    end

    it "reads the current URL" do
      session.visit("/lightpanda/simple")
      assert_match(%r{/lightpanda/simple$}, session.current_url)
    end

    it "reads the page body as HTML" do
      session.visit("/lightpanda/simple")
      assert_includes session.html, "Hello from Lightpanda"
      assert_includes session.html, "<h1>"
    end

    it "navigates back" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      assert_equal "Other Page", session.title
      session.go_back
      assert_equal "Simple Page", session.title
    end

    it "navigates forward" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      assert_equal "Simple Page", session.title
      session.go_forward
      assert_equal "Other Page", session.title
    end

    it "refreshes the page" do
      session.visit("/lightpanda/simple")
      assert_equal "Simple Page", session.title
      driver.refresh
      assert_equal "Simple Page", session.title
    end

    it "follows links via click" do
      session.visit("/lightpanda/simple")
      session.find(:css, "a[href='/lightpanda/other']").click
      session.assert_selector(:css, "#content", text: "This is the other page")
    end
  end

  # ───────────────────────────────────────────────
  # CDP client direct access
  # ───────────────────────────────────────────────

  describe "CDP client" do
    it "sends page-scoped commands via page_command" do
      session.visit("/lightpanda/simple")
      result = browser.page_command("Runtime.evaluate", expression: "1 + 2", returnByValue: true)
      assert_equal 3, result.dig("result", "value")
    end

    it "sends browser-scoped commands via command" do
      result = browser.command("Target.getTargets")
      assert result.key?("targetInfos"), "expected result to have key 'targetInfos', got #{result.keys.inspect}"
    end
  end

  # ───────────────────────────────────────────────
  # Escape hatches
  # ───────────────────────────────────────────────

  describe "with_lightpanda_browser" do
    it "yields the underlying Browser to the block" do
      yielded = nil
      driver.with_lightpanda_browser { |b| yielded = b }
      assert_same browser, yielded
    end

    it "returns the value of the block" do
      result = driver.with_lightpanda_browser { |b| b.options.timeout }
      assert_equal browser.options.timeout, result
    end

    it "raises ArgumentError when no block is given" do
      assert_raises(ArgumentError) { driver.with_lightpanda_browser }
    end
  end

  describe "Element#with_lightpanda_node" do
    it "yields the driver Node so callers can read remote_object_id" do
      session.visit("/lightpanda/simple")
      element = session.find(:css, "h1")
      yielded = nil
      element.with_lightpanda_node { |n| yielded = n }
      assert_kind_of Capybara::Lightpanda::Node, yielded
      assert_match(/\S/, yielded.remote_object_id) # non-empty string
    end

    it "raises ArgumentError when no block is given" do
      session.visit("/lightpanda/simple")
      assert_raises(ArgumentError) { session.find(:css, "h1").with_lightpanda_node }
    end
  end

  # ───────────────────────────────────────────────
  # Navigation response (status_code, response_headers)
  # ───────────────────────────────────────────────

  describe "navigation response" do
    it "exposes the status_code of the last document navigation" do
      session.visit("/lightpanda/simple")
      assert_equal 200, driver.status_code
    end

    it "exposes response_headers with case-insensitive lookup" do
      session.visit("/lightpanda/simple")
      headers = driver.response_headers
      # The point of the Headers wrapper: callers reach for canonical casing
      # ("Content-Type") even though CDP returns the header lowercased.
      assert_match(%r{\Atext/html}, headers["Content-Type"])
      assert_equal headers["Content-Type"], headers["content-type"]
    end

    it "clears the captured response on session reset so a fresh session reports nil" do
      session.visit("/lightpanda/simple")
      assert_equal 200, driver.status_code
      session.reset_session!
      assert_nil driver.status_code
      assert_empty driver.response_headers
    end

    it "updates status_code on each subsequent navigation" do
      session.visit("/lightpanda/simple")
      first = driver.status_code
      session.visit("/lightpanda/other")
      # Both should be 200 but assert separately to prove the second visit
      # actually re-triggered the responseReceived handler instead of
      # silently re-using the prior capture.
      assert_equal 200, first
      assert_equal 200, driver.status_code
    end
  end

  # ───────────────────────────────────────────────
  # Node#trigger
  # ───────────────────────────────────────────────

  describe "Node#trigger" do
    it "dispatches a focus event so listeners fire" do
      session.visit("/lightpanda/trigger_test")
      session.find(:css, "#focusable").trigger(:focus)
      session.assert_selector(:css, "#result", text: "focus-fired")
    end

    it "dispatches a SubmitEvent (not a plain Event) on form submit" do
      session.visit("/lightpanda/trigger_test")
      session.find(:css, "#submittable").trigger(:submit)
      session.assert_selector(:css, "#result", text: "submit-fired:SubmitEvent")
    end

    it "dispatches an arbitrary custom event by name" do
      session.visit("/lightpanda/trigger_test")
      session.find(:css, "#custom-target").trigger("lp:custom")
      session.assert_selector(:css, "#result", text: "custom-fired")
    end
  end

  # ───────────────────────────────────────────────
  # Selector error surfacing
  # ───────────────────────────────────────────────

  describe "invalid selectors" do
    it "raises InvalidSelector for malformed CSS at the document scope" do
      session.visit("/lightpanda/simple")
      assert_raises(Capybara::Lightpanda::InvalidSelector) do
        browser.find("css", "..[invalid")
      end
    end

    it "raises InvalidSelector for malformed CSS scoped to a node" do
      session.visit("/lightpanda/simple")
      body_id = browser.evaluate_with_ref("document.body")["objectId"]
      assert_raises(Capybara::Lightpanda::InvalidSelector) do
        browser.find_within(body_id, "css", "..[invalid")
      end
    end
  end

  # ───────────────────────────────────────────────
  # Network tracking
  # ───────────────────────────────────────────────

  describe "network" do
    it "tracks network requests when enabled" do
      session.visit("/lightpanda/simple")
      browser.network.enable
      session.visit("/lightpanda/other")
      traffic = browser.network.traffic
      refute_empty traffic
      assert traffic.first.key?(:url), "expected first traffic entry to have :url key"
      assert traffic.first.key?(:method), "expected first traffic entry to have :method key"
      browser.network.disable
    end

    it "clears traffic history" do
      session.visit("/lightpanda/simple")
      browser.network.enable
      session.visit("/lightpanda/other")
      refute_empty browser.network.traffic
      browser.network.clear
      assert_empty browser.network.traffic
      browser.network.disable
    end

    it "is idempotent for enable/disable" do
      browser.network.enable
      browser.network.enable
      browser.network.disable
      browser.network.disable
      pass
    end
  end

  # ───────────────────────────────────────────────
  # Cookies
  # ───────────────────────────────────────────────

  describe "cookies" do
    it "sets and reads cookies via server" do
      session.visit("/lightpanda/set_test_cookie")
      session.visit("/lightpanda/get_test_cookie")
      session.assert_selector(:css, "body", text: "cookie_value")
    end

    it "clears cookies via Network.clearBrowserCookies" do
      session.visit("/lightpanda/set_test_cookie")
      cookies = browser.cookies.all
      assert_equal(true, cookies.any? { |c| c.name == "lightpanda_test" })

      browser.cookies.clear
      cookies_after = browser.cookies.all
      assert_empty cookies_after
    end

    it "sets and gets cookies via CDP API" do
      session.visit("/lightpanda/simple")
      # Lightpanda requires domain for Network.setCookie
      host = URI.parse(session.current_url).host
      browser.cookies.set(name: "cdp_cookie", value: "cdp_value", domain: host)
      cookie = browser.cookies.get("cdp_cookie")
      refute_nil cookie
      assert_equal "cdp_value", cookie.value
    end

    it "deletes a specific cookie via CDP API" do
      session.visit("/lightpanda/simple")
      host = URI.parse(session.current_url).host
      browser.cookies.set(name: "to_delete", value: "bye", domain: host)
      refute_nil browser.cookies.get("to_delete")

      browser.cookies.remove(name: "to_delete", domain: host)
      assert_nil browser.cookies.get("to_delete")
    end

    it "preserves cookies through a redirect" do
      session.visit("/lightpanda/set_cookie_and_redirect")
      # The 302 response sets a cookie, then redirects to /get_test_cookie.
      # Verify the cookie exists in the browser's cookie jar.
      cookie = browser.cookies.get("redirect_test")
      refute_nil cookie, "Cookie set on 302 response not stored in browser"
      assert_equal "survived_redirect", cookie.value
    end

    it "sends redirect-set cookies on the follow-up request" do
      session.visit("/lightpanda/set_cookie_and_redirect")
      body = session.evaluate_script("document.body.textContent").strip
      assert_includes body, "survived_redirect"
    end

    it "sends SameSite=Strict cookies on same-origin navigation" do
      session.visit("/lightpanda/set_samesite_cookie")
      session.visit("/lightpanda/check_cookies")
      session.assert_selector(:css, "body", text: "ss_strict=strict_val")
    end
  end

  # ───────────────────────────────────────────────
  # Reset
  # ───────────────────────────────────────────────

  describe "reset" do
    it "resets the session to about:blank" do
      session.visit("/lightpanda/simple")
      assert_equal "Simple Page", session.title
      driver.reset!
      assert_match(/about:blank/, browser.current_url)
    end

    it "survives multiple resets" do
      session.visit("/lightpanda/simple")
      3.times { driver.reset! }
      session.visit("/lightpanda/simple")
      assert_equal "Simple Page", session.title
    end
  end

  # ───────────────────────────────────────────────
  # XPath finding across page lifecycle
  # ───────────────────────────────────────────────

  describe "XPath finding" do
    it "is available after visit" do
      session.visit("/lightpanda/simple")
      results = session.all(:xpath, "//p")
      assert_operator results.length, :>=, 1
    end

    it "works after back" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      results = session.all(:xpath, "//p")
      assert_operator results.length, :>=, 1
    end

    it "works after forward" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      session.go_forward
      results = session.all(:xpath, "//p")
      assert_operator results.length, :>=, 1
    end

    it "works after refresh" do
      session.visit("/lightpanda/simple")
      driver.refresh
      results = session.all(:xpath, "//p")
      assert_operator results.length, :>=, 1
    end
  end

  # ───────────────────────────────────────────────
  # JavaScript evaluation
  # ───────────────────────────────────────────────

  describe "JavaScript evaluation" do
    before { session.visit("/lightpanda/js_test") }

    it "evaluates a simple arithmetic expression" do
      assert_equal 2, session.evaluate_script("1 + 1")
    end

    it "reads a global variable" do
      assert_equal 42, session.evaluate_script("window.testValue")
    end

    it "returns strings" do
      assert_equal "hello world", session.evaluate_script("'hello world'")
    end

    it "returns null as nil" do
      assert_nil session.evaluate_script("null")
    end

    it "returns undefined as nil" do
      assert_nil session.evaluate_script("undefined")
    end

    it "returns booleans" do
      assert_equal true, session.evaluate_script("true")
      assert_equal false, session.evaluate_script("false")
    end

    it "returns arrays" do
      assert_equal [1, 2, 3], session.evaluate_script("[1, 2, 3]")
    end

    it "returns objects" do
      result = session.evaluate_script("({a: 1, b: 'two'})")
      assert_equal({ "a" => 1, "b" => "two" }, result)
    end

    it "returns nested structures" do
      result = session.evaluate_script("({arr: [1, {x: 2}]})")
      assert_equal({ "arr" => [1, { "x" => 2 }] }, result)
    end

    it "returns floats" do
      assert_in_delta 3.14, session.evaluate_script("3.14"), 0.001
    end

    it "executes script without return value" do
      session.execute_script("document.getElementById('result').textContent = 'executed'")
      assert_equal "executed", session.find(:css, "#result").text
    end

    it "raises JavaScriptError on thrown exceptions" do
      assert_raises(Capybara::Lightpanda::JavaScriptError) do
        session.evaluate_script("throw new Error('test error')")
      end
    end

    it "raises JavaScriptError with class name" do
      session.evaluate_script("throw new TypeError('bad type')")
    rescue Capybara::Lightpanda::JavaScriptError => e
      assert_equal "TypeError", e.class_name
    end

    it "can manipulate the DOM" do
      session.execute_script("document.title = 'Modified'")
      assert_equal "Modified", session.title
    end
  end

  # ───────────────────────────────────────────────
  # Node text & attributes
  # ───────────────────────────────────────────────

  describe "node text and attributes" do
    before { session.visit("/lightpanda/form_test") }

    it "reads text content" do
      label = session.find(:css, "label[for='name']")
      assert_equal "Name", label.text
    end

    it "reads tag name in lowercase" do
      input = session.find(:css, "#name")
      assert_equal "input", input.tag_name
    end

    it "reads standard attributes" do
      input = session.find(:css, "#name")
      assert_equal "text", input["type"]
      assert_equal "name", input["id"]
      assert_equal "Enter name", input["placeholder"]
    end

    it "returns nil for missing attributes" do
      input = session.find(:css, "#name")
      assert_nil input["data-nonexistent"]
    end

    it "resolves href attributes to full URLs" do
      session.visit("/lightpanda/links")
      link = session.find(:css, "#absolute-link")
      assert_match(%r{http://.+/lightpanda/simple$}, link["href"])
    end

    it "resolves src attributes to full URLs" do
      session.visit("/lightpanda/links")
      img = session.find(:css, "#test-image")
      assert_match(%r{http://.+/lightpanda/image\.png$}, img["src"])
    end

    it "reads hidden input value via attribute" do
      hidden = session.find(:css, "#secret", visible: false)
      assert_equal "hidden_value", hidden["value"]
    end
  end

  # ───────────────────────────────────────────────
  # Visibility detection
  # ───────────────────────────────────────────────

  describe "visibility detection" do
    before { session.visit("/lightpanda/visibility") }

    it "treats inline style=display:none as not visible" do
      refute_predicate session.find(:css, "#hidden-display-inline", visible: false), :visible?
    end

    it "treats class-rule display:none as not visible" do
      refute_predicate session.find(:css, "#hidden-display-class", visible: false), :visible?
    end

    it "treats inline style=visibility:hidden as not visible" do
      refute_predicate session.find(:css, "#hidden-visibility-inline", visible: false), :visible?
    end

    it "treats class-rule visibility:hidden as not visible" do
      refute_predicate session.find(:css, "#hidden-visibility-class", visible: false), :visible?
    end

    it "treats inline style=visibility:collapse as not visible" do
      refute_predicate session.find(:css, "#hidden-collapse-inline", visible: false), :visible?
    end

    it "treats the HTML `hidden` attribute as not visible" do
      refute_predicate session.find(:css, "#hidden-attr", visible: false), :visible?
    end

    it "cascades hidden attribute through ancestor to descendants" do
      refute_predicate session.find(:css, "#hidden-via-ancestor", visible: false), :visible?
    end

    it "treats <input type=hidden> as not visible" do
      refute_predicate session.find(:css, "#hidden-input", visible: false), :visible?
    end

    it "treats descendants of closed <details> (other than <summary>) as not visible" do
      refute_predicate session.find(:css, "#details-body", visible: false), :visible?
      assert_predicate session.find(:css, "#closed-summary"), :visible?
    end

    it "treats descendants of an open <details> as visible" do
      assert_predicate session.find(:css, "#open-body"), :visible?
    end

    it "toggles <details> open when its <summary> is clicked" do
      assert_equal false, session.evaluate_script("document.getElementById('closed-details').open")
      session.find(:css, "#closed-summary").click
      assert_equal true, session.evaluate_script("document.getElementById('closed-details').open")
      assert_predicate session.find(:css, "#details-body"), :visible?
    end

    it "considers display:none elements obscured" do
      assert_predicate session.find(:css, "#hidden-display-inline", visible: false), :obscured?
      assert_predicate session.find(:css, "#hidden-display-class", visible: false), :obscured?
    end

    it "considers visibility:hidden elements obscured" do
      assert_predicate session.find(:css, "#hidden-visibility-inline", visible: false), :obscured?
    end

    it "considers descendants of hidden-attr ancestors obscured" do
      assert_predicate session.find(:css, "#hidden-via-ancestor", visible: false), :obscured?
    end

    it "filters hidden descendants out of visible_text" do
      el = session.find(:css, "#text-with-hidden")
      assert_includes el.text, "Visible part"
      assert_includes el.text, "and more"
      refute_includes el.text, "SECRET"
    end
  end

  # ───────────────────────────────────────────────
  # Form interaction
  # ───────────────────────────────────────────────

  describe "form interaction" do
    before { session.visit("/lightpanda/form_test") }

    it "sets and reads text input value" do
      input = session.find(:css, "#name")
      input.set("Test User")
      assert_equal "Test User", input.value
    end

    it "sets and reads email input value" do
      input = session.find(:css, "#email")
      input.set("test@example.com")
      assert_equal "test@example.com", input.value
    end

    it "sets and reads password input value" do
      input = session.find(:css, "#password")
      input.set("secret123")
      assert_equal "secret123", input.value
    end

    it "sets and reads textarea value" do
      textarea = session.find(:css, "#bio")
      textarea.set("Some bio text\nwith newlines")
      assert_equal "Some bio text\nwith newlines", textarea.value
    end

    it "clears input before setting new value" do
      input = session.find(:css, "#name")
      input.set("First")
      input.set("Second")
      assert_equal "Second", input.value
    end

    describe "checkboxes" do
      it "checks an unchecked checkbox" do
        checkbox = session.find(:css, "#agree")
        refute_predicate checkbox, :checked?
        checkbox.set(true)
        assert_predicate checkbox, :checked?
      end

      it "unchecks a checked checkbox" do
        checkbox = session.find(:css, "#newsletter")
        assert_predicate checkbox, :checked?
        checkbox.set(false)
        refute_predicate checkbox, :checked?
      end

      it "is idempotent when setting same value" do
        checkbox = session.find(:css, "#agree")
        checkbox.set(true)
        checkbox.set(true)
        assert_predicate checkbox, :checked?
      end
    end

    describe "radio buttons" do
      it "selects a radio button" do
        radio = session.find(:css, "#gender-male")
        radio.set(true)
        assert_predicate radio, :checked?
      end

      it "checks a different radio in the group" do
        male = session.find(:css, "#gender-male")
        female = session.find(:css, "#gender-female")
        male.set(true)
        assert_predicate male, :checked?
        female.set(true)
        assert_predicate female, :checked?
      end
    end

    describe "select dropdowns" do
      it "selects an option" do
        select_el = session.find(:css, "#color")
        session.find(:css, "#color option[value='blue']").select_option
        assert_equal "blue", select_el.value
      end

      it "reads selected? on options" do
        session.find(:css, "#color option[value='blue']").select_option
        assert_predicate session.find(:css, "#color option[value='blue']"), :selected?
      end
    end

    describe "multi-select" do
      it "selects multiple options" do
        session.find(:css, "#hobbies option[value='reading']").select_option
        session.find(:css, "#hobbies option[value='coding']").select_option
        values = session.find(:css, "#hobbies").value
        assert_includes values, "reading"
        assert_includes values, "coding"
      end

      it "unselects an option" do
        session.find(:css, "#hobbies option[value='reading']").select_option
        session.find(:css, "#hobbies option[value='reading']").unselect_option
        values = session.find(:css, "#hobbies").value
        refute_includes values, "reading"
      end

      it "reports multiple? as true" do
        assert_predicate session.find(:css, "#hobbies"), :multiple?
      end

      it "reports multiple? as false for single select" do
        refute_predicate session.find(:css, "#color"), :multiple?
      end
    end

    describe "contenteditable" do
      it "sets content on contenteditable elements" do
        editable = session.find(:css, "#editable")
        editable.set("New content")
        assert_equal "New content", editable.text
      end
    end

    describe "disabled and readonly" do
      it "reports disabled? correctly" do
        assert_predicate session.find(:css, "#disabled-input"), :disabled?
        refute_predicate session.find(:css, "#name"), :disabled?
      end

      it "reports readonly? correctly" do
        assert_predicate session.find(:css, "#readonly-input"), :readonly?
        refute_predicate session.find(:css, "#name"), :readonly?
      end
    end

    describe "send_keys" do
      it "appends text to an input" do
        input = session.find(:css, "#name")
        input.set("Hello")
        input.send_keys(" World")
        assert_equal "Hello World", input.value
      end
    end
  end

  # ───────────────────────────────────────────────
  # Click interactions
  # ───────────────────────────────────────────────

  describe "click interactions" do
    before { session.visit("/lightpanda/js_test") }

    it "clicks a button" do
      session.find(:css, "#click-me").click
      assert_equal "clicked", session.find(:css, "#result").text
    end

    it "double clicks an element" do
      session.find(:css, "#dbl-click").double_click
      assert_equal "double-clicked", session.find(:css, "#result").text
    end

    it "right clicks an element" do
      session.find(:css, "#ctx-menu").right_click
      assert_equal "context-menu", session.find(:css, "#result").text
    end

    it "hovers over an element" do
      session.find(:css, "#hoverable").hover
      assert_equal "hovered", session.find(:css, "#result").text
    end

    # Clicking a non-interactive wrapper must reach a handler bound on an inner
    # node — the select2 pattern (helpers click the .select2-container, but the
    # open handler is on the inner .select2-choice). Without layout the gem
    # can't hit-test coordinates, so CLICK_JS descends to the first visible
    # child. The offscreen #s2-focusser sibling ensures a naive "single visible
    # child" rule would miss it; first-visible-child lands on #s2-trigger.
    it "descends a wrapper click to an inner element's handler" do
      session.find(:css, "#s2-wrapper").click
      assert_equal "inner:s2-trigger", session.find(:css, "#result").text
    end

    # The descent must STOP at an element that carries its own click handler
    # (role=button / onclick), so the event lands there — not on a deeper child.
    it "does not descend past a handler-bearing wrapper" do
      session.find(:css, "#rb-wrapper").click
      assert_equal "rb:rb-wrapper:rb-wrapper", session.find(:css, "#result").text
    end
  end

  # ───────────────────────────────────────────────
  # Turbo-compatible form submission
  # ───────────────────────────────────────────────

  describe "Turbo-compatible form submission" do
    before { session.visit("/lightpanda/turbo_form") }

    it "fires submit event when clicking a button[type=submit]" do
      session.find(:css, "#btn-save").click
      assert_includes session.find(:css, "#submit-result").text, "intercepted"
    end

    it "passes correct submitter to the submit event" do
      session.find(:css, "#btn-save").click
      assert_equal "intercepted:btn-save", session.find(:css, "#submit-result").text
    end

    it "passes correct submitter for input[type=submit]" do
      session.find(:css, "#input-submit").click
      assert_equal "intercepted:input-submit", session.find(:css, "#submit-result").text
    end

    it "passes correct submitter for button with formaction" do
      session.find(:css, "#btn-publish").click
      assert_equal "intercepted:btn-publish", session.find(:css, "#submit-result").text
    end
  end

  # ───────────────────────────────────────────────
  # Turbo compatibility (fetch submit)
  # ───────────────────────────────────────────────

  describe "Turbo compatibility" do
    it "submits forms via fetch when Turbo is present" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-name").set("Test User")
      session.find(:css, "#turbo-submit").click
      session.assert_selector(:css, "#result-name", text: "Test User")
    end

    it "includes submitter name/value in fetch submission" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-name").set("Test")
      session.find(:css, "#turbo-save").click
      session.assert_selector(:css, "#result-action", text: "save")
    end

    it "respects formaction attribute on submit button" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-alt").click
      session.assert_selector(:css, "#alt-result", text: "Alt action reached")
    end
  end

  # ───────────────────────────────────────────────
  # Dynamic content
  # ───────────────────────────────────────────────

  describe "dynamic content" do
    before { session.visit("/lightpanda/dynamic") }

    it "finds dynamically added elements" do
      session.find(:css, "#add-element").click
      session.assert_selector(:css, "#dynamic-element", text: "I was added dynamically")
    end

    it "does not find removed elements" do
      session.find(:css, "#add-element").click
      session.assert_selector(:css, "#dynamic-element")
      session.find(:css, "#remove-element").click
      session.assert_no_selector(:css, "#dynamic-element", wait: 0.1)
    end
  end

  # ───────────────────────────────────────────────
  # CSS finding
  # ───────────────────────────────────────────────

  describe "CSS finding" do
    before { session.visit("/lightpanda/elements") }

    it "finds multiple elements by CSS" do
      items = session.all(:css, ".item")
      assert_equal 3, items.length
    end

    it "finds a single element by id" do
      el = session.find(:css, "#heading")
      assert_equal "Heading", el.text
    end

    it "finds elements by compound selectors" do
      cells = session.all(:css, "#data-table tbody td")
      assert_equal 4, cells.length
    end

    it "returns empty for non-matching selectors" do
      els = session.all(:css, ".nonexistent", wait: false)
      assert_empty els
    end

    it "finds elements within a parent" do
      parent = session.find(:css, "#list")
      children = parent.all(:css, ".item")
      assert_equal 3, children.length
    end
  end

  # ───────────────────────────────────────────────
  # XPath finding (Capybara integration smoke)
  #
  # These tests route through `session.find(:xpath, ...)` and
  # `session.all(:xpath, ...)` — exercising the full driver path
  # (visibility filtering, error retry, Capybara wrapping). Comprehensive
  # polyfill-engine coverage lives in the next describe block.
  # ───────────────────────────────────────────────

  describe "XPath finding" do
    before { session.visit("/lightpanda/elements") }

    it "round-trips a simple xpath through session.all" do
      assert_equal 3, session.all(:xpath, "//li").length
    end

    it "round-trips a Capybara-style class selector through session.find" do
      el = session.find(:xpath, "//*[contains(concat(' ', @class, ' '), ' item ')]", match: :first)
      assert_equal "li", el.tag_name
    end

    it "evaluates count() in a predicate through session.find" do
      el = session.find(:xpath, "//ul[count(li) = 3]")
      assert_equal "ul", el.tag_name
    end

    # XPath spec: positional predicates on reverse axes evaluate in axis
    # (proximity) order. ancestor::*[1] must pick the parent, NOT the root.
    # Pins the polyfill regression where reverse axes were emitted in document
    # order, flipping which node `[1]` selected.
    it "ancestor::*[1] returns the nearest ancestor (proximity order predicate)" do
      el = session.find(:xpath, "//td[normalize-space() = '1']/ancestor::*[1]")
      assert_equal "tr", el.tag_name
    end

    it "preceding-sibling::*[1] returns the closest preceding sibling" do
      el = session.find(:xpath, "//li[3]/preceding-sibling::*[1]")
      assert_equal "Item 2", el.text
    end
  end

  # XPath conformance is now covered by upstream's 91-case Zig battery in
  # PR #2305 (native Document.evaluate). The gem's only XPath-shaped surface
  # is the FIND_WITHIN_JS / FIND_IN_FRAME_JS / find_in_document branches,
  # which are exercised end-to-end by Capybara's shared specs.

  # ───────────────────────────────────────────────
  # Capybara DSL (relies on XPath evaluator)
  # ───────────────────────────────────────────────

  describe "Capybara DSL" do
    it "fill_in finds input by label text" do
      session.visit("/lightpanda/form_test")
      session.fill_in("Name", with: "Test User")
      assert_equal "Test User", session.find(:css, "#name").value
    end

    it "click_link finds link by text" do
      session.visit("/lightpanda/simple")
      session.click_link("Go to other page")
      assert_equal "Other Page", session.title
    end

    it "click_button finds submit button by value" do
      session.visit("/lightpanda/form_test")
      session.fill_in("Name", with: "Test")
      session.click_button("Submit")
      session.assert_selector(:css, "#results")
    end

    it "find(:label) finds label by text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:label, "Name")
      assert_equal "label", el.tag_name
    end

    it "find(:link) finds link by text" do
      session.visit("/lightpanda/simple")
      el = session.find(:link, "Go to other page")
      assert_equal "a", el.tag_name
    end

    it "find(:button) finds button by value" do
      session.visit("/lightpanda/form_test")
      el = session.find(:button, "Submit")
      assert_equal "input", el.tag_name
    end

    it "find(:select) finds select by label text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:select, "Favorite Color")
      assert_equal "select", el.tag_name
    end

    it "find(:field) finds input by label text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:field, "Name")
      assert_equal "input", el.tag_name
    end
  end

  # ───────────────────────────────────────────────
  # Scoped finding (within)
  # ───────────────────────────────────────────────

  describe "scoped finding" do
    before { session.visit("/lightpanda/nested") }

    it "finds children within a parent element" do
      parent = session.find(:css, "#parent")
      children = parent.all(:css, ".child")
      assert_equal 3, children.length
    end

    it "scopes finding to within a specific container" do
      sibling = session.find(:css, "#sibling")
      children = sibling.all(:css, ".child")
      assert_equal 1, children.length
      assert_equal "Sibling child", children.first.text
    end

    it "finds nested descendants" do
      nested = session.find(:css, ".nested")
      children = nested.all(:css, ".child")
      assert_equal 1, children.length
      assert_equal "Nested child", children.first.text
    end
  end

  # ───────────────────────────────────────────────
  # Node path
  # ───────────────────────────────────────────────

  describe "node path" do
    it "returns a CSS path for elements with ids" do
      session.visit("/lightpanda/simple")
      el = session.find(:css, "#content")
      path = el.path
      assert_includes path, "#content"
    end

    it "returns a path for deeply nested elements" do
      session.visit("/lightpanda/elements")
      el = session.find(:css, ".item", match: :first)
      path = el.path
      refute_empty path
    end
  end

  # ───────────────────────────────────────────────
  # Element tag names
  # ───────────────────────────────────────────────

  describe "tag names" do
    before { session.visit("/lightpanda/elements") }

    it "returns correct tag names for various elements" do
      assert_equal "h1", session.find(:css, "#heading").tag_name
      assert_equal "p", session.find(:css, "#paragraph").tag_name
      assert_equal "span", session.find(:css, "#inline").tag_name
      assert_equal "div", session.find(:css, "#block").tag_name
      assert_equal "ul", session.find(:css, "#list").tag_name
      assert_equal "table", session.find(:css, "#data-table").tag_name
    end
  end

  # ───────────────────────────────────────────────
  # Frame support
  # ───────────────────────────────────────────────

  describe "frame support" do
    before { session.visit("/lightpanda/with_frame") }

    it "pushes and pops frame stack" do
      frame = session.find(:css, "#test-frame")
      assert_empty browser.frame_stack
      driver.switch_to_frame(frame)
      assert_equal 1, browser.frame_stack.length
      driver.switch_to_frame(:parent)
      assert_empty browser.frame_stack
    end

    it "clears frame stack on :top" do
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      driver.switch_to_frame(:top)
      assert_empty browser.frame_stack
    end

    it "finds the main page content outside the frame" do
      assert_equal "Main Page", session.find(:css, "#main-heading").text
    end

    it "finds elements inside a frame" do
      sleep 0.5
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      els = session.all(:css, "#frame-text", wait: 2)
      assert_equal 1, els.length
      assert_equal "Inside the frame", els.first.text
      driver.switch_to_frame(:top)
    end

    it "switches back to top and finds main content" do
      sleep 0.5
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      driver.switch_to_frame(:top)
      assert_equal "Main Page", session.find(:css, "#main-heading").text
    end
  end

  # ───────────────────────────────────────────────
  # Error handling
  # ───────────────────────────────────────────────

  describe "error handling" do
    it "raises JavaScriptError for JS exceptions" do
      session.visit("/lightpanda/js_test")
      err = assert_raises(Capybara::Lightpanda::JavaScriptError) do
        session.evaluate_script("throw new Error('boom')")
      end
      assert_match(/boom/, err.message)
    end

    # Uploads are supported since build 6672 (DOM.setFileInputFiles) — a bad
    # path must surface the browser's FileNotFound instead of silently
    # submitting an empty input. Happy-path coverage: #attach_file shared specs.
    it "raises BrowserError(FileNotFound) when the upload path doesn't exist" do
      session.visit("/lightpanda/form_test")
      js = "var fi = document.createElement('input'); fi.type='file'; fi.id='file-input'; document.body.appendChild(fi)"
      session.execute_script(js)
      file_input = session.find(:css, "#file-input", visible: false)
      err = assert_raises(Capybara::Lightpanda::BrowserError) do
        file_input.set("/nonexistent/lightpanda/upload.txt")
      end
      assert_match(/FileNotFound/, err.message)
    end
  end

  # ───────────────────────────────────────────────
  # Browser lifecycle
  # ───────────────────────────────────────────────

  describe "browser lifecycle" do
    it "detects when browser connection is alive" do
      session.visit("/lightpanda/simple")
      assert_equal true, driver.browser_alive?
    end

    it "reports dead connection for uninitialized driver" do
      fresh_driver = Capybara::Lightpanda::Driver.new(TestApp, driver.options)
      assert_equal false, fresh_driver.browser_alive?
    end
  end

  # ───────────────────────────────────────────────
  # CDP error handling (last — invalid commands corrupt Lightpanda state)
  # ───────────────────────────────────────────────

  describe "CDP error handling" do
    it "raises BrowserError on invalid commands" do
      assert_raises(Capybara::Lightpanda::BrowserError) do
        browser.page_command("NonExistent.method")
      end
    end
  end
end
