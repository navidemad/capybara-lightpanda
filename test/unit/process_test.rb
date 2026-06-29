# frozen_string_literal: true

require_relative "../test_helper"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/options"
require "capybara/lightpanda/binary"
require "capybara/lightpanda/process"

describe Capybara::Lightpanda::Process do
  let(:options) { Capybara::Lightpanda::Options.new }
  let(:process) { Capybara::Lightpanda::Process.new(options) }
  let(:floor) { Capybara::Lightpanda::Process::MINIMUM_NIGHTLY_BUILD }

  describe "READY_PATTERN" do
    it "captures the bound address from the server-ready log line" do
      line = "info(server): server running address=127.0.0.1:43117"
      match = line.match(Capybara::Lightpanda::Process::READY_PATTERN)
      assert_equal "127.0.0.1:43117", match[1]
    end

    it "matches when 'server running' and the address arrive in different chunks" do
      # wait_for_ready accumulates chunked output; the /m flag lets the
      # pattern span intervening log lines.
      output = "info(server): server running\ninfo(other): noise\naddress = 127.0.0.1:9222"
      match = output.match(Capybara::Lightpanda::Process::READY_PATTERN)
      assert_equal "127.0.0.1:9222", match[1]
    end
  end

  describe "#wait_for_ready" do
    # Wire real pipes in place of the spawned process's stdout/stderr so the
    # actual select/read loop runs against scripted output.
    def wire_pipes(process)
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      process.instance_variable_set(:@stdout_r, stdout_r)
      process.instance_variable_set(:@stderr_r, stderr_r)
      process.instance_variable_set(:@stdout_w, stdout_w)
      process.instance_variable_set(:@stderr_w, stderr_w)
      [stdout_w, stderr_w]
    end

    after { process.send(:cleanup_pipes) }

    it "derives ws_url from the OS-assigned address, not the requested port" do
      # With the port-0 default the bound port is only knowable from the
      # ready line — the contract parallel test workers rely on.
      stdout_w, = wire_pipes(process)
      stdout_w.write("info(server): server running address=127.0.0.1:43117\n")
      stdout_w.flush

      process.send(:wait_for_ready)

      assert_equal "ws://127.0.0.1:43117/", process.ws_url
    end

    describe "when the address is already in use" do
      let(:options) { Capybara::Lightpanda::Options.new(port: 9222) }

      it "raises PortInUseError naming the port" do
        _, stderr_w = wire_pipes(process)
        stderr_w.write("err(server): listen err=AddressInUse\n")
        stderr_w.flush

        error = assert_raises(Capybara::Lightpanda::PortInUseError) do
          process.send(:wait_for_ready)
        end
        assert_includes error.message, "port 9222 is already in use"
        # Subclass contract: callers that `rescue ProcessTimeoutError` (the
        # class raised before PortInUseError existed) must keep catching it.
        assert_kind_of Capybara::Lightpanda::ProcessTimeoutError, error
      end
    end

    describe "when the ready line never arrives" do
      let(:options) { Capybara::Lightpanda::Options.new(process_timeout: 0.3) }

      it "raises ProcessTimeoutError carrying the captured output" do
        stdout_w, = wire_pipes(process)
        stdout_w.write("info(browser): still booting\n")
        stdout_w.flush

        error = assert_raises(Capybara::Lightpanda::ProcessTimeoutError) do
          process.send(:wait_for_ready)
        end
        assert_includes error.message, "failed to start within 0.3 seconds"
        assert_includes error.message, "still booting"
      end
    end
  end

  describe "#build_args" do
    before { @extra_args = ENV.delete("LIGHTPANDA_EXTRA_ARGS") }

    # Restore-or-delete: a plain `ENV[...] = @extra_args if @extra_args` would
    # leak the value set inside the test below into the rest of the test:all
    # process — and poison every later test that spawns a real Lightpanda.
    after do
      if @extra_args
        ENV["LIGHTPANDA_EXTRA_ARGS"] = @extra_args
      else
        ENV.delete("LIGHTPANDA_EXTRA_ARGS")
      end
    end

    it "builds the full serve command line, stylesheets + message-size flags included" do
      assert_equal %w[serve --host 127.0.0.1 --port 0 --log_level info --enable-external-stylesheets
                      --cdp-max-message-size 104857600],
                   process.send(:build_args)
    end

    describe "with explicit host and port" do
      let(:options) { Capybara::Lightpanda::Options.new(host: "0.0.0.0", port: 9333) }

      it "passes them through" do
        assert_equal %w[serve --host 0.0.0.0 --port 9333 --log_level info --enable-external-stylesheets
                        --cdp-max-message-size 104857600],
                     process.send(:build_args)
      end
    end

    it "appends LIGHTPANDA_EXTRA_ARGS split on whitespace" do
      ENV["LIGHTPANDA_EXTRA_ARGS"] = "--log-format pretty --log-filter-scopes telemetry"
      assert_equal %w[--log-format pretty --log-filter-scopes telemetry],
                   process.send(:build_args).last(4)
    end
  end

  describe "#check_minimum_version" do
    it "accepts a nightly build at the floor" do
      Open3.stubs(:capture3).with("/bin/lp", "version").returns(["Lightpanda nightly.#{floor}\n", "", nil])

      process.send(:check_minimum_version, "/bin/lp")

      assert_equal floor, process.nightly_build
      assert_equal "Lightpanda nightly.#{floor}", process.version
    end

    it "accepts dev builds — locally compiled trees use the same build counter" do
      Open3.stubs(:capture3).returns(["Lightpanda dev.99999\n", "", nil])

      process.send(:check_minimum_version, "/bin/lp")

      assert_equal Gem::Version.new("99999"), process.nightly_build
    end

    it "rejects builds below the floor with the tailored update hint" do
      Open3.stubs(:capture3).returns(["Lightpanda nightly.6352\n", "", nil])
      Capybara::Lightpanda::Binary.stubs(:update_hint).returns("brew update && brew upgrade lightpanda")

      error = assert_raises(Capybara::Lightpanda::BinaryError) do
        process.send(:check_minimum_version, "/bin/lp")
      end
      assert_includes error.message, "too old"
      assert_includes error.message, "requires build >= #{floor}"
      assert_includes error.message, "brew update && brew upgrade lightpanda"
    end

    it "rejects versions it cannot parse — never assume an unknown build is new enough" do
      Open3.stubs(:capture3).returns(["weird-version-string\n", "", nil])
      Capybara::Lightpanda::Binary.stubs(:update_hint).returns("hint")

      assert_raises(Capybara::Lightpanda::BinaryError) { process.send(:check_minimum_version, "/bin/lp") }
      assert_nil process.nightly_build
    end

    it "lets ENOENT through silently — attempt_start surfaces unrunnable binaries" do
      Open3.stubs(:capture3).raises(Errno::ENOENT)

      process.send(:check_minimum_version, "/missing/lp")

      assert_nil process.nightly_build
    end
  end

  describe "#kill_process_on_port" do
    it "no-ops on port 0 — the ephemeral default has no fixed port to free" do
      process.expects(:pids_listening_on).never
      process.send(:kill_process_on_port, 0)
    end

    it "TERMs every pid holding the port" do
      process.stubs(:pids_listening_on).with(9222).returns([123, 456])
      process.stubs(:sleep)
      Process.expects(:kill).with("TERM", 123)
      Process.expects(:kill).with("TERM", 456)

      process.send(:kill_process_on_port, 9222)
    end

    it "ignores pids that exited between lookup and kill" do
      process.stubs(:pids_listening_on).returns([123])
      process.stubs(:sleep)
      Process.stubs(:kill).raises(Errno::ESRCH)

      process.send(:kill_process_on_port, 9222)
    end

    it "raises BinaryError when lsof is unavailable to identify the holder" do
      process.stubs(:pids_listening_on).returns(nil)

      error = assert_raises(Capybara::Lightpanda::BinaryError) do
        process.send(:kill_process_on_port, 9222)
      end
      assert_includes error.message, "lsof"
    end
  end

  describe "#pids_listening_on" do
    let(:success_status) { stub(success?: true) }
    let(:failure_status) { stub(success?: false) }

    it "parses newline-separated pids from lsof output" do
      Open3.stubs(:capture3).with("lsof", "-ti", "tcp:9222").returns(["123\n456\n", "", success_status])
      assert_equal [123, 456], process.send(:pids_listening_on, 9222)
    end

    it "treats exit != 0 with empty output as 'port not held'" do
      Open3.stubs(:capture3).returns(["", "", failure_status])
      assert_equal [], process.send(:pids_listening_on, 9222)
    end

    it "returns nil on a real lsof failure (stderr present) so the caller can raise" do
      Open3.stubs(:capture3).returns(["", "lsof: permission denied\n", failure_status])
      assert_nil process.send(:pids_listening_on, 9222)
    end

    it "returns nil when lsof is not installed" do
      Open3.stubs(:capture3).raises(Errno::ENOENT)
      assert_nil process.send(:pids_listening_on, 9222)
    end
  end
end
