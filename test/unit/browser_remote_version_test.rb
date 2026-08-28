# frozen_string_literal: true

require_relative "../test_helper"

# The version floor on the `ws_url:` path.
#
# The spawn path runs `lightpanda version` before the browser is up. Connecting
# to an externally-managed browser has no binary to shell out to, so for a long
# time `ws_url:` was the one entrance to the driver with no floor check at all:
# a browser below the floor connected happily, and the missing feature surfaced
# later as a CDP error that named neither the version nor the option that let it
# through. Browser#check_remote_version closes that hole over CDP.
#
# Exercised against a stubbed client on purpose: what is under test is the
# policy and the error mapping, both of which have to hold for browsers this
# suite cannot spawn (one below the floor, and one that is not Lightpanda at
# all). The wiring — that #start actually calls this against a live endpoint —
# is pinned by test/features/ws_url_version_test.rb.
describe "Capybara::Lightpanda::Browser ws_url version floor" do
  let(:floor) { Capybara::Lightpanda::Process::MINIMUM_NIGHTLY_BUILD }
  let(:ws_url) { "ws://192.0.2.10:9222/" }
  let(:client) { mock("client") }

  # Browser#initialize starts a whole session; the subject here is one private
  # step of it, so the object is built without running it.
  def browser
    b = Capybara::Lightpanda::Browser.allocate
    b.instance_variable_set(:@client, client)
    b.instance_variable_set(:@options, Capybara::Lightpanda::Options.new(ws_url: ws_url))
    b.instance_variable_set(:@process, nil)
    b
  end

  it "reads the version over CDP and exposes it like the spawn path does" do
    client.expects(:command).with("LP.version").returns({ "version" => "1.0.0-nightly.#{floor}+abc1234" })

    b = browser
    b.send(:check_remote_version)

    assert_equal "1.0.0-nightly.#{floor}+abc1234", b.version
    assert_equal floor, b.nightly_build
    assert_nil b.release, "a nightly carries no release tag"
  end

  # The reason the whole file exists: below the floor the connection has to fail
  # here, naming the version, rather than somewhere downstream naming nothing.
  it "refuses a browser below the floor" do
    client.expects(:command).with("LP.version").returns({ "version" => "1.0.0-nightly.6352+abc1234" })

    error = assert_raises(Capybara::Lightpanda::BinaryError) { browser.send(:check_remote_version) }

    assert_includes error.message, "1.0.0-nightly.6352"
    assert_includes error.message, "nightly build >= #{floor}"
  end

  it "refuses a tagged release below the floor" do
    client.expects(:command).with("LP.version").returns({ "version" => "0.3.7" })

    error = assert_raises(Capybara::Lightpanda::BinaryError) { browser.send(:check_remote_version) }

    assert_includes error.message, "release >= #{Capybara::Lightpanda::Process::MINIMUM_RELEASE}"
  end

  # Binary.update_hint prints a curl into a path the gem controls. Under ws_url
  # the browser belongs to someone else, possibly on another host, so following
  # that hint would overwrite an unrelated binary and leave the real one stale.
  it "does not tell the user to curl over a binary it does not manage" do
    client.expects(:command).with("LP.version").returns({ "version" => "1.0.0-nightly.6352" })

    error = assert_raises(Capybara::Lightpanda::BinaryError) { browser.send(:check_remote_version) }

    refute_includes error.message, "curl"
    assert_includes error.message, "does not manage"
  end

  # A browser that cannot answer LP.version is not one the gem can vouch for:
  # a Lightpanda predating the LP domain, or — easy to do, and previously
  # diagnosable only by watching later commands fail — a Chrome. Chrome answers
  # the handshake and then rejects the unknown method, which Client#handle_error
  # turns into a BrowserError.
  it "refuses an endpoint that cannot answer LP.version" do
    client.expects(:command).with("LP.version")
          .raises(Capybara::Lightpanda::BrowserError, "'LP.version' wasn't found")

    error = assert_raises(Capybara::Lightpanda::BinaryError) { browser.send(:check_remote_version) }

    assert_includes error.message, ws_url, "the message must name the endpoint that failed"
    assert_includes error.message, "LP.version"
  end

  it "refuses an endpoint that never answers" do
    client.expects(:command).with("LP.version")
          .raises(Capybara::Lightpanda::TimeoutError, "Command LP.version timed out after 15s")

    assert_raises(Capybara::Lightpanda::BinaryError) { browser.send(:check_remote_version) }
  end
end
