# frozen_string_literal: true

require "minitest/autorun"
require_relative "session_isolation"
require "capybara-lightpanda"
require "selenium-webdriver"
require "tmpdir"

class SeleniumContractTest < Minitest::Test
  include SessionIsolationContract

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
        Capybara::Lightpanda::Driver.new(app, save_path: @default_directory, raise_on_unhandled_modal: true,
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

  # Solidus's order page asserts have_content("Tracking Number FOOBAR") across
  # a <th>/<td> row. WebDriver's text separates table cells with a space.
  def test_table_row_text_reads_cells_with_a_space
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<table><tr id="tracking"><th>Tracking Number</th><td>FOOBAR</td></tr></table>';
    JS
    assert_equal "Tracking Number FOOBAR", @page.find("#tracking").text
    assert @page.has_content?("Tracking Number FOOBAR", wait: 0)
  end

  def test_picture_overlay_keyboard_shortcuts_use_focus_at_perform_time
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<button id="picture">Open picture</button>';
      window.keys = [];
      document.onkeydown = e => window.keys.push([e.target.id, e.key, e.code]);
      document.querySelector('button').onclick = () => document.body.dataset.open = 'yes';
    JS
    actions = @browser.action
    actions.send_keys(:arrow_right).send_keys(:arrow_left)
    @page.execute_script("document.querySelector('button').focus()")
    assert_empty @page.evaluate_script("window.keys")
    assert_nil actions.perform
    assert_equal [%w[picture ArrowRight ArrowRight], %w[picture ArrowLeft ArrowLeft]],
                 @page.evaluate_script("window.keys")

    actions.send_keys(:enter).perform
    assert_equal "yes", @page.evaluate_script("document.body.dataset.open")
    assert_equal [%w[ArrowRight ArrowRight], %w[ArrowLeft ArrowLeft], %w[Enter NumpadEnter]],
                 @page.evaluate_script("window.keys.map(e => e.slice(1))")
  end

  # Shared helpers pass Selenium's ActionBuilder keywords; a driver that
  # rejects them fails the helper before any key is sent.
  def test_action_takes_seleniums_keywords_and_rejects_unknown_ones
    @page.execute_script("window.keys = []; document.onkeydown = e => window.keys.push(e.key);")
    @browser.action(async: true, devices: [], duration: 0).send_keys(:arrow_down).perform
    assert_equal ["ArrowDown"], @page.evaluate_script("window.keys")
    assert_raises(ArgumentError) { @browser.action(asynchronous: true) }
  end

  # A typed "\n" is the Enter key in Chrome: `send_keys("query\n")` submits
  # the search form and runs Enter handlers. Inserted as text, the newline
  # vanished from the input and nothing submitted.
  def test_a_typed_newline_is_the_enter_key
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<form onsubmit="event.preventDefault(); document.body.dataset.submitted = \\'yes\\'">' +
        '<input id="query"><textarea id="notes"></textarea></form>';
      window.enters = [];
      document.addEventListener('keydown', e => { if (e.key === 'Enter') window.enters.push(e.target.id) });
    JS
    @page.find("#notes").send_keys("a\nb")
    assert_equal "a\nb", @page.find("#notes").value
    assert_nil @page.evaluate_script("document.body.dataset.submitted")

    @page.find("#query").send_keys("lightpanda\n")
    assert_equal "lightpanda", @page.find("#query").value
    assert_equal "yes", @page.evaluate_script("document.body.dataset.submitted")
    assert_equal %w[notes query], @page.evaluate_script("window.enters")
  end

  # A spec passing an Array to a single-value field has a bug; typing the
  # Array's inspect string into the field hid it. Selenium raises instead, and
  # a `multiple` file input still takes the Array.
  def test_an_array_on_a_field_without_multiple_raises_instead_of_typing_it
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<input id="tags"><textarea id="notes"></textarea><input id="files" type="file" multiple>';
    JS
    %w[#tags #notes].each do |field|
      error = assert_raises(ArgumentError) { @page.find(field).set(%w[a b]) }
      assert_match(/Value cannot be an Array when 'multiple' attribute is not present/, error.message)
      assert_equal "", @page.find(field).value
    end
    paths = [__FILE__, File.expand_path("session_isolation.rb", __dir__)]
    @page.find("#files").set(paths)
    assert_equal 2, @page.evaluate_script("document.getElementById('files').files.length")
  end

  def test_a_dialog_after_dispatch_does_not_replay_the_shortcut
    @page.execute_script(<<~JS)
      window.keys = [];
      document.onkeydown = e => {
        window.keys.push(e.key);
        if (window.keys.length === 1) alert("Picture opened");
      };
    JS
    actions = @browser.action
    assert_raises(Capybara::Lightpanda::UnhandledModalError, Selenium::WebDriver::Error::UnexpectedAlertOpenError) do
      actions.send_keys(:arrow_right).perform
      @page.evaluate_script("window.keys.length")
    end
    actions.perform
    assert_equal ["ArrowRight"], @page.evaluate_script("window.keys")
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

  def test_native_attribute_reads_form_validation_and_current_field_values
    @page.execute_script(<<~JS)
      document.body.innerHTML = '<input id="title" required value="draft" data-kind="title">' +
        '<select id="scope" required><option value="">Choose</option><option value="all">All</option></select>' +
        '<input id="consent" type="checkbox" checked><a id="export" href="">Export</a>';
      document.querySelector('#title').value = '';
      document.querySelector('#consent').checked = false;
    JS
    title = @page.find("#title").native
    %w[title scope].each do |id|
      message = @page.evaluate_script("document.getElementById(arguments[0]).validationMessage", id)
      refute_empty message
      assert_equal message, @page.find("##{id}").native.attribute("validationMessage")
    end
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
    # Teardown helpers print `entry.time`; on both drivers it must be now, not 1970.
    severe.each { |entry| assert_in_delta Time.now, entry.time, 60, entry.inspect }

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
