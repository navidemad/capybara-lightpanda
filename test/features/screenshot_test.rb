# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

# Page.captureScreenshot. Since #3231 (build >= 8815, under the floor)
# Lightpanda renders the document for real — a text-layout render, not
# compositor output, so the bytes depend on page content; the pre-8815
# placeholder was one constant PNG regardless of page. The gem was already
# wired (Driver#save_screenshot -> Browser#screenshot ->
# Page.captureScreenshot, plus the `render` alias for capybara-screenshot);
# these tests pin the rendered-for-real contract.
describe "Capybara::Lightpanda screenshots" do
  let(:png_signature) { "\x89PNG\r\n\x1A\n".b }
  let(:session) { TestSessions::Lightpanda }
  let(:browser) { session.driver.browser }

  after { session.reset_session! }

  # The response must be a decodable PNG written where asked —
  # capybara-screenshot depends on it.
  it "save_screenshot writes a valid PNG" do
    session.visit("/lightpanda/simple")

    path = File.join(Dir.mktmpdir, "shot.png")
    session.save_screenshot(path)

    assert File.exist?(path), "expected #{path} to be written"
    assert_equal png_signature, File.binread(path)[0, 8], "expected a PNG signature"
  end

  # Content-dependent bytes are the proof of real rendering — dimensions
  # alone can't tell, since the default capture is viewport-sized either way.
  it "renders page content (different pages, different bytes)" do
    session.visit("/lightpanda/simple")
    first = browser.screenshot
    session.visit("/lightpanda/links")
    second = browser.screenshot

    assert_equal png_signature, first[0, 8]
    refute_equal first, second,
                 "expected content-dependent screenshot bytes (#3231); " \
                 "identical bytes mean the constant pre-8815 placeholder"
  end
end
