# frozen_string_literal: true

require_relative "../test_helper"
require "concurrent-ruby"
require "capybara/lightpanda/client"

# Constructing a real Client opens a WebSocket. For the close-time fail-fast
# behavior we only care about #fail_pending_commands operating on @pendings,
# so we bypass full init with `Client.allocate` + state injection.
describe Capybara::Lightpanda::Client do
  describe "#close fails pending commands fast" do
    let(:client) { Capybara::Lightpanda::Client.allocate }
    let(:pendings) { Concurrent::Hash.new }

    before do
      client.instance_variable_set(:@pendings, pendings)
    end

    it "resolves blocked IVars so callers fall through value!(timeout) immediately" do
      ivar = Concurrent::IVar.new
      pendings[1] = ivar

      # Before fix: the IVar stayed unresolved and a caller blocked here for
      # the full @options.timeout (often 30s) before raising DeadBrowserError.
      # After fix: try_set(nil) wakes the waiter; value!(short_timeout) returns
      # nil and the caller's @ws.closed? check raises immediately.
      waiter = Thread.new { ivar.value!(5) }

      client.send(:fail_pending_commands)

      assert_nil waiter.value
    end

    it "is a no-op for IVars that already carry a real response" do
      ivar = Concurrent::IVar.new
      response = { "id" => 1, "result" => { "ok" => true } }
      ivar.set(response)
      pendings[1] = ivar

      # try_set must not clobber a response that landed just before close.
      client.send(:fail_pending_commands)

      assert_equal response, ivar.value
    end

    it "handles an empty pendings hash" do
      client.send(:fail_pending_commands)
      pass
    end
  end
end
