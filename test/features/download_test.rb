# frozen_string_literal: true

require_relative "../test_helper"

# File downloads via Browser.setDownloadBehavior (upstream PR #2722, build
# >= 7545, guaranteed by MINIMUM_NIGHTLY_BUILD).
#
# Capybara's own `:download` shared example (click_link_spec "can download a
# file") stays in capybara_skip: its /download.csv fixture sends `text/csv`
# with NO Content-Disposition, relying on MIME-type-triggered download. Lightpanda
# only downloads on `Content-Disposition: attachment` (it renders any other
# response as a normal navigation), so that spec can't pass. This test exercises
# the real, supported path: an attachment response streamed to Capybara.save_path.
describe "Capybara::Lightpanda downloads" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/download_page") }
  after { session.reset_session! }

  def downloaded_file
    File.join(Capybara.save_path, "report.csv")
  end

  it "streams a Content-Disposition attachment to save_path" do
    refute File.exist?(downloaded_file), "precondition: file must not exist yet"

    session.click_link("Download report")
    session.driver.wait_for_download(timeout: 5)

    assert File.exist?(downloaded_file), "expected #{downloaded_file} to be written"
    assert_includes File.read(downloaded_file), "lightpanda,100"
  end

  it "records the completed download on the driver" do
    session.click_link("Download report")
    session.driver.wait_for_download(timeout: 5)

    assert_includes session.driver.downloads, downloaded_file
  end
end
