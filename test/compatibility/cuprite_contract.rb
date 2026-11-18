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
    case env["PATH_INFO"]
    when "/redirect"
      next [302, { "location" => "/parent" }, []]
    when "/parent"
      next [200, { "content-type" => "text/html" }, ['<iframe src="/child"></iframe>']]
    when "/child"
      next [404, { "content-type" => "text/html" }, ["missing"]]
    when "/headers"
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
    @stream_started = Queue.new
    @release_stream = Queue.new
    app = lambda do |env|
      next APP.call(env) unless env["PATH_INFO"] == "/stream"

      body = Enumerator.new do |out|
        out << "first"
        @stream_started << true
        @release_stream.pop(timeout: 5)
        out << "last"
      end
      [200, { "content-type" => "text/plain" }, body]
    end
    @page = Capybara::Session.new(:store_system, app)
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

  def test_redirect_and_iframe_keep_distinct_responses
    @page.visit("/redirect")
    network = @page.driver.browser.network
    assert network.wait_for_idle(duration: 0.01)
    assert_equal 200, network.status
    assert_equal 200, network.response.status
    statuses = network.traffic.to_h { |hop| [URI(hop.request.url).path, hop.response&.status] }
    assert_equal [302, 200, 404], statuses.values_at("/redirect", "/parent", "/child")
    assert_equal statuses.keys, @page.driver.network_traffic(:all).map { |hop| URI(hop.request.url).path }.uniq
    network.clear(:cache)
    refute_empty network.traffic
    network.clear(:traffic)
    assert_empty network.traffic
    assert_equal 200, network.status
  end

  def test_idle_waits_for_the_response_body
    @page.visit("/")
    @page.execute_script("fetch('/stream').then(r => r.text()); void 0")
    assert @stream_started.pop(timeout: 5), "the server must start streaming"
    network = @page.driver.browser.network
    refute network.wait_for_idle(timeout: 0.05, duration: 0.01)
    @release_stream << true
    assert network.wait_for_idle(timeout: 3, duration: 0.01)
    stream = network.traffic.find { |hop| URI(hop.request.url).path == "/stream" }
    assert_predicate stream, :finished?
  ensure
    @release_stream << true
  end

  def test_failed_fetch_releases_the_idle_wait
    @page.visit("/")
    @page.evaluate_async_script("fetch('http://127.0.0.1:1/closed').catch(arguments[0])")
    network = @page.driver.browser.network
    assert network.wait_for_idle(timeout: 2, duration: 0.01)
    failed = network.traffic.find { |hop| hop.request&.url&.end_with?("/closed") }
    assert_predicate failed, :finished?
    assert failed.error
  end

  def test_copied_remote_and_chrome_options_fail_before_launch
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, url: "http://remote") }
    assert_includes error.message, "ws_url:"
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, proxy: {}) }
    assert_includes error.message, ":proxy"
  end
end
