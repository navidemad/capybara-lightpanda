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

  def test_decidim_mobile_and_desktop_helpers_change_the_next_pages_responsive_branch
    window = @browser.manage.window
    [["375", 667, true], [1920, 1080, false]].each do |width, height, mobile|
      rect = window.resize_to(width, height)
      assert_equal %w[height width x y], rect.keys.sort
      assert_equal mobile, rect.fetch("width") <= 767
      @page.visit("/")
      assert_equal mobile, @page.evaluate_script("matchMedia('(max-width: 767px)').matches")
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
