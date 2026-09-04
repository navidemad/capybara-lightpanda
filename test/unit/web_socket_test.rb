# frozen_string_literal: true

require_relative "../test_helper"
require "socket"
require "digest"
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

  # A completed handshake whose reader then hits an error outside the narrow
  # IO rescue. With abort_on_exception that error was re-raised on the main
  # thread — wherever it happened to be — and took the process down. The
  # reader must instead mark the connection dead so the next send raises
  # DeadBrowserError (ferrum #632).
  it "marks the connection dead instead of aborting the process when the reader raises unexpectedly" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    go = Queue.new
    done = Queue.new
    accepter = serve_once(server) do |sock|
      request = +""
      request << sock.readpartial(4096) until request.include?("\r\n\r\n")
      key = request[/Sec-WebSocket-Key: (\S+)/, 1]
      accept = Digest::SHA1.base64digest("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      sock.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
      # Hold the socket open until the client has armed its failure, then
      # send one byte for the reader to parse. A fixed sleep here raced the
      # handshake under suite load.
      go.pop
      sock.write("x")
      done.pop
      sock.close
    end

    ws = Capybara::Lightpanda::Client::WebSocket.new("ws://127.0.0.1:#{port}/", options)
    driver = ws.instance_variable_get(:@driver)
    def driver.parse(_data) = raise(Errno::ETIMEDOUT)

    _out, err = capture_io do
      go << true
      deadline = Time.now + 2
      sleep 0.05 until ws.closed? || Time.now > deadline
    end
    done << true

    assert_predicate ws, :closed?
    assert_match(/reader died.*ETIMEDOUT/, err)
    assert_raises(Capybara::Lightpanda::DeadBrowserError) { ws.send_message("{}") }
  ensure
    accepter&.join
    server&.close
  end
end
