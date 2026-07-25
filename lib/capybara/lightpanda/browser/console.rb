# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # Runtime.consoleAPICalled consumers: the user-facing console_logs
      # ring buffer, the optional IO-logger stream, and the Turbo
      # busy/idle sentinel tracking behind Browser#wait_for_idle.
      module Console
        # Console messages captured from `Runtime.consoleAPICalled` since the
        # last `reset` (Turbo-tracker sentinels excluded). Loose hashes, like
        # Network#traffic: `{type:, text:, timestamp:, args:}` where `type` is
        # the console method name ("log", "error", "warning", ...), `text` joins
        # the arguments' primitive values/descriptions, and `args` keeps the raw
        # CDP RemoteObjects. Lets suites assert on JS console errors
        # (`browser.console_logs.select { |m| m[:type] == "error" }`) the way
        # peer drivers do via custom Ferrum loggers.
        def console_logs
          @console_logs_mutex.synchronize { @console_logs.dup }
        end

        def clear_console_logs
          @console_logs_mutex.synchronize { @console_logs.clear }
        end

        # Uncaught page exceptions and unhandled promise rejections since the
        # last `reset`: `{kind:, message:, url:, line:, column:, stack:,
        # timestamp:}`, where `kind` is "error" or "unhandledrejection".
        #
        # Deliberately NOT folded into #console_logs. Chrome reports an
        # uncaught exception through Runtime.exceptionThrown rather than
        # consoleAPICalled, and Playwright/Puppeteer expose it as `pageerror`
        # separately from `console` — so a suite that greps console_logs for
        # errors on those stacks doesn't see exceptions there either. Merging
        # them would also start failing every suite that already asserts
        # console_logs holds no errors.
        #
        # Lightpanda emits no Runtime.exceptionThrown at all, so the source is
        # a passive listener pair in javascripts/errors.js reporting over the
        # console.debug sentinel channel. It sees what reaches `window`:
        # exceptions a framework catches itself (Stimulus's handleError, any
        # try/catch) never arrive, and a cross-origin script collapses to
        # "Script error." with no detail. Partial by construction — but the
        # alternative is the zero visibility that made the solidus taxon-tree
        # failure take a hand-injected listener to explain.
        def page_errors
          @page_errors_mutex.synchronize { @page_errors.dup }
        end

        def clear_page_errors
          @page_errors_mutex.synchronize { @page_errors.clear }
        end

        private

        def subscribe_to_console_logs
          logger = @options.logger
          return unless logger

          on("Runtime.consoleAPICalled") do |params|
            params["args"]&.each do |r|
              value = r["value"]
              next if driver_sentinel?(value)

              logger.puts(value)
            end
          end
        end

        TURBO_SENTINEL_PREFIX = "__lightpanda_turbo_"
        private_constant :TURBO_SENTINEL_PREFIX

        PAGE_ERROR_SENTINEL_PREFIX = "__lightpanda_page_error_"
        private_constant :PAGE_ERROR_SENTINEL_PREFIX

        # The Turbo activity tracker signals busy/idle via console.debug
        # sentinels (see subscribe_to_turbo_signals); every consoleAPICalled
        # consumer must filter them out of user-facing output.
        def turbo_sentinel?(value)
          value.is_a?(String) && value.start_with?(TURBO_SENTINEL_PREFIX)
        end

        # javascripts/errors.js reports uncaught page errors over the same
        # console.debug channel, prefix + JSON payload.
        def page_error_sentinel?(value)
          value.is_a?(String) && value.start_with?(PAGE_ERROR_SENTINEL_PREFIX)
        end

        # Anything the injected bundle emits for the driver's own benefit. Every
        # consoleAPICalled consumer filters on this, not on one prefix — missing
        # a sentinel here leaks driver plumbing into user-facing output.
        def driver_sentinel?(value)
          turbo_sentinel?(value) || page_error_sentinel?(value)
        end

        # Oldest entries are dropped past this cap so a chatty page can't grow
        # the buffer unbounded across a long session.
        CONSOLE_LOGS_LIMIT = 1_000

        # Ring-buffer every console.* call for `Browser#console_logs`. Separate
        # from subscribe_to_console_logs (which streams to an optional IO logger)
        # so capture works without any logger configured. Driver sentinels are
        # plumbing, not page output: the Turbo ones are dropped, and the
        # page-error ones are rerouted to @page_errors instead.
        def subscribe_to_console_capture
          on("Runtime.consoleAPICalled") do |params|
            args = params["args"]
            next unless args.is_a?(Array)

            first = args.first&.dig("value")
            next if turbo_sentinel?(first)

            if page_error_sentinel?(first)
              record_page_error(first, params["timestamp"])
              next
            end

            entry = {
              type: params["type"],
              text: args.map { |a| a.fetch("value") { a["description"] }.to_s }.join(" "),
              timestamp: params["timestamp"],
              args: args,
            }
            push_capped(@console_logs, @console_logs_mutex, entry, CONSOLE_LOGS_LIMIT)
          end
        end

        # Same cap and reasoning as CONSOLE_LOGS_LIMIT: a page erroring inside a
        # loop (a rejected fetch on an interval) must not grow this unbounded.
        PAGE_ERRORS_LIMIT = 1_000

        # Parse one `__lightpanda_page_error_<json>` sentinel into @page_errors.
        # A payload that won't parse is still worth surfacing — dropping it would
        # turn "the page threw" into silence, which is the whole failure mode
        # this exists to end — so it lands with the raw text as the message.
        def record_page_error(sentinel, timestamp)
          json = sentinel.delete_prefix(PAGE_ERROR_SENTINEL_PREFIX)
          fields = begin
            JSON.parse(json)
          rescue JSON::ParserError
            { "kind" => "error", "message" => json }
          end

          entry = {
            kind: fields["kind"] || "error",
            message: fields["message"].to_s,
            url: fields["url"].to_s,
            line: fields["line"],
            column: fields["column"],
            stack: fields["stack"],
            timestamp: timestamp,
          }
          push_capped(@page_errors, @page_errors_mutex, entry, PAGE_ERRORS_LIMIT)
        end

        def push_capped(buffer, mutex, entry, limit)
          mutex.synchronize do
            buffer << entry
            buffer.shift(buffer.size - limit) if buffer.size > limit
          end
        end

        # Wire @turbo_event to the JS-side _signalTurbo emissions. The JS calls
        # console.debug('__lightpanda_turbo_busy') / '_idle' on transitions across
        # zero pending ops; Lightpanda forwards those to Runtime.consoleAPICalled.
        # Idle → set the event (wakes any waiter); busy → reset.
        #
        # On Runtime.executionContextsCleared (navigation), unconditionally set
        # the event: if we navigated away mid-busy state, no further idle signal
        # would ever come from the old context, and we'd block for the full
        # timeout. The new context will signal busy again if Turbo is active.
        def subscribe_to_turbo_signals
          on("Runtime.consoleAPICalled") do |params|
            next unless params["args"].is_a?(Array)

            marker = params["args"].first&.dig("value")
            next unless turbo_sentinel?(marker)

            case marker
            when "#{TURBO_SENTINEL_PREFIX}busy" then @turbo_event.reset
            when "#{TURBO_SENTINEL_PREFIX}idle" then @turbo_event.set
            end
          end

          on("Runtime.executionContextsCleared") { @turbo_event.set }
        end
      end
    end
  end
end
