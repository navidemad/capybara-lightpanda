# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

# End-to-end regression for the live-CDP-connection SIGTERM hang.
#
# A browser left to process-exit cleanup (no explicit #quit — what happens to
# Capybara's shared browser at the end of a suite) must be torn down by closing
# its CDP WebSocket BEFORE SIGTERM. Lightpanda swallows a single SIGTERM while a
# CDP connection is live, so if teardown SIGTERMed first it would fall back to
# the STOP_GRACE_SECONDS SIGKILL escalation (~3s) — or, before that escalation,
# hang forever. Closing the WS first makes SIGTERM land cleanly.
class TeardownTest < Minitest::Test
  SCRIPT = File.expand_path("../support/abandoned_browser_script.rb", __dir__)

  def test_abandoned_browser_is_torn_down_via_clean_sigterm_at_exit
    bin = ENV["LIGHTPANDA_BIN"] || Capybara::Lightpanda::Binary.update
    port = rand(9000..9799)
    env = { "LP_ABANDON_BIN" => bin, "LP_ABANDON_PORT" => port.to_s }

    out = +""
    child_exit_at = nil
    status = nil
    Open3.popen2e(env, RbConfig.ruby, SCRIPT) do |_in, oe, wait_thr|
      out = oe.read # blocks until the child closes stdout, i.e. exits
      child_exit_at = Time.now.to_f
      status = wait_thr.value
    end

    pid = out[/READY (\d+)/, 1]&.to_i
    teardown_start = out[/TEARDOWN_START ([\d.]+)/, 1]&.to_f

    assert status.success?, "child did not exit cleanly:\n#{out}"
    refute_nil pid, "child never reported a lightpanda pid:\n#{out}"
    refute_nil teardown_start, "child never reached teardown:\n#{out}"

    refute pid_alive?(pid), "lightpanda pid #{pid} survived the child's exit (leak)"

    teardown_dt = child_exit_at - teardown_start
    # Clean SIGTERM teardown is ~0.1-0.3s. The SIGKILL-escalation fallback would
    # take ~STOP_GRACE_SECONDS (3s), which only happens if the CDP WS was NOT
    # closed before SIGTERM. 2s sits unambiguously between the two.
    assert_operator teardown_dt, :<, 2.0,
                    "at-exit teardown took #{teardown_dt.round(2)}s — the SIGKILL " \
                    "escalation fired, i.e. the CDP WebSocket was not closed before SIGTERM"
  end

  private

  def pid_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end
end
