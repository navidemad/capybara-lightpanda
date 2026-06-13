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

        private

        def subscribe_to_console_logs
          logger = @options.logger
          return unless logger

          on("Runtime.consoleAPICalled") do |params|
            params["args"]&.each do |r|
              value = r["value"]
              next if turbo_sentinel?(value)

              logger.puts(value)
            end
          end
        end

        TURBO_SENTINEL_PREFIX = "__lightpanda_turbo_"
        private_constant :TURBO_SENTINEL_PREFIX

        # The Turbo activity tracker signals busy/idle via console.debug
        # sentinels (see subscribe_to_turbo_signals); every consoleAPICalled
        # consumer must filter them out of user-facing output.
        def turbo_sentinel?(value)
          value.is_a?(String) && value.start_with?(TURBO_SENTINEL_PREFIX)
        end

        # Oldest entries are dropped past this cap so a chatty page can't grow
        # the buffer unbounded across a long session.
        CONSOLE_LOGS_LIMIT = 1_000

        # Ring-buffer every console.* call for `Browser#console_logs`. Separate
        # from subscribe_to_console_logs (which streams to an optional IO logger)
        # so capture works without any logger configured. Skips the Turbo
        # activity-tracker sentinels — they're driver plumbing, not page output.
        def subscribe_to_console_capture
          on("Runtime.consoleAPICalled") do |params|
            args = params["args"]
            next unless args.is_a?(Array)

            first = args.first&.dig("value")
            next if turbo_sentinel?(first)

            entry = {
              type: params["type"],
              text: args.map { |a| a.fetch("value") { a["description"] }.to_s }.join(" "),
              timestamp: params["timestamp"],
              args: args,
            }
            @console_logs_mutex.synchronize do
              @console_logs << entry
              @console_logs.shift(@console_logs.size - CONSOLE_LOGS_LIMIT) if @console_logs.size > CONSOLE_LOGS_LIMIT
            end
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
