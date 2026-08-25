# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

# Page.captureScreenshot. Below build 8815 Lightpanda returns a constant
# placeholder PNG (hardcoded 1920x1080, nothing rendered); since #3231
# (>= 8815) it renders the document for real — a text-layout render, not
# compositor output, so the bytes depend on page content. The gem was
# already wired (Driver#save_screenshot -> Browser#screenshot ->
# Page.captureScreenshot, plus the `render` alias for capybara-screenshot);
# these tests pin the contract on both sides of 8815.
describe "Capybara::Lightpanda screenshots" do
  let(:png_signature) { "\x89PNG\r\n\x1A\n".b }
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  # True on every supported build: placeholder or real, the response must be
  # a decodable PNG written where asked — capybara-screenshot depends on it.
  it "save_screenshot writes a valid PNG" do
    session.visit("/lightpanda/simple")

    path = File.join(Dir.mktmpdir, "shot.png")
    session.save_screenshot(path)

    assert File.exist?(path), "expected #{path} to be written"
    assert_equal png_signature, File.binread(path)[0, 8], "expected a PNG signature"
  end

  # The behavioral difference of #3231: the placeholder was one constant PNG
  # regardless of page, so content-dependent bytes are the proof of real
  # rendering (dimensions alone can't tell — the default capture is
  # viewport-sized either way).
  it "renders page content on >= 8815 (different pages, different bytes)" do
    build = browser.nightly_build
    unless build && build >= Gem::Version.new("8815")
      skip "needs Lightpanda nightly >= 8815 (real captureScreenshot, #3231); " \
           "running #{browser.version}"
    end

    session.visit("/lightpanda/simple")
    first = browser.screenshot
    session.visit("/lightpanda/links")
    second = browser.screenshot

    assert_equal png_signature, first[0, 8]
    refute_equal first, second,
                 "expected content-dependent screenshot bytes on >= 8815 " \
                 "(the pre-8815 placeholder is constant)"
  end
end
