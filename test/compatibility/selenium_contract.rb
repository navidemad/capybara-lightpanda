# frozen_string_literal: true

require "minitest/autorun"
require "capybara-lightpanda"
require "selenium-webdriver"

class SeleniumContractTest < Minitest::Test
  APP = lambda do |env|
    body = env["PATH_INFO"] == "/" ? '<iframe src="/admin/frame"></iframe>' : "<title>Consent</title>"
    [200, { "content-type" => "text/html" }, [body]]
  end

  def setup
    driver = ENV.fetch("CONTRACT_DRIVER", "lightpanda")
    Capybara.register_driver(:migration_browser) do |app|
      case driver
      when "selenium"
        options = Selenium::WebDriver::Chrome::Options.new(args: ["--headless", "--no-sandbox"])
        options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"]
        Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
      when "lightpanda"
        Capybara::Lightpanda::Driver.new(app, browser_path: ENV.fetch("LIGHTPANDA_BIN", nil))
      else
        raise ArgumentError, "unknown contract driver #{driver.inspect}"
      end
    end
    Capybara.server = :puma, { Silent: true }
    @page = Capybara::Session.new(:migration_browser, APP)
    @page.visit("/")
    @browser = @page.driver.browser
  end

  def teardown
    @page.driver.quit
  end

  def test_native_attribute_reads_form_validation_and_current_field_values
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<input id="title" required value="draft" data-kind="title">' +
        '<select id="scope" required><option value="">Choose</option><option value="all">All</option></select>' +
        '<input id="consent" type="checkbox" checked><a id="export" href="">Export</a>';
      document.querySelector('#title').value = '';
      document.querySelector('#consent').checked = false;
    JS
    title = @page.find("#title").native
    assert_equal "Please fill out this field.", title.attribute("validationMessage")
    assert_equal "Please select an item in the list.", @page.find("#scope").native.attribute("validationMessage")
    assert_equal "", title.attribute("value")
    assert_equal "true", title.attribute("required")
    assert_equal "false", title.attribute("disabled")
    assert_equal "title", title.attribute("data-kind")
    assert_nil title.attribute("data-missing")
    assert_nil @page.find("#consent").native.attribute("checked")
    assert_equal "", @page.find("#export").native.attribute("href")

    @page.fill_in("title", with: "New initiative")
    @page.select("All", from: "scope")
    assert_equal "New initiative", title.attribute("value")
    assert_equal "", title.attribute("validationMessage")
    assert_equal "", @page.find("#scope").native.attribute("validationMessage")
  end

  def test_native_attribute_uses_live_properties_and_preserves_svg_link_values
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<input value="live" data-kind="field">' +
        '<svg><a href="report"><text>Report</text></a></svg>';
      document.querySelector("input").getAttribute = () => { throw Error("overridden") };
    JS
    input = @page.find("input").native
    assert_equal "live", input.attribute("value")
    assert_equal "field", input.attribute("data-kind")
    assert_nil input.attribute("data-absent")
    link = @page.find("svg a", visible: :all).native
    assert_equal({ "baseVal" => "report", "animVal" => "report" }, link.attribute("href"))
    assert_equal link.attribute("href"), link.attribute("HREF")
  end

  def test_browser_log_exposes_uncaught_errors_to_system_test_teardown
    @page.execute_script(<<~JS)
      setTimeout(() => { throw new Error("migration exception"); }, 0);
      setTimeout(() => { Promise.reject(new Error("migration rejection")); }, 5);
      Promise.reject(new Error("migration handled")).catch(() => {});
      setTimeout(() => {
        console.error("migration console");
        document.body.dataset.finished = "yes";
      }, 20);
    JS
    @page.assert_selector("body[data-finished=yes]", visible: :all)
    severe = @browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
    %w[exception rejection console].each do |kind|
      assert_equal 1, severe.count { |entry| entry.message.include?("migration #{kind}") }, severe.inspect
    end
    refute(severe.any? { |entry| entry.message.include?("migration handled") })

    @page.reset_session!
    @page.visit("/")
    refute(@page.driver.browser.logs.get(:browser).any? { |entry| entry.message.include?("migration") })
  end

  def test_decidim_mobile_and_desktop_helpers_change_the_next_pages_responsive_branch
    window = @browser.manage.window
    [["375", 667, true], [1920, 1080, false]].each do |width, height, mobile|
      rect = window.resize_to(width, height)
      assert_equal %w[height width x y], rect.keys.sort
      assert_equal mobile, rect.fetch("width") <= 767
      assert_equal height, rect.fetch("height")
      @page.visit("/")
      assert_equal mobile, @page.evaluate_script("matchMedia('(max-width: 767px)').matches")
      assert_equal mobile, @page.evaluate_script("matchMedia('(max-height: 800px)').matches")
    end
    assert_raises(Selenium::WebDriver::Error::InvalidArgumentError) { window.resize_to(-1, 500) }
    assert_raises(ArgumentError) { window.resize_to("mobile", 500) }
  end

  def test_cookie_manager_follows_the_current_frame
    @browser.execute_cdp("Network.setCookie", name: "inside", value: "frame", url: @page.current_url, path: "/admin")
    manager = @browser.manage
    assert_empty manager.all_cookies
    @page.within_frame do
      cookie = manager.cookie_named("inside")
      assert_equal "frame", cookie[:value]
      assert_nil cookie[:expires]
      assert_equal "Lax", cookie[:same_site]
      manager.delete_all_cookies
      assert_empty manager.all_cookies
    end
  end

  def test_sign_out_on_a_subdomain_preserves_the_parent_hosts_private_cookie
    url = URI(@page.current_url)
    url.host = "child.parent.localhost"
    @page.visit(url.to_s)
    @browser.execute_cdp("Network.setCookie", name: "login", value: "private", domain: "parent.localhost", path: "/")
    @browser.execute_cdp("Network.setCookie", name: "login", value: "shared", domain: ".parent.localhost", path: "/")
    assert_equal "shared", @browser.manage.cookie_named("login")[:value]
    @browser.manage.delete_all_cookies
    assert_empty @browser.manage.all_cookies

    url.host = "parent.localhost"
    @page.visit(url.to_s)
    assert_equal "private", @browser.manage.cookie_named("login")[:value]
  end

  def test_consent_cookie_metadata_and_scoped_sign_out
    url = @page.current_url
    expires = Time.now.to_i + 3600
    @browser.execute_cdp("Network.setCookie", name: "consent", value: "essential", url: url, path: "/",
                                              httpOnly: true, sameSite: "Lax", expires: expires)
    @browser.execute_cdp("Network.setCookie", name: "private", value: "keep", url: url, path: "/admin")
    @browser.execute_cdp("Network.setCookie", name: "other", value: "keep", domain: "other.example", path: "/")

    manager = @browser.manage
    cookie = manager.cookie_named("consent")
    expiration = cookie.fetch(:expires)
    assert_instance_of DateTime, expiration
    assert_in_delta expires, expiration.to_time.to_f, 0.001
    assert_equal({ name: "consent", value: "essential", path: "/", domain: URI(url).host,
                   secure: false, http_only: true, same_site: "Lax", }, cookie.except(:expires))
    assert_equal(["consent"], manager.all_cookies.map { |entry| entry[:name] })
    @browser.execute_cdp("Network.setCookie", name: "", value: "anonymous", url: url, path: "/")
    assert_equal "anonymous", manager.cookie_named("")[:value]
    manager.delete_all_cookies
    assert_empty manager.all_cookies
    assert_raises(Selenium::WebDriver::Error::NoSuchCookieError) { manager.cookie_named("consent") }
    @page.visit("/admin")
    assert_equal "keep", manager.cookie_named("private")[:value]
    others = @browser.execute_cdp("Network.getCookies", urls: ["http://other.example/"]).fetch("cookies")
    assert_equal(["other"], others.map { |entry| entry["name"] })
  end
end
