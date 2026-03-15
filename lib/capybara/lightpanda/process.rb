# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Process
      READY_PATTERN = /server running.*address=(\d+\.\d+\.\d+\.\d+:\d+)/
      ADDRESS_IN_USE_PATTERN = /err=AddressInUse/

      attr_reader :pid, :ws_url

      def initialize(options)
        @options = options
        @pid = nil
        @ws_url = nil
        @stdout_r = nil
        @stdout_w = nil
        @stderr_r = nil
        @stderr_w = nil
      end

      def start
        binary_path = @options.browser_path || Binary.find_or_download

        raise BinaryNotFoundError, "Lightpanda binary not found" unless binary_path

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

      def attempt_start(binary_path)
        @stdout_r, @stdout_w = IO.pipe
        @stderr_r, @stderr_w = IO.pipe

        @pid = spawn_process(binary_path)

        @stdout_w.close
        @stderr_w.close

        wait_for_ready
      end

      def spawn_process(binary_path)
        args = build_args

        ::Process.spawn(
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

      def cleanup_pipes
        [@stdout_r, @stdout_w, @stderr_r, @stderr_w].each do |pipe|
          pipe&.close unless pipe&.closed?
        end
      end
    end
  end
end
