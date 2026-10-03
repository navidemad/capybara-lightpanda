# frozen_string_literal: true

require_relative "../test_helper"

# The CDP socket must be released when the browser died before we quit.
#
# WHY THIS MATTERS: a crashed browser makes the reader thread mark the
# connection dead without closing the socket, and Client::WebSocket#close used
# to return early on an already-dead connection — so every crash (and every
# crash-recovery reconnect) leaked a file descriptor until GC. Ferrum hit the
# same leak as EMFILE under restart loops (rubycdp/ferrum#639).
class DeadBrowserSocketTest < Minitest::Test
  def test_quit_closes_the_socket_of_a_browser_that_already_died
    bin = ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    browser = Capybara::Lightpanda::Browser.new(browser_path: bin, port: rand(9800..9899))
    ws = browser.client.instance_variable_get(:@ws)
    socket = ws.instance_variable_get(:@socket)

    Process.kill("KILL", browser.process.pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.05 until ws.closed? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert ws.closed?, "the reader thread never noticed the browser died"

    browser.quit

    assert socket.closed?, "quit left the dead browser's TCPSocket open"
  end
end
