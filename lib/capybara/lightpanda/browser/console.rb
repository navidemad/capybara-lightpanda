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
        # The source is Runtime.exceptionThrown, as in Chrome: Lightpanda emits
        # it for an uncaught exception (#3905, build 10450) and an unhandled
        # rejection (#4096, 10904), in iframes too (#4115, 10910). What it
        # reports is what reaches `window` uncancelled: an exception a framework
        # catches itself (Stimulus's handleError, any try/catch) never arrives,
        # nor does one a page `error` listener cancels with preventDefault. The
        # driver's own scripts raise JavaScriptError instead and never land here.
        def page_errors
          @page_errors_mutex.synchronize { @page_errors.dup }
        end

        def clear_page_errors
          @page_errors_mutex.synchronize { @page_errors.clear }
        end

        REJECTION_TEXT = "Uncaught (in promise)"
        private_constant :REJECTION_TEXT

        # Cap the stack: a deep recursion stack can be megabytes, and the buffer
        # keeps up to PAGE_ERRORS_LIMIT of them.
        STACK_LIMIT = 4_000
        private_constant :STACK_LIMIT

        # One Runtime.exceptionThrown event as a page_errors entry. The shape is
        # the one javascripts/errors.js produced from the DOM `error` /
        # `unhandledrejection` events before this event replaced it, so suites
        # written against it keep working:
        # - message: an Error's "Name: message" (the description up to its
        #   first stack frame), or a thrown primitive's value. A rejection's
        #   message drops the "Name: " prefix, as `reason.message` did.
        # - line/column: 1-based like ErrorEvent's lineno/colno (CDP counts
        #   from 0), and nil for a rejection, which carries no location.
        # - stack: the Error's description, which is its stack, or nil for a
        #   thrown primitive. Lightpanda sends no structured stackTrace.
        def self.page_error_entry(params)
          details = params["exceptionDetails"] || {}
          exception = details["exception"] || {}
          rejection = details["text"] == REJECTION_TEXT
          stack = exception["subtype"] == "error" ? exception["description"].to_s : nil

          {
            kind: rejection ? "unhandledrejection" : "error",
            message: page_error_message(exception, stack, rejection),
            url: details["url"].to_s,
            line: rejection ? nil : one_based(details["lineNumber"]),
            column: rejection ? nil : one_based(details["columnNumber"]),
            stack: stack&.slice(0, STACK_LIMIT),
            timestamp: params["timestamp"],
          }
        end

        def self.one_based(position)
          position + 1 if position
        end

        def self.page_error_message(exception, stack, rejection)
          return primitive_text(exception) unless stack

          summary = stack.split(/\n\s+at /, 2).first
          prefix = "#{exception['className']}: "
          rejection && summary.start_with?(prefix) ? summary.delete_prefix(prefix) : summary
        end

        # What String(value) gave for a thrown or rejected non-Error.
        def self.primitive_text(exception)
          return exception["value"].nil? ? "null" : exception["value"].to_s if exception.key?("value")

          [exception["unserializableValue"], exception["description"], exception["type"]]
            .find { |v| v.is_a?(String) && !v.empty? }.to_s
        end
        private_class_method :page_error_message, :one_based, :primitive_text

        private

        def subscribe_to_console_logs
          logger = @options.logger
          return unless logger

          on("Runtime.consoleAPICalled") do |params|
            params["args"]&.each do |r|
              next if driver_sentinel?(r["value"])

              logger.puts(console_arg_text(r))
            end
          end
        end

        # One console argument as text. Since upstream #3504 (build 9414)
        # Lightpanda sends `value` for primitives only — an object, array or
        # DOM node arrives as a RemoteObject with a `description` (sometimes
        # empty), a `className` and a `type`. Reading `value` alone printed
        # objects as blank lines in the logger and DOM nodes as "" in
        # console_logs; fall through to the first non-empty descriptor,
        # the way DevTools labels an object it can't preview.
        def console_arg_text(arg)
          return arg["value"].to_s if arg.key?("value")

          [arg["unserializableValue"], arg["description"], arg["className"], arg["type"]]
            .find { |v| v.is_a?(String) && !v.empty? }.to_s
        end

        TURBO_SENTINEL_PREFIX = "__lightpanda_turbo_"
        private_constant :TURBO_SENTINEL_PREFIX

        # The Turbo activity tracker signals busy/idle via console.debug
        # sentinels (see subscribe_to_turbo_signals); every consoleAPICalled
        # consumer must filter them out of user-facing output.
        def turbo_sentinel?(value)
          value.is_a?(String) && value.start_with?(TURBO_SENTINEL_PREFIX)
        end

        # Anything the injected bundle emits for the driver's own benefit. Every
        # consoleAPICalled consumer filters on this, not on one prefix — a new
        # sentinel added to turbo_sentinel?'s side only would leak driver
        # plumbing into user-facing output.
        def driver_sentinel?(value)
          turbo_sentinel?(value)
        end

        # Oldest entries are dropped past this cap so a chatty page can't grow
        # the buffer unbounded across a long session.
        CONSOLE_LOGS_LIMIT = 1_000

        # Ring-buffer every console.* call for `Browser#console_logs`. Separate
        # from subscribe_to_console_logs (which streams to an optional IO logger)
        # so capture works without any logger configured. Driver sentinels are
        # plumbing, not page output, so they are dropped.
        def subscribe_to_console_capture
          on("Runtime.consoleAPICalled") do |params|
            args = params["args"]
            next unless args.is_a?(Array)
            next if driver_sentinel?(args.first&.dig("value"))

            entry = {
              type: params["type"],
              text: args.map { |a| console_arg_text(a) }.join(" "),
              timestamp: params["timestamp"],
              args: args,
            }
            push_capped(@console_logs, @console_logs_mutex, entry, CONSOLE_LOGS_LIMIT)
          end
        end

        # Same cap and reasoning as CONSOLE_LOGS_LIMIT: a page erroring inside a
        # loop (a rejected fetch on an interval) must not grow this unbounded.
        PAGE_ERRORS_LIMIT = 1_000

        def subscribe_to_page_errors
          on("Runtime.exceptionThrown") do |params|
            push_capped(@page_errors, @page_errors_mutex, Console.page_error_entry(params), PAGE_ERRORS_LIMIT)
          end
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
