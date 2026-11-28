# frozen_string_literal: true

require_relative "../test_helper"

# One message-size cap for both directions of the CDP socket, and an error that
# names it when a message crosses it.
#
# WHY THIS MATTERS: the gem lifts Lightpanda's inbound cap to 100 MiB, but the
# reader kept websocket-driver's 64 MiB default. A 70 MiB result (a big
# evaluate, page HTML, a data URL) closed the socket with "Browser closed during
# Runtime.evaluate", then "WebSocket is not open" for every later call: it read
# as a browser crash, and nothing pointed at a size limit (rubycdp/ferrum#739).
class MessageSizeLimitTest < Minitest::Test
  MIB = 1024 * 1024

  def setup
    bin = ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    @browser = Capybara::Lightpanda::Browser.new(browser_path: bin, port: rand(9600..9699), timeout: 60)
    @browser.go_to("about:blank")
  end

  def teardown
    @browser&.quit
  end

  def test_a_result_between_64_and_100_mib_arrives
    result = @browser.evaluate("'x'.repeat(#{70 * MIB})")

    assert_equal 70 * MIB, result.bytesize
    assert_equal 2, @browser.evaluate("1 + 1"), "the session must survive a large result"
  end

  def test_a_result_over_the_limit_names_the_receive_limit_then_and_after
    error = assert_raises(Capybara::Lightpanda::DeadBrowserError) do
      @browser.evaluate("'x'.repeat(#{101 * MIB})")
    end
    assert_match(/Runtime\.evaluate: Browser sent a message larger than the 100 MiB receive limit/, error.message)

    later = assert_raises(Capybara::Lightpanda::DeadBrowserError) { @browser.evaluate("1") }
    assert_match(/100 MiB receive limit/, later.message)
  end

  def test_a_message_the_browser_refuses_names_its_inbound_cap
    error = assert_raises(Capybara::Lightpanda::DeadBrowserError) do
      @browser.evaluate("arguments[0].length", "x" * (101 * MIB))
    end
    assert_match(/Browser refused a message larger than its 100 MiB --cdp-max-message-size/, error.message)
  end
end
