# frozen_string_literal: true

require "spec_helper"

# Comprehensive test suite for capybara-lightpanda.
#
# Tests use CSS selectors and direct DOM APIs to avoid depending on
# Capybara's complex XPath label matchers (which require a full XPath engine).
#
# Test ordering note: Network and cookie tests come early because Lightpanda's
# beta browser can become unresponsive after many rapid CDP interactions.
# Tests that are "heavier" (forms, dynamic content, clicks) come later.

RSpec.describe Capybara::Lightpanda::Driver do
  let(:session) { TestSessions::Lightpanda }
  let(:driver) { session.driver }
  let(:browser) { driver.browser }

  after { session.reset_session! }

  # ───────────────────────────────────────────────
  # Driver setup & lifecycle
  # ───────────────────────────────────────────────

  describe "driver setup" do
    it "returns true for needs_server?" do
      expect(driver.needs_server?).to be true
    end

    it "returns true for wait?" do
      expect(driver.wait?).to be true
    end

    it "provides invalid_element_errors for Capybara retry logic" do
      errors = driver.invalid_element_errors
      expect(errors).to include(Capybara::Lightpanda::NodeNotFoundError)
      expect(errors).to include(Capybara::Lightpanda::NoExecutionContextError)
      expect(errors).to include(Capybara::Lightpanda::ObsoleteNode)
      expect(errors).to include(Capybara::Lightpanda::MouseEventFailed)
    end

    it "exposes the browser object" do
      expect(driver.browser).to be_a(Capybara::Lightpanda::Browser)
    end

    it "lazily initializes @browser as nil" do
      fresh_driver = Capybara::Lightpanda::Driver.new(TestApp, driver.options)
      expect(fresh_driver.instance_variable_get(:@browser)).to be_nil
    end
  end

  # ───────────────────────────────────────────────
  # Navigation
  # ───────────────────────────────────────────────

  describe "navigation" do
    it "visits a page and reads the title" do
      session.visit("/lightpanda/simple")
      expect(session.title).to eq("Simple Page")
    end

    it "reads the current URL" do
      session.visit("/lightpanda/simple")
      expect(session.current_url).to match(%r{/lightpanda/simple$})
    end

    it "reads the page body as HTML" do
      session.visit("/lightpanda/simple")
      expect(session.html).to include("Hello from Lightpanda")
      expect(session.html).to include("<h1>")
    end

    it "navigates back" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      expect(session.title).to eq("Other Page")
      session.go_back
      expect(session.title).to eq("Simple Page")
    end

    it "navigates forward" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      expect(session.title).to eq("Simple Page")
      session.go_forward
      expect(session.title).to eq("Other Page")
    end

    it "refreshes the page" do
      session.visit("/lightpanda/simple")
      expect(session.title).to eq("Simple Page")
      driver.refresh
      expect(session.title).to eq("Simple Page")
    end

    it "follows links via click" do
      session.visit("/lightpanda/simple")
      session.find(:css, "a[href='/lightpanda/other']").click
      expect(session).to have_css("#content", text: "This is the other page")
    end
  end

  # ───────────────────────────────────────────────
  # CDP client direct access
  # ───────────────────────────────────────────────

  describe "CDP client" do
    it "sends page-scoped commands via page_command" do
      session.visit("/lightpanda/simple")
      result = browser.page_command("Runtime.evaluate", expression: "1 + 2", returnByValue: true)
      expect(result.dig("result", "value")).to eq(3)
    end

    it "sends browser-scoped commands via command" do
      result = browser.command("Target.getTargets")
      expect(result).to have_key("targetInfos")
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
      expect(traffic).not_to be_empty
      expect(traffic.first).to have_key(:url)
      expect(traffic.first).to have_key(:method)
      browser.network.disable
    end

    it "clears traffic history" do
      session.visit("/lightpanda/simple")
      browser.network.enable
      session.visit("/lightpanda/other")
      expect(browser.network.traffic).not_to be_empty
      browser.network.clear
      expect(browser.network.traffic).to be_empty
      browser.network.disable
    end

    it "is idempotent for enable/disable" do
      browser.network.enable
      browser.network.enable
      browser.network.disable
      browser.network.disable
    end
  end

  # ───────────────────────────────────────────────
  # Cookies
  # ───────────────────────────────────────────────

  describe "cookies" do
    it "sets and reads cookies via server" do
      session.visit("/lightpanda/set_test_cookie")
      session.visit("/lightpanda/get_test_cookie")
      expect(session).to have_css("body", text: "cookie_value")
    end

    it "clears cookies via Network.clearBrowserCookies" do
      session.visit("/lightpanda/set_test_cookie")
      cookies = browser.cookies.all
      expect(cookies.any? { |c| c["name"] == "lightpanda_test" }).to be true

      browser.cookies.clear
      cookies_after = browser.cookies.all
      expect(cookies_after).to be_empty
    end

    it "sets and gets cookies via CDP API" do
      session.visit("/lightpanda/simple")
      # Lightpanda requires domain for Network.setCookie
      host = URI.parse(session.current_url).host
      browser.cookies.set(name: "cdp_cookie", value: "cdp_value", domain: host)
      cookie = browser.cookies.get("cdp_cookie")
      expect(cookie).not_to be_nil
      expect(cookie["value"]).to eq("cdp_value")
    end

    it "deletes a specific cookie via CDP API" do
      session.visit("/lightpanda/simple")
      host = URI.parse(session.current_url).host
      browser.cookies.set(name: "to_delete", value: "bye", domain: host)
      expect(browser.cookies.get("to_delete")).not_to be_nil

      browser.cookies.remove(name: "to_delete", domain: host)
      expect(browser.cookies.get("to_delete")).to be_nil
    end

    it "preserves cookies through a redirect" do
      session.visit("/lightpanda/set_cookie_and_redirect")
      # The 302 response sets a cookie, then redirects to /get_test_cookie.
      # Verify the cookie exists in the browser's cookie jar.
      cookie = browser.cookies.get("redirect_test")
      expect(cookie).not_to be_nil, "Cookie set on 302 response not stored in browser"
      expect(cookie["value"]).to eq("survived_redirect")
    end

    it "sends redirect-set cookies on the follow-up request" do
      session.visit("/lightpanda/set_cookie_and_redirect")
      body = session.evaluate_script("document.body.textContent").strip
      # Pre-existing Lightpanda limitation (verified on v0.2.7 and nightly):
      # cookies set via Set-Cookie on a 302 response are stored in the jar
      # but not sent on the immediate follow-up request to the redirect target.
      pending "Lightpanda stores redirect cookies but doesn't send them on follow-up request" if body == "No cookie"
      expect(body).to include("survived_redirect")
    end

    it "sends SameSite=Strict cookies on same-origin navigation" do
      session.visit("/lightpanda/set_samesite_cookie")
      session.visit("/lightpanda/check_cookies")
      expect(session).to have_css("body", text: "ss_strict=strict_val")
    end
  end

  # ───────────────────────────────────────────────
  # Reset
  # ───────────────────────────────────────────────

  describe "reset" do
    it "resets the session to about:blank" do
      session.visit("/lightpanda/simple")
      expect(session.title).to eq("Simple Page")
      driver.reset!
      expect(browser.current_url).to match(/about:blank/)
    end

    it "survives multiple resets" do
      session.visit("/lightpanda/simple")
      3.times { driver.reset! }
      session.visit("/lightpanda/simple")
      expect(session.title).to eq("Simple Page")
    end
  end

  # ───────────────────────────────────────────────
  # XPath polyfill re-injection
  # ───────────────────────────────────────────────

  describe "XPath polyfill" do
    it "is available after visit" do
      session.visit("/lightpanda/simple")
      results = session.all(:xpath, "//p")
      expect(results.length).to be >= 1
    end

    it "is re-injected after back" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      results = session.all(:xpath, "//p")
      expect(results.length).to be >= 1
    end

    it "is re-injected after forward" do
      session.visit("/lightpanda/simple")
      session.visit("/lightpanda/other")
      session.go_back
      session.go_forward
      results = session.all(:xpath, "//p")
      expect(results.length).to be >= 1
    end

    it "is re-injected after refresh" do
      session.visit("/lightpanda/simple")
      driver.refresh
      results = session.all(:xpath, "//p")
      expect(results.length).to be >= 1
    end
  end

  # ───────────────────────────────────────────────
  # JavaScript evaluation
  # ───────────────────────────────────────────────

  describe "JavaScript evaluation" do
    before { session.visit("/lightpanda/js_test") }

    it "evaluates a simple arithmetic expression" do
      expect(session.evaluate_script("1 + 1")).to eq(2)
    end

    it "reads a global variable" do
      expect(session.evaluate_script("window.testValue")).to eq(42)
    end

    it "returns strings" do
      expect(session.evaluate_script("'hello world'")).to eq("hello world")
    end

    it "returns null as nil" do
      expect(session.evaluate_script("null")).to be_nil
    end

    it "returns undefined as nil" do
      expect(session.evaluate_script("undefined")).to be_nil
    end

    it "returns booleans" do
      expect(session.evaluate_script("true")).to be true
      expect(session.evaluate_script("false")).to be false
    end

    it "returns arrays" do
      expect(session.evaluate_script("[1, 2, 3]")).to eq([1, 2, 3])
    end

    it "returns objects" do
      result = session.evaluate_script("({a: 1, b: 'two'})")
      expect(result).to eq("a" => 1, "b" => "two")
    end

    it "returns nested structures" do
      result = session.evaluate_script("({arr: [1, {x: 2}]})")
      expect(result).to eq("arr" => [1, { "x" => 2 }])
    end

    it "returns floats" do
      expect(session.evaluate_script("3.14")).to be_within(0.001).of(3.14)
    end

    it "executes script without return value" do
      session.execute_script("document.getElementById('result').textContent = 'executed'")
      expect(session.find(:css, "#result").text).to eq("executed")
    end

    it "raises JavaScriptError on thrown exceptions" do
      expect do
        session.evaluate_script("throw new Error('test error')")
      end.to raise_error(Capybara::Lightpanda::JavaScriptError)
    end

    it "raises JavaScriptError with class name" do
      session.evaluate_script("throw new TypeError('bad type')")
    rescue Capybara::Lightpanda::JavaScriptError => e
      expect(e.class_name).to eq("TypeError")
    end

    it "can manipulate the DOM" do
      session.execute_script("document.title = 'Modified'")
      expect(session.title).to eq("Modified")
    end
  end

  # ───────────────────────────────────────────────
  # Node text & attributes
  # ───────────────────────────────────────────────

  describe "node text and attributes" do
    before { session.visit("/lightpanda/form_test") }

    it "reads text content" do
      label = session.find(:css, "label[for='name']")
      expect(label.text).to eq("Name")
    end

    it "reads tag name in lowercase" do
      input = session.find(:css, "#name")
      expect(input.tag_name).to eq("input")
    end

    it "reads standard attributes" do
      input = session.find(:css, "#name")
      expect(input["type"]).to eq("text")
      expect(input["id"]).to eq("name")
      expect(input["placeholder"]).to eq("Enter name")
    end

    it "returns nil for missing attributes" do
      input = session.find(:css, "#name")
      expect(input["data-nonexistent"]).to be_nil
    end

    it "resolves href attributes to full URLs" do
      session.visit("/lightpanda/links")
      link = session.find(:css, "#absolute-link")
      expect(link["href"]).to match(%r{http://.+/lightpanda/simple$})
    end

    it "resolves src attributes to full URLs" do
      session.visit("/lightpanda/links")
      img = session.find(:css, "#test-image")
      expect(img["src"]).to match(%r{http://.+/lightpanda/image\.png$})
    end

    it "reads hidden input value via attribute" do
      hidden = session.find(:css, "#secret", visible: false)
      expect(hidden["value"]).to eq("hidden_value")
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
      expect(input.value).to eq("Test User")
    end

    it "sets and reads email input value" do
      input = session.find(:css, "#email")
      input.set("test@example.com")
      expect(input.value).to eq("test@example.com")
    end

    it "sets and reads password input value" do
      input = session.find(:css, "#password")
      input.set("secret123")
      expect(input.value).to eq("secret123")
    end

    it "sets and reads textarea value" do
      textarea = session.find(:css, "#bio")
      textarea.set("Some bio text\nwith newlines")
      expect(textarea.value).to eq("Some bio text\nwith newlines")
    end

    it "clears input before setting new value" do
      input = session.find(:css, "#name")
      input.set("First")
      input.set("Second")
      expect(input.value).to eq("Second")
    end

    describe "checkboxes" do
      it "checks an unchecked checkbox" do
        checkbox = session.find(:css, "#agree")
        expect(checkbox).not_to be_checked
        checkbox.set(true)
        expect(checkbox).to be_checked
      end

      it "unchecks a checked checkbox" do
        checkbox = session.find(:css, "#newsletter")
        expect(checkbox).to be_checked
        checkbox.set(false)
        expect(checkbox).not_to be_checked
      end

      it "is idempotent when setting same value" do
        checkbox = session.find(:css, "#agree")
        checkbox.set(true)
        checkbox.set(true)
        expect(checkbox).to be_checked
      end
    end

    describe "radio buttons" do
      it "selects a radio button" do
        radio = session.find(:css, "#gender-male")
        radio.set(true)
        expect(radio).to be_checked
      end

      it "checks a different radio in the group" do
        male = session.find(:css, "#gender-male")
        female = session.find(:css, "#gender-female")
        male.set(true)
        expect(male).to be_checked
        female.set(true)
        expect(female).to be_checked
      end
    end

    describe "select dropdowns" do
      it "selects an option" do
        select_el = session.find(:css, "#color")
        session.find(:css, "#color option[value='blue']").select_option
        expect(select_el.value).to eq("blue")
      end

      it "reads selected? on options" do
        session.find(:css, "#color option[value='blue']").select_option
        expect(session.find(:css, "#color option[value='blue']")).to be_selected
      end
    end

    describe "multi-select" do
      it "selects multiple options" do
        session.find(:css, "#hobbies option[value='reading']").select_option
        session.find(:css, "#hobbies option[value='coding']").select_option
        values = session.find(:css, "#hobbies").value
        expect(values).to include("reading")
        expect(values).to include("coding")
      end

      it "unselects an option" do
        session.find(:css, "#hobbies option[value='reading']").select_option
        session.find(:css, "#hobbies option[value='reading']").unselect_option
        values = session.find(:css, "#hobbies").value
        expect(values).not_to include("reading")
      end

      it "reports multiple? as true" do
        expect(session.find(:css, "#hobbies")).to be_multiple
      end

      it "reports multiple? as false for single select" do
        expect(session.find(:css, "#color")).not_to be_multiple
      end
    end

    describe "contenteditable" do
      it "sets content on contenteditable elements" do
        editable = session.find(:css, "#editable")
        editable.set("New content")
        expect(editable.text).to eq("New content")
      end
    end

    describe "disabled and readonly" do
      it "reports disabled? correctly" do
        expect(session.find(:css, "#disabled-input")).to be_disabled
        expect(session.find(:css, "#name")).not_to be_disabled
      end

      it "reports readonly? correctly" do
        expect(session.find(:css, "#readonly-input")).to be_readonly
        expect(session.find(:css, "#name")).not_to be_readonly
      end
    end

    describe "send_keys" do
      it "appends text to an input" do
        input = session.find(:css, "#name")
        input.set("Hello")
        input.send_keys(" World")
        expect(input.value).to eq("Hello World")
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
      expect(session.find(:css, "#result").text).to eq("clicked")
    end

    it "double clicks an element" do
      session.find(:css, "#dbl-click").double_click
      expect(session.find(:css, "#result").text).to eq("double-clicked")
    end

    it "right clicks an element" do
      session.find(:css, "#ctx-menu").right_click
      expect(session.find(:css, "#result").text).to eq("context-menu")
    end

    it "hovers over an element" do
      session.find(:css, "#hoverable").hover
      expect(session.find(:css, "#result").text).to eq("hovered")
    end
  end

  # ───────────────────────────────────────────────
  # Turbo-compatible form submission
  # ───────────────────────────────────────────────

  describe "Turbo-compatible form submission" do
    before { session.visit("/lightpanda/turbo_form") }

    it "fires submit event when clicking a button[type=submit]" do
      session.find(:css, "#btn-save").click
      expect(session.find(:css, "#submit-result").text).to include("intercepted")
    end

    it "passes correct submitter to the submit event" do
      session.find(:css, "#btn-save").click
      expect(session.find(:css, "#submit-result").text).to eq("intercepted:btn-save")
    end

    it "passes correct submitter for input[type=submit]" do
      session.find(:css, "#input-submit").click
      expect(session.find(:css, "#submit-result").text).to eq("intercepted:input-submit")
    end

    it "passes correct submitter for button with formaction" do
      session.find(:css, "#btn-publish").click
      expect(session.find(:css, "#submit-result").text).to eq("intercepted:btn-publish")
    end
  end

  # ───────────────────────────────────────────────
  # Turbo compatibility (CSS #id polyfill + fetch submit)
  # ───────────────────────────────────────────────

  describe "Turbo compatibility" do
    it "rewrites #id selectors to [id=\"...\"] so they survive body modify+replace" do
      session.visit("/lightpanda/turbo_drive")
      session.execute_script(<<~JS)
        document.body.innerHTML = '<h1 id="page-title">Modified</h1>';
        var nb = document.createElement('body');
        nb.innerHTML = '<h1 id="page-title">Replaced</h1><p id="extra">x</p>';
        document.body.replaceWith(nb);
      JS
      expect(session.evaluate_script("document.querySelector('#page-title') !== null")).to eq(true)
      expect(session.evaluate_script("document.querySelectorAll('body #extra').length")).to eq(1)
    end

    it "submits forms via fetch when Turbo is present" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-name").set("Test User")
      session.find(:css, "#turbo-submit").click
      expect(session).to have_css("#result-name", text: "Test User")
    end

    it "includes submitter name/value in fetch submission" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-name").set("Test")
      session.find(:css, "#turbo-save").click
      expect(session).to have_css("#result-action", text: "save")
    end

    it "respects formaction attribute on submit button" do
      session.visit("/lightpanda/turbo_form_submit")
      session.find(:css, "#turbo-alt").click
      expect(session).to have_css("#alt-result", text: "Alt action reached")
    end
  end

  # ───────────────────────────────────────────────
  # Dynamic content
  # ───────────────────────────────────────────────

  describe "dynamic content" do
    before { session.visit("/lightpanda/dynamic") }

    it "finds dynamically added elements" do
      session.find(:css, "#add-element").click
      expect(session).to have_css("#dynamic-element", text: "I was added dynamically")
    end

    it "does not find removed elements" do
      session.find(:css, "#add-element").click
      expect(session).to have_css("#dynamic-element")
      session.find(:css, "#remove-element").click
      expect(session).not_to have_css("#dynamic-element", wait: 0.1)
    end
  end

  # ───────────────────────────────────────────────
  # CSS finding
  # ───────────────────────────────────────────────

  describe "CSS finding" do
    before { session.visit("/lightpanda/elements") }

    it "finds multiple elements by CSS" do
      items = session.all(:css, ".item")
      expect(items.length).to eq(3)
    end

    it "finds a single element by id" do
      el = session.find(:css, "#heading")
      expect(el.text).to eq("Heading")
    end

    it "finds elements by compound selectors" do
      cells = session.all(:css, "#data-table tbody td")
      expect(cells.length).to eq(4)
    end

    it "returns empty for non-matching selectors" do
      els = session.all(:css, ".nonexistent", wait: false)
      expect(els).to be_empty
    end

    it "finds elements within a parent" do
      parent = session.find(:css, "#list")
      children = parent.all(:css, ".item")
      expect(children.length).to eq(3)
    end
  end

  # ───────────────────────────────────────────────
  # XPath finding
  # ───────────────────────────────────────────────

  describe "XPath finding" do
    before { session.visit("/lightpanda/elements") }

    it "finds elements by simple XPath" do
      items = session.all(:xpath, "//li")
      expect(items.length).to eq(3)
    end

    it "finds element by XPath with attribute predicate" do
      el = session.find(:xpath, "//h1[@id='heading']")
      expect(el.text).to eq("Heading")
    end

    it "finds elements by XPath with class" do
      rows = session.all(:xpath, "//tr[@class='row']")
      expect(rows.length).to eq(2)
    end

    it "handles union operator" do
      items = session.all(:xpath, "//h1 | //p")
      expect(items.length).to be >= 2
    end

    it "handles contains()" do
      el = session.find(:xpath, "//h1[contains(., 'Heading')]")
      expect(el.tag_name).to eq("h1")
    end

    it "handles normalize-space()" do
      el = session.find(:xpath, "//*[normalize-space(.) = 'Heading']")
      expect(el.tag_name).to eq("h1")
    end

    it "handles not()" do
      items = session.all(:xpath, "//h1[not(@class)]")
      expect(items).not_to be_empty
    end

    it "handles and/or in predicates" do
      items = session.all(:xpath, "//*[@id='heading' or @id='paragraph']")
      expect(items.length).to eq(2)
    end

    it "handles descendant axis" do
      items = session.all(:xpath, "//ul/descendant::li")
      expect(items.length).to eq(3)
    end

    it "handles parent axis" do
      el = session.find(:xpath, "//li/parent::ul")
      expect(el.tag_name).to eq("ul")
    end

    it "handles following-sibling axis" do
      items = session.all(:xpath, "//li[1]/following-sibling::li")
      expect(items.length).to eq(2)
    end

    it "handles starts-with()" do
      el = session.find(:xpath, "//*[starts-with(@id, 'head')]")
      expect(el.tag_name).to eq("h1")
    end

    it "handles text() node test" do
      el = session.find(:xpath, "//p[text()]", match: :first)
      expect(el.text).not_to be_empty
    end

    it "handles position predicate" do
      el = session.find(:xpath, "//li[1]")
      expect(el.text).to eq("Item 1")
    end

    it "handles last()" do
      el = session.find(:xpath, "//li[last()]")
      expect(el.text).to eq("Item 3")
    end

    it "handles self:: axis" do
      items = session.all(:xpath, "//li[self::li]")
      expect(items.length).to eq(3)
    end

    it "handles ancestor:: axis" do
      el = session.find(:xpath, "//li/ancestor::ul")
      expect(el.tag_name).to eq("ul")
    end

    it "handles concat()" do
      el = session.find(:xpath, "//*[contains(concat(' ', @class, ' '), ' item ')]", match: :first)
      expect(el.tag_name).to eq("li")
    end

    it "handles translate() for case-insensitive match" do
      xpath = "//*[translate(., 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', " \
              "'abcdefghijklmnopqrstuvwxyz') = 'heading']"
      el = session.find(:xpath, xpath)
      expect(el.tag_name).to eq("h1")
    end

    it "handles count()" do
      el = session.find(:xpath, "//ul[count(li) = 3]")
      expect(el.tag_name).to eq("ul")
    end
  end

  # ───────────────────────────────────────────────
  # Capybara DSL (relies on XPath evaluator)
  # ───────────────────────────────────────────────

  describe "Capybara DSL" do
    it "fill_in finds input by label text" do
      session.visit("/lightpanda/form_test")
      session.fill_in("Name", with: "Test User")
      expect(session.find(:css, "#name").value).to eq("Test User")
    end

    it "click_link finds link by text" do
      session.visit("/lightpanda/simple")
      session.click_link("Go to other page")
      expect(session.title).to eq("Other Page")
    end

    it "click_button finds submit button by value" do
      session.visit("/lightpanda/form_test")
      session.fill_in("Name", with: "Test")
      session.click_button("Submit")
      expect(session).to have_css("#results")
    end

    it "find(:label) finds label by text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:label, "Name")
      expect(el.tag_name).to eq("label")
    end

    it "find(:link) finds link by text" do
      session.visit("/lightpanda/simple")
      el = session.find(:link, "Go to other page")
      expect(el.tag_name).to eq("a")
    end

    it "find(:button) finds button by value" do
      session.visit("/lightpanda/form_test")
      el = session.find(:button, "Submit")
      expect(el.tag_name).to eq("input")
    end

    it "find(:select) finds select by label text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:select, "Favorite Color")
      expect(el.tag_name).to eq("select")
    end

    it "find(:field) finds input by label text" do
      session.visit("/lightpanda/form_test")
      el = session.find(:field, "Name")
      expect(el.tag_name).to eq("input")
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
      expect(children.length).to eq(3)
    end

    it "scopes finding to within a specific container" do
      sibling = session.find(:css, "#sibling")
      children = sibling.all(:css, ".child")
      expect(children.length).to eq(1)
      expect(children.first.text).to eq("Sibling child")
    end

    it "finds nested descendants" do
      nested = session.find(:css, ".nested")
      children = nested.all(:css, ".child")
      expect(children.length).to eq(1)
      expect(children.first.text).to eq("Nested child")
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
      expect(path).to include("#content")
    end

    it "returns a path for deeply nested elements" do
      session.visit("/lightpanda/elements")
      el = session.find(:css, ".item", match: :first)
      path = el.path
      expect(path).not_to be_empty
    end
  end

  # ───────────────────────────────────────────────
  # Element tag names
  # ───────────────────────────────────────────────

  describe "tag names" do
    before { session.visit("/lightpanda/elements") }

    it "returns correct tag names for various elements" do
      expect(session.find(:css, "#heading").tag_name).to eq("h1")
      expect(session.find(:css, "#paragraph").tag_name).to eq("p")
      expect(session.find(:css, "#inline").tag_name).to eq("span")
      expect(session.find(:css, "#block").tag_name).to eq("div")
      expect(session.find(:css, "#list").tag_name).to eq("ul")
      expect(session.find(:css, "#data-table").tag_name).to eq("table")
    end
  end

  # ───────────────────────────────────────────────
  # Frame support
  # ───────────────────────────────────────────────

  describe "frame support" do
    before { session.visit("/lightpanda/with_frame") }

    it "pushes and pops frame stack" do
      frame = session.find(:css, "#test-frame")
      expect(browser.frame_stack).to be_empty
      driver.switch_to_frame(frame)
      expect(browser.frame_stack.length).to eq(1)
      driver.switch_to_frame(:parent)
      expect(browser.frame_stack).to be_empty
    end

    it "clears frame stack on :top" do
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      driver.switch_to_frame(:top)
      expect(browser.frame_stack).to be_empty
    end

    it "finds the main page content outside the frame" do
      expect(session.find(:css, "#main-heading").text).to eq("Main Page")
    end

    it "finds elements inside a frame" do
      sleep 0.5
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      els = session.all(:css, "#frame-text", wait: 2)
      expect(els.length).to eq(1)
      expect(els.first.text).to eq("Inside the frame")
      driver.switch_to_frame(:top)
    end

    it "switches back to top and finds main content" do
      sleep 0.5
      frame = session.find(:css, "#test-frame")
      driver.switch_to_frame(frame)
      driver.switch_to_frame(:top)
      expect(session.find(:css, "#main-heading").text).to eq("Main Page")
    end
  end

  # ───────────────────────────────────────────────
  # Error handling
  # ───────────────────────────────────────────────

  describe "error handling" do
    it "raises JavaScriptError for JS exceptions" do
      session.visit("/lightpanda/js_test")
      expect do
        session.evaluate_script("throw new Error('boom')")
      end.to raise_error(Capybara::Lightpanda::JavaScriptError, /boom/)
    end

    it "raises NotImplementedError for file uploads" do
      session.visit("/lightpanda/form_test")
      js = "var fi = document.createElement('input'); fi.type='file'; fi.id='file-input'; document.body.appendChild(fi)"
      session.execute_script(js)
      file_input = session.find(:css, "#file-input", visible: false)
      expect do
        file_input.set("/tmp/test.txt")
      end.to raise_error(NotImplementedError, /File uploads/)
    end
  end

  # ───────────────────────────────────────────────
  # Browser lifecycle
  # ───────────────────────────────────────────────

  describe "browser lifecycle" do
    it "detects when browser connection is alive" do
      session.visit("/lightpanda/simple")
      expect(driver.browser_alive?).to be true
    end

    it "reports dead connection for uninitialized driver" do
      fresh_driver = Capybara::Lightpanda::Driver.new(TestApp, driver.options)
      expect(fresh_driver.browser_alive?).to be false
    end
  end

  # ───────────────────────────────────────────────
  # CDP error handling (last — invalid commands corrupt Lightpanda state)
  # ───────────────────────────────────────────────

  describe "CDP error handling" do
    it "raises BrowserError on invalid commands" do
      expect do
        browser.page_command("NonExistent.method")
      end.to raise_error(Capybara::Lightpanda::BrowserError)
    end
  end
end
