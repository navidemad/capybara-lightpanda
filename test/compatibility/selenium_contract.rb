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
    manager.delete_all_cookies
    assert_empty manager.all_cookies
    assert_raises(Selenium::WebDriver::Error::NoSuchCookieError) { manager.cookie_named("consent") }
    @page.visit("/admin")
    assert_equal "keep", manager.cookie_named("private")[:value]
    others = @browser.execute_cdp("Network.getCookies", urls: ["http://other.example/"]).fetch("cookies")
    assert_equal(["other"], others.map { |entry| entry["name"] })
  end
end
