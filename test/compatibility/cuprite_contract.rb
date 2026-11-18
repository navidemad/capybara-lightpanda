# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require "cgi"

# Run both load orders. The selection also determines which browser runs the
# shared examples. Both gems register their stock driver in either process.
if ENV.fetch("CONTRACT_DRIVER", "lightpanda") == "cuprite"
  require "capybara/cuprite"
  require "capybara-lightpanda"
else
  require "capybara-lightpanda"
  require "capybara/cuprite"
end

class CupriteContractTest < Minitest::Test
  APP = lambda do |env|
    if env["PATH_INFO"] == "/headers"
      values = env.select { |key, _| key.start_with?("HTTP_") }
      next [200, { "content-type" => "text/html" }, ["<pre>#{CGI.escapeHTML(values.to_json)}</pre>"]]
    end
    [200, { "content-type" => "text/html" }, ["<title>Store</title><label>Name<input></label>"]]
  end

  def setup
    @directory = Dir.mktmpdir
    options = { save_path: @directory, window_size: [900, 700] }
    if ENV.fetch("CONTRACT_DRIVER", "lightpanda") == "cuprite"
      options[:browser_path] = ENV["CHROME_BIN"] if ENV["CHROME_BIN"]
      Capybara.register_driver(:store_system) { |app| Capybara::Cuprite::Driver.new(app, options) }
    else
      options[:browser_path] = ENV["LIGHTPANDA_BIN"] if ENV["LIGHTPANDA_BIN"]
      Capybara::Lightpanda.register_cuprite_driver(:store_system, **options)
    end
    Capybara.server = :puma, { Silent: true }
    @page = Capybara::Session.new(:store_system, APP)
  end

  def teardown
    @page.driver.quit
    FileUtils.remove_entry(@directory)
  end

  def test_application_registration_preserves_the_stock_drivers
    assert_instance_of Capybara::Cuprite::Driver, Capybara.drivers[:cuprite].call(nil)
    assert_instance_of Capybara::Lightpanda::Driver, Capybara.drivers[:lightpanda].call(nil)
    @page.visit("/")
    @page.fill_in("Name", with: "Ada")
    assert_equal "Ada", @page.find_field("Name").value
    assert_equal [900, 700], @page.current_window.size
  end

  def echoed_headers
    @page.visit("/headers")
    JSON.parse(@page.find("pre").text)
  end

  def test_request_headers_reach_the_server_and_reset_between_examples
    headers = @page.driver.browser.headers
    headers.set("X-First" => "1")
    headers.add({ "X-Second" => "2" })
    assert_equal %w[1 2], echoed_headers.values_at("HTTP_X_FIRST", "HTTP_X_SECOND")
    headers.set("X-Third" => "3")
    assert_nil echoed_headers["HTTP_X_FIRST"]
    assert_equal({ "X-Third" => "3" }, headers.get)
    headers.clear
    assert_empty headers.get
    headers.set("X-Third" => "3")
    @page.reset_session!
    assert_nil echoed_headers["HTTP_X_THIRD"]
  end

  def test_browser_identity_matches_the_request
    headers = @page.driver.browser.headers
    headers.set("User-Agent" => "TestAgent/1", "Accept-Language" => "fr-FR")
    received = echoed_headers
    assert_equal "TestAgent/1", received["HTTP_USER_AGENT"]
    assert_includes received["HTTP_ACCEPT_LANGUAGE"], "fr-FR"
    assert_equal %w[TestAgent/1 fr-FR], @page.evaluate_script("[navigator.userAgent, navigator.language]")
  end

  def test_navigation_only_referer_is_excluded_from_persistent_headers
    @page.visit("/")
    source = "#{@page.current_url}source"
    @page.driver.add_header("Referer", source, permanent: false)
    assert_equal source, echoed_headers["HTTP_REFERER"]
    refute @page.driver.browser.headers.get.key?("Referer")
  end

  def test_login_cookie_before_visit_and_scoped_cookie_removal
    jar = @page.driver.browser.cookies
    assert jar.set({ name: "session", value: "before", httponly: true, samesite: "Lax" })
    assert_includes echoed_headers.fetch("HTTP_COOKIE"), "session=before"
    cookie = jar.all.fetch("session")
    assert jar.set(cookie), "a saved cookie can be reapplied to the browser"
    assert cookie.httponly?
    assert_equal "Lax", cookie.samesite

    jar.set(name: "session", value: "scoped", path: "/account")
    assert_equal %w[before scoped], jar.select { |item| item.name == "session" }.map(&:value).sort
    jar.remove(name: "session", path: "/account")
    assert_equal ["before"], jar.select { |item| item.name == "session" }.map(&:value)
    assert_equal "before", jar["session"].value
    @page.reset_session!
    assert_nil @page.driver.browser.cookies["session"]
  end

  def test_copied_remote_and_chrome_options_fail_before_launch
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, url: "http://remote") }
    assert_includes error.message, "ws_url:"
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, proxy: {}) }
    assert_includes error.message, ":proxy"
  end
end
