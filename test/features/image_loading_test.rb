# frozen_string_literal: true

require_relative "../test_helper"

# The `load_images` option -> `--load-resources image` (upstream #3230,
# build >= 8834, under the floor). Lightpanda's default never fetches
# `<img>` resources — a deliberate bandwidth choice the gem preserves — so
# both directions matter:
# the default must stay quiet, and opting in must make image requests ride
# the Network domain like any other (visible in `network.traffic`, counted
# by `wait_for_network_idle`).
describe "Capybara::Lightpanda image loading" do
  Capybara.register_driver(:lightpanda_load_images) do |app|
    Capybara::Lightpanda::Driver.new(
      app,
      timeout: 10,
      load_images: true,
      browser_path: ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    )
  end

  # Owns its own Lightpanda process (the flag is per-process), memoized for
  # the file. `--load-resources` is a fatal UnknownOption below build 8834,
  # which MINIMUM_NIGHTLY_BUILD now excludes, so the flagged session always
  # boots.
  def self.images_session
    @images_session ||= Capybara::Session.new(:lightpanda_load_images, TestApp)
  end

  Minitest.after_run { @images_session&.driver&.quit }

  let(:session) { TestSessions::Lightpanda }

  # Guards the default: wiring the option up must not have flipped image
  # fetching on for everyone.
  it "does not request <img> resources by default" do
    session.driver.browser.network.enable
    session.visit("/lightpanda/links")
    session.driver.wait_for_network_idle

    urls = session.driver.network.traffic.map { |t| t[:url] }
    refute urls.any? { |u| u.include?("/lightpanda/image.png") },
           "expected no image request without load_images, got #{urls.inspect}"
  ensure
    session.driver.browser.network.disable
    session.reset_session!
  end

  it "requests <img> resources and tracks them in network traffic when enabled" do
    images = self.class.images_session
    images.driver.browser.network.enable
    images.visit("/lightpanda/links")
    images.driver.wait_for_network_idle

    urls = images.driver.network.traffic.map { |t| t[:url] }
    assert urls.any? { |u| u.include?("/lightpanda/image.png") },
           "expected an image request with load_images: true, got #{urls.inspect}"
  ensure
    if self.class.instance_variable_get(:@images_session)
      images = self.class.images_session
      images.driver.browser.network.disable
      images.reset_session!
    end
  end
end
