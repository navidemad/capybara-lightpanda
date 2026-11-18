# frozen_string_literal: true

require_relative "../test_helper"

class CupritePageTest < Minitest::Test
  def setup
    # These guards must run before sending any command on the shared connection.
    browser = Struct.new(:client, :session_id, :options).new(nil, "session", Capybara::Lightpanda::Options.new(
                                                                               ws_url: "ws://localhost:9222"
                                                                             ))
    @page = Capybara::Lightpanda::CupritePage.new(browser)
  end

  def test_timezone_commands_cannot_change_another_remote_connections_zone
    assert_raises(Capybara::NotSupportedByDriverError) do
      @page.command("Emulation.setTimezoneOverride", timezoneId: "Asia/Tokyo")
    end
  end

  def test_ferrum_transport_options_are_not_forwarded_as_protocol_arguments
    %i[wait timeout slowmoable].each do |option|
      assert_raises(Capybara::NotSupportedByDriverError) do
        @page.command("Runtime.evaluate", expression: "1", option => 1)
      end
    end
  end
end
