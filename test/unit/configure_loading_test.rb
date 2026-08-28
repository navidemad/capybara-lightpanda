# frozen_string_literal: true

require_relative "../test_helper"

# Pins the exact params of the LP.configureLoading call.
#
# The feature test (test/features/frame_loading_test.rb) proves iframes work,
# but it cannot discriminate below build 8946 — iframes defaulted on there, so
# it passes whether or not the call is made. This file holds the wiring itself,
# on every build: the command name, and both flags being explicitly true.
#
# `worker: true` matters as much as `subFrame: true` and is easier to drop by
# accident, since nothing in the suite fails without it until an app under test
# happens to use a Web Worker.
describe "Capybara::Lightpanda::Browser#configure_loading" do
  let(:client) { mock("client") }

  # Browser#initialize starts a session; the subject is one private step of it.
  def browser
    b = Capybara::Lightpanda::Browser.allocate
    b.instance_variable_set(:@client, client)
    b.instance_variable_set(:@session_id, "SESSION-1")
    b
  end

  it "asks the browser to keep loading iframes and workers" do
    client.expects(:command)
          .with("LP.configureLoading", { subFrame: true, worker: true }, session_id: "SESSION-1")
          .returns({})

    browser.send(:configure_loading)
  end

  # Not rescued on purpose: LP.configureLoading predates the floor by a wide
  # margin, so a failure means the endpoint is not a Lightpanda we understand.
  # Swallowing it would restore the silence the call exists to prevent.
  it "does not swallow a failure" do
    client.expects(:command).raises(Capybara::Lightpanda::BrowserError, "'LP.configureLoading' wasn't found")

    assert_raises(Capybara::Lightpanda::BrowserError) { browser.send(:configure_loading) }
  end
end
