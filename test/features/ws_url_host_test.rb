# frozen_string_literal: true

require_relative "../test_helper"

# The CDP WebSocket handshake's `Host` allowlist, upstream #3173 + #3256.
#
# #3173 (build >= 8651) hardened the CDP endpoint against DNS rebinding: an
# upgrade request carrying any `Origin` header is 403'd, and `Host` had to be
# an IP literal — a *name* reaching the server means something answered a DNS
# lookup with its address, which is what a rebinding attack looks like. That
# rejected `localhost` too, so a user-supplied `ws_url:` had to say 127.0.0.1.
#
# #3256 (build >= 8875, the current floor) carves out the one name browsers
# hardwire to loopback without a DNS lookup: the exact lowercase
# `localhost:<port>` form. Bare `localhost`, `LOCALHOST:<port>` and
# `localhost.evil.com:<port>` are still refused — those rejections are not
# pinned here because provoking them means owning a hostname that resolves to
# loopback, which a unit-ish suite cannot arrange portably.
#
# The gem's own spawn path never depended on either rule — it connects to the
# `address=` the server logs, which is always an IP literal, and
# websocket-driver 0.8.1 sends no Origin. This file covers the path a *user*
# takes: `ws_url:` pointing at an externally-managed Lightpanda. That option is
# the gem's only supported way to reach a browser it did not start, so a
# regression here breaks remote/containerised setups while every spawn-based
# test in the suite stays green.
describe "Capybara::Lightpanda ws_url host handling" do
  let(:session) { TestSessions::Lightpanda }

  # Both the browser process and the Capybara server have to be up before the
  # second connection can be made: one supplies the CDP endpoint to re-dial,
  # the other the origin to fetch. A visit is the cheapest way to guarantee it.
  before { session.visit("/lightpanda/simple") }
  after { session.reset_session! }

  it "connects over an explicit ws_url whose Host is localhost" do
    spawned_url = session.driver.browser.process.ws_url
    localhost_url = spawned_url.sub("127.0.0.1", "localhost")

    refute_equal spawned_url, localhost_url,
                 "expected the spawned ws_url to be an IP literal — got #{spawned_url}"

    # Reuses the already-running browser rather than spawning a second one:
    # what is under test is the handshake, not process management. Below 8875
    # `Client.new` raises here, because the server 403s the upgrade before any
    # CDP traffic flows.
    driver = Capybara::Lightpanda::Driver.new(TestApp, ws_url: localhost_url, timeout: 10)

    begin
      # Absolute URL on purpose: a driver built directly (rather than through a
      # Capybara::Session) has no server of its own to resolve a relative path
      # against, and would silently sit on about:blank.
      driver.visit("#{session.server.base_url}/lightpanda/simple")

      assert_includes driver.html, "Simple Page"
    ensure
      driver.quit
    end
  end
end
