# frozen_string_literal: true

require "minitest/autorun"
require "capybara-lightpanda"
require "selenium-webdriver"
require "tmpdir"

class SeleniumContractTest < Minitest::Test
  APP = lambda do |env|
    if env["PATH_INFO"] == "/export"
      headers = { "content-type" => "application/octet-stream",
                  "content-disposition" => 'attachment; filename="report.bin"', }
      next [200, headers, [env.fetch("QUERY_STRING")]]
    end
    body = env["PATH_INFO"] == "/" ? '<iframe src="/admin/frame"></iframe>' : "<title>Consent</title>"
    [200, { "content-type" => "text/html" }, [body]]
  end

  def setup
    @default_directory = Dir.mktmpdir
    driver = ENV.fetch("CONTRACT_DRIVER", "lightpanda")
    Capybara.register_driver(:migration_browser) do |app|
      case driver
      when "selenium"
        options = Selenium::WebDriver::Chrome::Options.new(args: ["--headless", "--no-sandbox"])
        options.add_preference("download.default_directory", @default_directory)
        options.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"]
        Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
      when "lightpanda"
        Capybara::Lightpanda::Driver.new(app, save_path: @default_directory,
                                              browser_path: ENV.fetch("LIGHTPANDA_BIN", nil))
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
    @page&.driver&.quit
    FileUtils.remove_entry(@default_directory)
  end

  def test_download_helper_reads_each_export_from_the_selected_directory
    %w[first second].each do |report|
      path = File.join(@default_directory, report)
      assert_equal({}, @browser.public_send(:download_path=, path))
      assert_raises(Selenium::WebDriver::Error::InvalidArgumentError) { @browser.download_path = nil }
      download_report(report, path)
    end

    @page.reset_session!
    @page.visit("/")
    # Decidim configures the destination before every download example.
    after_reset = File.join(@default_directory, "after-reset")
    @page.driver.browser.download_path = after_reset
    download_report("after-reset", after_reset)
    assert_equal "first", File.binread(File.join(@default_directory, "first", "report.bin"))
    assert_equal "second", File.binread(File.join(@default_directory, "second", "report.bin"))
  end

  def download_report(report, destination)
    @page.execute_script("document.body.innerHTML = '<a href=/export?#{report}>Export</a>'")
    @page.click_link("Export")
    file = File.join(destination, "report.bin")
    Capybara::Lightpanda::Utils::Wait.until(timeout: 5) { File.file?(file) && File.binread(file) == report }
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
