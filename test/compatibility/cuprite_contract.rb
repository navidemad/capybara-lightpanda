# frozen_string_literal: true

require "minitest/autorun"
require_relative "session_isolation"
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
  include SessionIsolationContract

  APP = lambda do |env|
    case env["PATH_INFO"]
    when "/editor"
      next [200, { "content-type" => "text/html" }, [File.read(File.join(__dir__, "interactions.html"))]]
    when "/reports"
      next [200, { "content-type" => "text/html" }, ['<a href="/report.csv" download>Download report</a>']]
    when "/report.csv"
      next [200, { "content-type" => "text/csv", "content-disposition" => 'attachment; filename="report.csv"' },
            ["item,total\ncoffee,7\n"],]
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
    register_driver(:store_system, save_path: @directory, window_size: [900, 700])
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

  def register_driver(name, **options)
    if ENV.fetch("CONTRACT_DRIVER", "lightpanda") == "cuprite"
      options[:process_timeout] = 30
      options[:browser_path] = ENV["CHROME_BIN"] if ENV["CHROME_BIN"]
      Capybara.register_driver(name) { |app| Capybara::Cuprite::Driver.new(app, options) }
    else
      options[:browser_path] = ENV["LIGHTPANDA_BIN"] if ENV["LIGHTPANDA_BIN"]
      Capybara::Lightpanda.register_cuprite_driver(name, **options)
    end
  end

  def teardown
    @page.driver.quit
    FileUtils.remove_entry(@directory)
  end

  # Cuprite returns innerText's tab between table cells; Selenium a space
  # (selenium_contract.rb). Each registration matches its own reference.
  def test_table_row_text_keeps_the_tab_between_cells
    @page.visit("/")
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<table><tr id="total"><th>Total due</th><td>$0.00</td></tr></table>';
    JS
    assert_equal "Total due\t$0.00", @page.find("#total").text
    assert @page.has_content?("Total due\t$0.00", wait: 0)
  end

  def test_coordinate_mouse_input_for_chart_interactions
    @page.visit("/")
    @page.execute_script("window.addEventListener('mousemove', e => { window.lastPoint = [e.clientX, e.clientY] })")
    browser = @page.driver.browser
    move_to_tick = -> { browser.mouse.move(x: 75, y: 45) }

    if browser.is_a?(Capybara::Lightpanda::Browser)
      refute_respond_to browser, :mouse
      error = assert_raises(NoMethodError, &move_to_tick)
      assert_equal :mouse, error.name
      assert_same browser, error.receiver
      assert_match(/rendered layout.*Cuprite/, error.message)
      other = assert_raises(NoMethodError) { browser.missing_chart_helper }
      refute_match(/Cuprite/, other.message)
    else
      move_to_tick.call
      assert_equal [75, 45], @page.evaluate_script("window.lastPoint")
    end
  end

  def test_page_commands_switch_date_and_intl_without_replacing_the_document
    @page.visit("/")
    @page.fill_in("Name", with: "Unsaved")
    browser = @page.driver.browser
    current_zone = "Intl.DateTimeFormat().resolvedOptions().timeZone"
    original = @page.evaluate_script(current_zone)
    zone = original == "America/New_York" ? "America/St_Johns" : "America/New_York"
    method = "Emulation.setTimezoneOverride"
    if browser.is_a?(Capybara::Lightpanda::Browser)
      # Check the engine independently of the adapter. Older releases acknowledge
      # the raw CDP call even though Intl and Date keep the previous zone.
      browser.page_command(method, timezoneId: zone)
      supported = @page.evaluate_script(current_zone) == zone
      browser.page_command(method, timezoneId: "")
      unless supported
        assert_raises(Capybara::NotSupportedByDriverError) { browser.page.command(method, timezoneId: zone) }
        assert_equal original, @page.evaluate_script(current_zone)
        return
      end
    end

    { "America/New_York" => [300, 240], "America/St_Johns" => [210, 150] }.each do |id, offsets|
      browser.page.command(method, timezoneId: id)
      assert_equal id, @page.evaluate_script(current_zone)
      assert_equal offsets, @page.evaluate_script("[0, 6].map(m => new Date(Date.UTC(2024, m, 1)).getTimezoneOffset())")
    end
    browser.page.command(method, timezoneId: "GMT")
    assert_equal 0, @page.evaluate_script("new Date().getTimezoneOffset()")
    browser.page.command(method, timezoneId: "")
    assert_equal original, @page.evaluate_script(current_zone)
    assert_equal "Unsaved", @page.find_field("Name").value
  end

  def test_cached_page_handle_cannot_mutate_the_next_session
    @page.visit("/")
    cached = @page.driver.browser.page
    @page.reset!
    @page.visit("/")
    assert_raises(Ferrum::BrowserError, Capybara::Lightpanda::BrowserError) do
      cached.command("Runtime.evaluate", expression: "document.title = 'changed'")
    end
    assert_equal "Store", @page.title
  end

  def test_application_registration_preserves_the_stock_drivers
    assert_instance_of Capybara::Cuprite::Driver, Capybara.drivers[:cuprite].call(nil)
    assert_instance_of Capybara::Lightpanda::Driver, Capybara.drivers[:lightpanda].call(nil)
    @page.visit("/")
    @page.fill_in("Name", with: "Ada")
    assert_equal "Ada", @page.find_field("Name").value
    assert_equal [900, 700], @page.current_window.size
  end

  def test_refused_visit_raises_and_a_later_http_response_is_usable
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    url = "http://127.0.0.1:#{port}/unavailable"
    error = assert_raises(Ferrum::StatusError) { @page.visit(url) }
    refute_kind_of Ferrum::PendingConnectionsError, error
    assert_includes error.message, url

    @page.visit("/child")
    assert_equal 404, @page.status_code
    assert_equal "missing", @page.text
    @page.visit("/parent")
    assert_equal 200, @page.status_code
  end

  def test_disabled_debug_options_allow_headless_dashboard_navigation
    [nil, 0.0].each do |delay|
      register_driver(:dashboard, slowmo: delay, inspector: nil, browser_options: {}, headless: true)
      page = Capybara::Session.new(:dashboard, APP)
      page.visit("/")
      page.fill_in("Name", with: "GoodJob")
      assert_equal "GoodJob", page.find_field("Name").value
    ensure
      page&.driver&.quit
    end
  end

  def test_requested_debug_features_remain_explicit
    [{ slowmo: 0.5 }, { inspector: true }].each do |settings|
      error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:debug, **settings) }
      assert_includes error.message, settings.keys.first.to_s
    end
  end

  def test_forem_registration_allows_a_visit_to_return_while_a_script_is_pending
    register_driver(:better_cuprite, browser_options: {}, pending_connection_errors: false, timeout: 1)
    started = Queue.new
    release = Queue.new
    app = lambda do |env|
      if env["PATH_INFO"] == "/slow.js"
        started << true
        released = release.pop(timeout: 10)
        script = released ? "document.body.dataset.loaded = 'yes'" : ""
        [200, { "content-type" => "application/javascript" }, [script]]
      else
        [200, { "content-type" => "text/html" }, ['<body><script defer src="/slow.js"></script></body>']]
      end
    end
    page = Capybara::Session.new(:better_cuprite, app)
    page.visit("/")
    assert started.pop(timeout: 2), "the script must have reached the server"
    release << true
    assert page.has_selector?("body[data-loaded=yes]", visible: :all, wait: 5)
  ensure
    release&.push(true)
    page&.driver&.quit
  end

  def test_registration_rejects_custom_chrome_flags_and_required_pending_errors
    [{ browser_options: { proxy: "proxy.test" } }, { pending_connection_errors: true }].each do |settings|
      error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:custom, **settings) }
      assert_includes error.message, settings.keys.first.to_s
    end
  end

  def test_permanent_referer_replaces_the_navigation_only_referer
    @page.visit("/")
    headers = @page.driver.browser.headers
    base = @page.current_url
    headers.add({ "Referer" => "#{base}first" }, permanent: false)
    headers.add({ "Referer" => "#{base}second" })
    assert_equal "#{base}second", echoed_headers["HTTP_REFERER"]
    assert_equal "#{base}second", @page.evaluate_script("document.referrer")
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

  def test_removing_a_cookie_by_name_clears_every_path_on_its_host
    @page.visit("/")
    jar = @page.driver.browser.cookies
    jar.set(name: "account", value: "root", path: "/")
    jar.set(name: "account", value: "private", path: "/private")
    jar.set(name: "account", value: "other", domain: "other.example")
    jar.remove(name: "account")
    assert_equal ["other"], jar.select { |item| item.name == "account" }.map(&:value)
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

  def test_async_callbacks_follow_the_session_wait
    @page.visit("/")
    @page.using_wait_time(0.15) do
      assert_equal "done", @page.evaluate_async_script("arguments[1](arguments[0])", "done")
      assert_raises(Ferrum::ScriptTimeoutError, Capybara::Lightpanda::ScriptTimeoutError) do
        @page.evaluate_async_script("setTimeout(arguments[0], 800, 'late')")
      end
    end
    assert_equal 2, @page.evaluate_script("1 + 1"), "a missing callback leaves the browser usable"
  end

  def test_async_deadline_includes_a_promise_supplied_to_the_callback
    @page.visit("/")
    @page.using_wait_time(0.15) do
      assert_raises(Ferrum::ScriptTimeoutError, Capybara::Lightpanda::ScriptTimeoutError) do
        @page.evaluate_async_script("arguments[0](new Promise(resolve => setTimeout(resolve, 800, 'late')))")
      end
    end
  end

  def test_async_application_errors_reach_the_caller
    @page.visit("/")
    error = assert_raises(Ferrum::JavaScriptError, Capybara::Lightpanda::JavaScriptError) do
      @page.evaluate_async_script(<<~JS)
        throw new (class LightpandaCallbackTimeout extends Error {})('application rejected the edit');
      JS
    end
    assert_includes error.message, "application rejected the edit"
  end

  def test_wait_for_reload_observes_a_new_document_at_the_same_url
    @page.visit("/")
    @page.execute_script("window.oldDocument = true; setTimeout(() => location.reload(), 200)")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @page.driver.browser.wait_for_reload(5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
    assert_nil @page.evaluate_script("window.oldDocument"), "reload must replace the original document"
  end

  def test_reload_wait_wakes_for_same_document_navigation
    @page.visit("/")
    @page.execute_script("setTimeout(() => location.hash = 'summary', 200)")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @page.driver.browser.wait_for_reload(5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 4
    assert_equal "#summary", @page.evaluate_script("location.hash")
  end

  def test_driver_reload_wait_expires_without_reloading_the_page
    @page.visit("/")
    @page.execute_script("window.unsaved = 'draft'")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert @page.driver.wait_for_reload(0.15)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.12
    assert_equal "draft", @page.evaluate_script("window.unsaved")
  end

  def test_click_modifiers_reach_the_entire_mouse_sequence_and_reset
    @page.visit("/editor")
    button = @page.find_button("Select row")
    button.click(:shift, :alt)
    button.click
    expected = [%w[shift alt], []].flat_map do |modifiers|
      [["mousedown", modifiers, 0, 1, 1], ["mouseup", modifiers, 0, 0, 1], ["click", modifiers, 0, 0, 1]]
    end
    assert_equal expected, @page.evaluate_script("window.mouseEvents")
  end

  def test_secondary_click_handlers_receive_their_modifiers
    @page.visit("/editor")
    button = @page.find_button("Select row")
    button.right_click(:control, :alt)
    button.double_click(:meta)
    events = @page.evaluate_script("window.mouseEvents")
    right = %w[ctrl alt]
    double = %w[meta]
    expected = [
      ["mousedown", right, 2, 2, 1], ["contextmenu", right, 2, 2, 0], ["mouseup", right, 2, 0, 1],
      ["mousedown", double, 0, 1, 2], ["mouseup", double, 0, 0, 2],
      ["click", double, 0, 0, 2], ["dblclick", double, 0, 0, 2],
    ]
    assert_equal expected, events
  end

  def test_confirm_wrappers_choose_the_application_branch
    @page.visit("/editor")
    @page.dismiss_confirm("Discard changes?") { @page.click_button("Discard") }
    assert_equal "kept", @page.find("#decision").text
    @page.accept_confirm("Discard changes?") { @page.click_button("Discard") }
    assert_equal "discarded", @page.find("#decision").text
  end

  def test_fill_and_keyboard_helpers_drive_editor_state
    @page.visit("/editor")
    @page.fill_in("Title", with: "Draft")
    assert_equal "DRAFT", @page.find("#preview").text
    @page.find_field("Title").send_keys("!", :enter)
    assert_equal "DRAFT!", @page.find("#preview").text
    assert_equal "Draft!", @page.find("#saved").text
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

  def test_download_block_yields_once_and_waits_for_the_file
    @page.visit("/reports")
    calls = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @page.driver.browser.downloads.wait(3) do
      calls += 1
      @page.click_link("Download report")
    end
    # The wait ends when the download it started completes, not at the
    # deadline: a baseline taken after the block counts that download as
    # already begun and stalls the full 3 seconds.
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal 1, calls
    assert_equal "item,total\ncoffee,7\n", File.read(File.join(@directory, "report.csv"))
  end

  def test_block_wait_includes_a_download_started_asynchronously
    @page.visit("/reports")
    @page.driver.browser.downloads.wait(4) do
      @page.execute_script("setTimeout(() => document.querySelector('a').click(), 1250)")
    end
    assert_equal "item,total\ncoffee,7\n", File.read(File.join(@directory, "report.csv"))
  end

  def test_download_trigger_exceptions_reach_the_test
    error = assert_raises(RuntimeError) do
      @page.driver.browser.downloads.wait { raise "trigger failed" }
    end
    assert_equal "trigger failed", error.message
  end
end

# Cuprite 0.20.1 boots Chrome when an unused driver receives quit. These
# registration checks run without a session or browser teardown.
class CupriteRegistrationTest < Minitest::Test
  def test_registration_rejects_endpoints_the_transport_cannot_connect_to
    ["wss://remote.example", "ws://local host", "ws://host:99999", nil].each do |endpoint|
      assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, ws_url: endpoint) }
    end
    Capybara::Lightpanda.register_cuprite_driver(:remote, ws_url: "ws://localhost:9222/cdp")
    assert_equal "ws://localhost:9222/cdp", Capybara.drivers[:remote].call(nil).options[:ws_url]
  end

  def test_copied_remote_and_chrome_options_fail_before_launch
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, url: "http://remote") }
    assert_includes error.message, "ws_url:"
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, proxy: {}) }
    assert_includes error.message, ":proxy"
  end
end
