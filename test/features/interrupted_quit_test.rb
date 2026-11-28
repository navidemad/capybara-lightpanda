# frozen_string_literal: true

require_relative "../test_helper"
require "timeout"

# A quit interrupted while a hung browser keeps the connection open must still
# stop Lightpanda.
#
# WHY THIS MATTERS: `quit` untracks the browser before closing it, so once an
# outer Timeout.timeout (or Ctrl-C) skipped the process stop, nothing but the
# finalizer at exit would reap the binary, and the Browser still claimed to be
# started: a later `start` returned early onto a closed client. SIGSTOP stands
# in for a browser that hangs without dying (rubycdp/ferrum#740).
class InterruptedQuitTest < Minitest::Test
  def test_quit_interrupted_by_a_timeout_still_stops_a_hung_browser
    bin = ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    browser = Capybara::Lightpanda::Browser.new(browser_path: bin, port: rand(9700..9799))
    pid = browser.process.pid
    Process.kill("STOP", pid)

    assert_raises(Timeout::Error) { Timeout.timeout(0.5) { browser.quit } }

    assert_raises(Errno::ESRCH, "Lightpanda kept running after the interrupted quit") { Process.kill(0, pid) }
    assert_nil browser.process
    refute browser.alive?

    browser.start
    assert browser.alive?, "a quit browser must start again"
  ensure
    browser&.quit
  end
end
