# frozen_string_literal: true

# Run with bundle exec ruby script/audit_websocket.rb, or with JRuby and the
# websocket-driver gem installed. An idle reader must not prevent another
# thread from writing; protocol pongs must also survive concurrent senders.
require "socket"
require "json"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "capybara/lightpanda/errors"
require "capybara/lightpanda/options"
require "capybara/lightpanda/client/web_socket"

AuditWebSocketPeer = Struct.new(:socket) do
  def write(data) = socket.write(data)
end

watchdog = Thread.new do
  sleep 10
  warn "WebSocket audit timed out: a reader/writer may be deadlocked"
  exit! 1
end

begin
  server = TCPServer.new("127.0.0.1", 0)
  peer_thread = Thread.new do
    sock = server.accept
    driver = WebSocket::Driver.server(AuditWebSocketPeer.new(sock))
    driver.on(:connect) { driver.start }
    driver.on(:message) do |event|
      driver.text(event.data)
      driver.ping("alive")
    end
    loop { driver.parse(sock.readpartial(4096)) }
  rescue IOError, Errno::ECONNRESET
    nil
  ensure
    sock&.close
  end

  options = Capybara::Lightpanda::Options.new(timeout: 2)
  ws = Capybara::Lightpanda::Client::WebSocket.new("ws://127.0.0.1:#{server.addr[1]}/", options)
  sleep 0.15 # let the reader park before the first application write
  received = Queue.new
  senders = 4.times.map do |worker|
    Thread.new do
      25.times do |n|
        ws.send_message(JSON.generate(id: (worker * 25) + n), timeout: 2)
        received << ws.messages.pop
      end
    end
  end
  senders.each(&:join)
  ids = 100.times.map { received.pop.fetch("id") }
  raise "lost or duplicated messages" unless ids.uniq.length == 100

  puts JSON.generate(engine: RUBY_ENGINE, ruby: RUBY_VERSION,
                     messages: ids.length, handshake: "ok", concurrent_writes_and_pongs: "ok")
ensure
  ws&.close
  senders&.each(&:kill)
  peer_thread&.kill
  peer_thread&.join
  server&.close
  watchdog.kill
  watchdog.join
end
