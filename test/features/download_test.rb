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
  describe "native anchor downloads" do
    before do
      browser = session.driver.browser
      available = if browser.nightly_build
                    browser.nightly_build >= Gem::Version.new("11097")
                  else
                    browser.release >= Gem::Version.new("1.1.0")
                  end
      skip "native anchor downloads need Lightpanda build 11097" unless available
    end

    it "downloads data without navigating and runs each click handler exactly once" do
      session.execute_script(<<~JS)
        var link = document.getElementById('dl');
        link.href = 'data:text/plain,downloaded-bytes';
        link.download = 'plain.txt';
        window.events = [];
        ['mousedown', 'mouseup', 'click'].forEach(function(type) {
          link.addEventListener(type, function() { window.events.push(type); });
        });
      JS
      original_url = session.current_url

      session.click_link("Download report")
      session.driver.wait_for_download(timeout: 3)

      assert_equal original_url, session.current_url
      assert_equal "downloaded-bytes", File.read(File.join(Capybara.save_path, "plain.txt"))
      assert_equal 1, session.driver.browser.downloads.started_count
      assert_equal %w[mousedown mouseup click], session.evaluate_script("window.events")
    end

    it "honors cancellation without navigating or downloading" do
      session.execute_script(<<~JS)
        var link = document.getElementById('dl');
        link.href = 'data:text/plain,cancelled';
        link.download = 'cancelled.txt';
        window.clicks = 0;
        link.addEventListener('click', function(event) {
          window.clicks++;
          event.preventDefault();
        });
      JS
      original_url = session.current_url

      session.click_link("Download report")
      session.driver.wait_for_download(timeout: 1)

      assert_equal original_url, session.current_url
      assert_empty session.driver.downloads
      assert_equal 1, session.evaluate_script("window.clicks")
    end

    it "activates the download when the clicked target is a child of the link" do
      session.execute_script(<<~JS)
        var link = document.getElementById('dl');
        link.href = 'data:text/plain,child-bytes';
        link.download = 'child.txt';
        link.innerHTML = '<span id="child">Download</span>';
      JS
      original_url = session.current_url

      session.find("#child").click
      session.driver.wait_for_download(timeout: 3)

      assert_equal original_url, session.current_url
      assert_equal "child-bytes", File.read(File.join(Capybara.save_path, "child.txt"))
      assert_equal 1, session.driver.browser.downloads.started_count
    end
  end
end
