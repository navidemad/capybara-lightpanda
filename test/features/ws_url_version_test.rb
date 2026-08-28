# frozen_string_literal: true

require_relative "../test_helper"

# Pins the wiring: Browser#start asks an externally-managed browser for its
# version over CDP, the same way the spawn path shells out to
# `lightpanda version`.
#
# The policy those versions are judged against — floors, both channels, and the
# refusal of an endpoint that cannot answer LP.version — is unit-tested in
# test/unit/browser_remote_version_test.rb against a stubbed client, since a
# too-old browser is not something this suite can spawn. What only a live
# endpoint can prove is that #start makes the call at all, which is exactly the
# step that was missing: `ws_url:` used to reach a working session with
# #version, #nightly_build and #release all nil, and no floor enforced.
describe "Capybara::Lightpanda ws_url version reporting" do
  let(:session) { TestSessions::Lightpanda }

  # Both the browser process and the Capybara server have to be up before a
  # second connection can be made to the first one's CDP endpoint.
  before { session.visit("/lightpanda/simple") }
  after { session.reset_session! }

  it "learns the version over CDP for a browser it did not spawn" do
    spawned = session.driver.browser

    # Reuses the running browser rather than spawning a second one: the subject
    # is what a ws_url session learns about a browser, not process management.
    driver = Capybara::Lightpanda::Driver.new(TestApp, ws_url: spawned.process.ws_url, timeout: 10)

    begin
      browser = driver.browser

      assert_nil browser.process, "a ws_url session manages no process of its own"
      assert_equal spawned.version, browser.version,
                   "both sessions are talking to the same browser, so both must report its version"
      refute_nil browser.nightly_build || browser.release,
                 "the version has to be parsed into a channel, not just carried as a string"
    ensure
      driver.quit
    end
  end
end
