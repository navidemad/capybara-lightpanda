# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

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
  APP = lambda do |_env|
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

  def test_copied_remote_and_chrome_options_fail_before_launch
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, url: "http://remote") }
    assert_includes error.message, "ws_url:"
    error = assert_raises(ArgumentError) { Capybara::Lightpanda.register_cuprite_driver(:remote, proxy: {}) }
    assert_includes error.message, ":proxy"
  end
end
