# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Process
      READY_PATTERN = /server running.*address=(\d+\.\d+\.\d+\.\d+:\d+)/
      ADDRESS_IN_USE_PATTERN = /err=AddressInUse/

      # First nightly with the cookie/navigation/redirect fixes that let the gem
      # drop several workarounds: PR #2255 (Network.clearBrowserCookies empty
      # params + Network.getAllCookies), PR #2257 (window.location.pathname /
      # .search assignment triggers navigation), PR #2265 (URL fragment inherited
      # across fragment-less redirect). Rejecting older builds lets Cookies#clear
      # rely on the bulk-clear call, Cookies#all use Network.getAllCookies, and
      # current-path / fragment specs run unskipped.
      MINIMUM_NIGHTLY_BUILD = Gem::Version.new("5817")

      attr_reader :pid, :ws_url, :version, :nightly_build

      def initialize(options)
        @options = options
        @pid = nil
        @ws_url = nil
        @version = nil
        @nightly_build = nil
        @stdout_r = nil
        @stdout_w = nil
        @stderr_r = nil
        @stderr_w = nil
      end

      def start
        binary_path = @options.browser_path || Binary.find_or_download

        raise BinaryNotFoundError, "Lightpanda binary not found" unless binary_path

        check_minimum_version(binary_path)
        attempt_start(binary_path)
      rescue ProcessTimeoutError => e
        raise unless e.message.include?("already in use")

        kill_process_on_port(@options.port)
        attempt_start(binary_path)
      end

      def stop
        return unless @pid

        begin
          ::Process.kill("TERM", -@pid) # Kill process group
        rescue Errno::ESRCH, Errno::EPERM
          # Process group already dead, try direct
          begin
            ::Process.kill("TERM", @pid)
          rescue Errno::ESRCH
            # Process already dead
          end
        end

        begin
          ::Process.wait(@pid)
        rescue Errno::ECHILD
          # Already reaped
        end

        cleanup_pipes
        @pid = nil
      end

      def alive?
        return false unless @pid

        ::Process.kill(0, @pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      private

      def check_minimum_version(binary_path)
        stdout, = Open3.capture3(binary_path, "version")
        @version = stdout.strip
        # Accept either `nightly.NNNN` (publicly distributed builds) or
        # `dev.NNNN` (locally compiled trees) — the build number is the same
        # `git rev-list --count HEAD` counter, just labelled differently.
        build = @version[/(?:nightly|dev)\.(\d+)/, 1]
        @nightly_build = Gem::Version.new(build) if build

        return if @nightly_build && @nightly_build >= MINIMUM_NIGHTLY_BUILD

        raise BinaryError,
              "Lightpanda #{@version} is too old. " \
              "This gem requires build >= #{MINIMUM_NIGHTLY_BUILD}. " \
              "Update: curl -sL https://github.com/lightpanda-io/browser/releases/download/nightly/" \
              "#{Binary.platform_binary} -o #{binary_path} && chmod +x #{binary_path}"
      rescue Errno::ENOENT
        # Binary not runnable — let attempt_start handle it
      end

      def attempt_start(binary_path)
        @stdout_r, @stdout_w = IO.pipe
        @stderr_r, @stderr_w = IO.pipe

        @pid = spawn_process(binary_path)
        register_finalizer(@pid)

        @stdout_w.close
        @stderr_w.close

        wait_for_ready

        # Drain stderr/stdout to prevent pipe buffer from filling up
        # and blocking the Lightpanda process
        start_drain_thread
      end

      def start_drain_thread
        @drain_thread = Thread.new do
          ios = [@stdout_r, @stderr_r].compact
          loop do
            ready = IO.select(ios, nil, nil, 0.5)
            next unless ready

            ready[0].each do |io|
              io.read_nonblock(4096)
            rescue IO::WaitReadable
              # No data
            rescue EOFError
              ios.delete(io)
            end

            break if ios.empty?
          rescue IOError
            break
          end
        end
      end

      def spawn_process(binary_path)
        args = build_args

        ::Process.spawn(
          { "LIGHTPANDA_DISABLE_TELEMETRY" => "true" },
          binary_path, *args,
          out: @stdout_w,
          err: @stderr_w,
          pgroup: true
        )
      end

      def build_args
        [
          "serve",
          "--host",
          @options.host.to_s,
          "--port",
          @options.port.to_s,
          "--log_level",
          "info",
        ]
      end

      def wait_for_ready
        started_at = Time.now
        output = +""

        catch(:ready) do
          while Time.now - started_at < @options.process_timeout
            ready = IO.select([@stdout_r, @stderr_r], nil, nil, 0.1)

            next unless ready

            ready[0].each do |io|
              chunk = io.read_nonblock(1024)
              output << chunk

              if (match = output.match(READY_PATTERN))
                @ws_url = "ws://#{match[1]}/"
                throw(:ready)
              end

              if output.match?(ADDRESS_IN_USE_PATTERN)
                cleanup_failed_process
                raise ProcessTimeoutError,
                      "Lightpanda failed to start: port #{@options.port} is already in use"
              end
            rescue IO::WaitReadable
              # No data available yet
            rescue EOFError
              # Pipe closed
            end
          end

          stop

          raise ProcessTimeoutError,
                "Lightpanda failed to start within #{@options.process_timeout} seconds.\nOutput: #{output}"
        end
      end

      def cleanup_failed_process
        return unless @pid

        begin
          ::Process.wait(@pid, ::Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end

        cleanup_pipes
        @pid = nil
      end

      def kill_process_on_port(port)
        port = port.to_i
        return if port <= 0

        pids = `lsof -ti tcp:#{port} 2>/dev/null`.strip
        return if pids.empty?

        pids.split("\n").each do |pid_str|
          pid = pid_str.strip.to_i
          next if pid <= 0

          ::Process.kill("TERM", pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end

        sleep 0.5
      end

      # Class method so the finalizer proc doesn't capture `self` (which
      # would prevent GC from ever running the finalizer).
      class << self
        private

        def weak_kill(pid)
          proc do
            ::Process.kill("TERM", -pid)
            ::Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD, Errno::EPERM
            nil
          end
        end
      end

      def register_finalizer(pid)
        ObjectSpace.define_finalizer(self, self.class.send(:weak_kill, pid))
      end

      def cleanup_pipes
        [@stdout_r, @stdout_w, @stderr_r, @stderr_w].each do |pipe|
          pipe&.close unless pipe&.closed?
        end
      end
    end
  end
end
