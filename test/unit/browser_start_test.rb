# frozen_string_literal: true

require_relative "../test_helper"

# Issue #219. Browser#start brings the process and the CDP connection up
# before the steps that can still fail (the ws_url version floor, creating the
# context and the page). An exception there escapes Browser.new, so nobody
# holds the object to quit it: the process kept running, the socket and its
# two threads stayed open, and the next attempt competed with the orphan for
# the port. A failed start must leave nothing behind.
describe "Capybara::Lightpanda::Browser#start failure" do
  let(:process) { mock("Process") }
  let(:client) { mock("Client") }

  before do
    process.stubs(:start)
    process.stubs(:ws_url).returns("ws://127.0.0.1:9222/")
    Capybara::Lightpanda::Process.stubs(:new).returns(process)
    Capybara::Lightpanda::Client.stubs(:new).returns(client)
  end

  it "stops the process and closes the connection when creating the context fails" do
    client.stubs(:command).with("Target.createBrowserContext")
          .raises(Capybara::Lightpanda::TimeoutError, "Command Target.createBrowserContext timed out")
    client.expects(:close)
    process.expects(:stop)

    assert_raises(Capybara::Lightpanda::TimeoutError) { Capybara::Lightpanda::Browser.new }
  end

  it "closes the connection to a ws_url browser below the version floor" do
    Capybara::Lightpanda::Process.expects(:new).never
    client.stubs(:command).with("LP.version").returns({ "version" => "0.3.7" })
    client.expects(:close)

    assert_raises(Capybara::Lightpanda::BinaryError) do
      Capybara::Lightpanda::Browser.new(ws_url: "ws://127.0.0.1:9222/")
    end
  end

  it "is not tracked for at_exit teardown" do
    client.stubs(:command).raises(Capybara::Lightpanda::TimeoutError, "slow")
    client.stubs(:close)
    process.stubs(:stop)
    Capybara::Lightpanda::Browser.expects(:track).never

    assert_raises(Capybara::Lightpanda::TimeoutError) { Capybara::Lightpanda::Browser.new }
  end
end
