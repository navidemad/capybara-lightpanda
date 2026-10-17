# frozen_string_literal: true

require "json"
require "socket"
require "websocket/driver"

require_relative "../utils/attempt"

module Capybara
  module Lightpanda
    class Client
      class WebSocket
        attr_reader :url, :messages

        def initialize(url, options)
          @url = url
          @options = options
          @logger = options.logger
          @socket = nil
          @driver = nil
          @thread = nil
          @status = :closed
          @messages = Queue.new
          @driver_mutex = Mutex.new

          connect
        end

        # `timeout` bounds how long the browser may go without taking any of
        # the frame's bytes (see #write); nil falls back to options.timeout.
        def send_message(message, timeout: nil)
          raise DeadBrowserError, "WebSocket is not open" unless @status == :open

          @logger&.puts("\n\n▶ #{@logger.elapsed_time} #{message}")
          @driver_mutex.synchronize do
            @write_timeout = timeout
            @driver.text(message)
          ensure
            @write_timeout = nil
          end
        end

        # The socket is closed even when the connection is already dead. A
        # browser that dies first makes the reader thread #mark_dead the
        # connection (status :closed or :error) without closing the socket,
        # and an early return here then left the TCPSocket — one descriptor
        # per crashed browser — open until GC finalized it (ferrum #639).
        def close
          unless @status == :closed
            @status = :closing
            @messages.close
            @driver_mutex.synchronize { @driver&.close }
            @thread&.join(1) || @thread&.kill
          end
          close_socket
          @status = :closed
        end

        def closed?
          @status == :closed || @status == :error
        end

        # Called by websocket-driver, always under @driver_mutex. A browser
        # that stops reading (hung, stopped, or a page stuck in a sync JS loop
        # on Lightpanda's single thread) would block a plain write forever
        # once the frame outgrows the socket buffers, holding the lock that
        # every other command, the reader's parse and #close need — and the
        # command timeout only starts after the write returns. So the write
        # gives up once the browser takes no byte for the timeout; the wait
        # restarts on every partial write, so a slow but moving peer is fine
        # (ferrum #644). Close and pong frames have no command timeout and
        # fall back to options.timeout rather than waiting forever.
        def write(data)
          until data.empty?
            written = @socket.write_nonblock(data, exception: false)
            if written.is_a?(Integer)
              data = data.byteslice(written..)
            elsif !wait_for_socket(written)
              abandon_stalled_write
            end
          end
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          mark_dead
        end

        # Single home for the "dead implies queue closed" invariant: every
        # path that gives up on the connection must close @messages so the
        # Client message thread's blocking pop returns. Public because the
        # Client calls it when its own message thread dies — either transport
        # thread dying means the connection is dead.
        def mark_dead(status = :closed)
          @status = status
          @messages.close
        end

        private

        def wait_for_socket(state)
          timeout = @write_timeout || @options.timeout
          state == :wait_readable ? @socket.wait_readable(timeout) : @socket.wait_writable(timeout)
        end

        # The frame was cut off midway, so the connection can't be reused:
        # mark it dead (the reader and message threads stop, pending commands
        # are released) and close the socket.
        def abandon_stalled_write
          timeout = @write_timeout || @options.timeout
          mark_dead(:error)
          close_socket
          raise DeadBrowserError, "Browser accepted no data for #{timeout}s and is likely stuck; connection closed"
        end

        def close_socket
          @socket&.close unless @socket.nil? || @socket.closed?
        rescue IOError, SystemCallError
          # Already torn down by the peer; nothing left to release.
        end

        def connect
          uri = URI.parse(@url)

          @socket = connect_with_retry(uri.host, uri.port)
          @driver = ::WebSocket::Driver.client(self)

          setup_callbacks

          @driver.start

          read_handshake_response
          start_reader_thread
        end

        def connect_with_retry(host, port)
          Utils::Attempt.with_retry(errors: Errno::ECONNREFUSED, max: 10, wait: 0.1) do
            TCPSocket.new(host, port)
          end
        end

        def setup_callbacks
          @driver.on(:open) do
            @status = :open
          end

          @driver.on(:message) do |event|
            @logger&.puts("    ◀ #{@logger.elapsed_time} #{event.data}\n")
            message = parse_message(event.data)
            @messages << message if message
          rescue ClosedQueueError
            # Queue was closed during shutdown
          end

          @driver.on(:close) do
            mark_dead
          end

          @driver.on(:error) do |event|
            # Do NOT raise here. This callback fires synchronously from
            # @driver.parse(data) inside the reader thread. Mark the
            # connection dead and let Client#command surface DeadBrowserError
            # on its next dispatch via closed?.
            @logger&.puts("✗ WebSocket error: #{event.message}")
            mark_dead(:error)
          end
        end

        # The reader must never take the host process down. With
        # abort_on_exception an error the narrow IO rescue doesn't expect
        # (Errno::ETIMEDOUT is a SystemCallError, not an IOError) was re-raised
        # on the main thread wherever it happened to be: a spec failure blamed
        # on an unrelated call, or a server dying with its `ensure` never
        # reaching browser.quit. Any error here means the connection is dead —
        # report it and let the next command raise DeadBrowserError
        # (mirrors ferrum #632).
        def start_reader_thread
          @thread = Thread.new do
            Thread.current.abort_on_exception = false

            loop do
              break if @status == :closed || @status == :closing

              begin
                next unless @socket.wait_readable(0.1)

                data = @socket.readpartial(4096)
                @driver_mutex.synchronize { @driver.parse(data) }
              rescue Errno::ECONNRESET, Errno::EPIPE, IOError
                mark_dead
                break
              rescue StandardError => e
                warn "Capybara::Lightpanda: WebSocket reader died: #{e.class}: #{e.message}"
                mark_dead(:error)
                break
              end
            end
          end
        end

        def read_handshake_response
          started_at = Time.now

          while @status != :open && Time.now - started_at < @options.handshake_timeout
            next unless @socket.wait_readable(0.1)

            begin
              data = @socket.readpartial(4096)
              @driver.parse(data)
            rescue Errno::ECONNRESET, Errno::EPIPE, IOError # IOError covers EOFError
              raise DeadBrowserError, "Connection closed during handshake"
            end
          end

          return if @status == :open

          raise TimeoutError, "WebSocket handshake timed out after #{@options.handshake_timeout}s"
        end

        # A JS string can hold a lone UTF-16 surrogate ("😀".slice(0, 1));
        # Lightpanda escapes it as `\ud83d`, which Ruby's json rejects.
        # Dropping that frame left its command waiting out the full timeout,
        # so retry once with every lone surrogate replaced by U+FFFD — what
        # Chrome and Ferrum (#648) hand back for the same value.
        def parse_message(data)
          JSON.parse(data, max_nesting: false)
        rescue JSON::ParserError => e
          begin
            JSON.parse(replace_lone_surrogates(data), max_nesting: false)
          rescue JSON::ParserError
            warn_parse_failure(e.message)

            nil
          end
        end

        # Alternation order matters: a valid lead+trail pair is consumed
        # whole, then a lone surrogate, then any other escape (`\\`, `\"`,
        # a non-surrogate `\uXXXX`) is skipped as-is — scanning left to
        # right so `\\ud800` (an escaped backslash, then text) survives.
        SURROGATE_ESCAPE = /\\u[dD][89abAB]\h{2}\\u[dD][c-fC-F]\h{2}|(\\u[dD][89a-fA-F]\h{2})|\\./m

        def replace_lone_surrogates(data)
          data.gsub(SURROGATE_ESCAPE) { |escape| Regexp.last_match(1) ? "\\uFFFD" : escape }
        end

        # Dedupe identical parse-failure warnings per WebSocket instance.
        # Lightpanda occasionally emits CDP frames that embed a bare
        # `undefined` token (invalid JSON — see upstream-wishlist.md A41)
        # and a complex page reproduces the same frame on every load,
        # which previously flooded test output with one warn per frame.
        # Surface the first occurrence per unique error so the upstream
        # regression stays visible, then suppress repeats.
        def warn_parse_failure(message)
          @parse_warnings ||= {}
          return if @parse_warnings[message]

          @parse_warnings[message] = true
          warn "Failed to parse WebSocket message: #{message}"
        end
      end
    end
  end
end
