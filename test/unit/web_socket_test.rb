# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/options"
require "capybara/lightpanda/client/web_socket"

# A handshake cut mid-flight must surface as DeadBrowserError — part of the
# gem's BrowserError family that Driver and callers rescue — never as a raw
# Errno/EOFError that bypasses every rescue path and reaches the user as an
# unclassified exception.
describe Capybara::Lightpanda::Client::WebSocket do
  let(:options) { Capybara::Lightpanda::Options.new(handshake_timeout: 2) }

  def serve_once(server, &block)
    Thread.new do
      sock = server.accept
      block.call(sock)
    end
  end

  it "raises DeadBrowserError when the server closes during the handshake (FIN → EOFError)" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepter = serve_once(server) do |sock|
      sock.readpartial(4096) # consume the HTTP upgrade request
      sock.close             # FIN: client's readpartial raises EOFError
    end

    error = assert_raises(Capybara::Lightpanda::DeadBrowserError) do
      Capybara::Lightpanda::Client::WebSocket.new("ws://127.0.0.1:#{port}/", options)
    end
    assert_match(/handshake/i, error.message)
  ensure
    accepter&.join
    server&.close
  end

  it "raises DeadBrowserError when the server resets the connection (RST → ECONNRESET)" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepter = serve_once(server) do |sock|
      sock.readpartial(4096)
      # SO_LINGER(on, 0): close sends RST instead of FIN, so the client's
      # readpartial raises Errno::ECONNRESET — the case that used to leak raw.
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      sock.close
    end

    assert_raises(Capybara::Lightpanda::DeadBrowserError) do
      Capybara::Lightpanda::Client::WebSocket.new("ws://127.0.0.1:#{port}/", options)
    end
  ensure
    accepter&.join
    server&.close
  end
end
