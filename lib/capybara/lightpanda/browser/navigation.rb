# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # Navigation lifecycle: go_to / back / forward / refresh and the
      # Page.loadEventFired + readyState-polling machinery behind them
      # (the polling fallback is load-bearing — see CLAUDE.md).
      module Navigation
        # Navigation with readyState fallback.
        #
        # Lightpanda may never fire Page.loadEventFired on complex JS pages
        # (lightpanda-io/browser#1801, #1832). When the event times out,
        # we poll document.readyState as a fallback.
        #
        # Page.navigate is sent asynchronously because Lightpanda may not
        # return the command result until the page is fully loaded (unlike
        # Chrome which returns immediately with frameId/loaderId). If we
        # waited synchronously, the readyState fallback would never be
        # reached on pages that fail to fully load.
        #
        # Uses a single shared deadline so the worst-case wait is 1x timeout,
        # not 2x (lightpanda-io/browser#1849).
        def go_to(url, wait: true)
          enable_page_events

          if wait
            wait_for_page_load(url)
          else
            page_command("Page.navigate", url: url)
          end
          check_unhandled_modal!
        end
        alias goto go_to

        def back
          wait_for_navigation { navigate_history(-1) }
        end

        def forward
          wait_for_navigation { navigate_history(+1) }
        end

        def refresh
          wait_for_navigation { page_command("Page.reload") }
        end
        alias reload refresh

        private

        def wait_for_page_load(url, retried: false)
          deadline = await_navigation do
            @client.command("Page.navigate", { url: url }, async: true, session_id: @session_id)
          end
          handle_navigation_crash(url, deadline, retried: retried)
        end

        # Lightpanda may kill the WebSocket or crash during complex page
        # navigation (lightpanda-io/browser#1849, #1854). Reconnect and
        # retry once. If the retry also crashes, raise a clear error
        # instead of leaving the client in a dead state.
        def handle_navigation_crash(url, deadline, retried:)
          if @client.closed? && !retried
            begin
              reconnect
              remaining = deadline - monotonic_time
              if remaining.positive?
                # Equivalent of re-entering go_to without leaking the retry
                # bookkeeping into its public signature. enable_page_events is
                # needed again: reconnect's clear_session_state reset the flag.
                enable_page_events
                wait_for_page_load(url, retried: true)
              end
            rescue DeadBrowserError
              raise
            rescue StandardError
              # reconnect itself failed (process won't restart, port stuck, etc.).
              # Fall through to the raise below — a second immediate reconnect
              # attempt would just duplicate the failure we already swallowed.
            end
          end

          return unless @client.closed?

          raise DeadBrowserError, "Lightpanda crashed navigating to #{url}"
        end

        def safe_current_url
          current_url
        rescue StandardError
          nil
        end

        # Wait for a navigation triggered by the given block.
        # Uses the same loadEventFired + readyState fallback as go_to.
        def wait_for_navigation(&)
          enable_page_events
          await_navigation(&)
        end

        # Step the session history by `offset` (-1 = back, +1 = forward) using
        # native CDP. `Page.getNavigationHistory` returns the entry list and
        # `currentIndex`; `Page.navigateToHistoryEntry` jumps to the chosen
        # entry's `id`. No-op when the offset would step past either end so
        # the behavior matches `history.back()` / `history.forward()` on a
        # bounded session history.
        def navigate_history(offset)
          history = page_command("Page.getNavigationHistory")
          target_index = history["currentIndex"] + offset
          entries = history["entries"]
          return if target_index.negative? || target_index >= entries.length

          page_command("Page.navigateToHistoryEntry", entryId: entries[target_index]["id"])
        end

        # Common navigation lifecycle shared by `wait_for_page_load` (fresh
        # `Page.navigate`) and `wait_for_navigation` (back / forward / reload).
        # Subscribes to Page.loadEventFired, runs the trigger, waits briefly for
        # the event, falls back to readyState polling for the remaining budget.
        # The handler is unsubscribed via `ensure` so a raising trigger doesn't
        # leak a subscription onto the next navigation. Returns the deadline so
        # the caller can decide whether to attempt crash recovery.
        def await_navigation
          starting_url = safe_current_url
          deadline = monotonic_time + @options.timeout
          loaded = Utils::Event.new
          handler = proc { loaded.set }
          @client.on("Page.loadEventFired", &handler)

          begin
            yield

            unless loaded.wait([2, @options.timeout].min)
              remaining = deadline - monotonic_time
              poll_ready_state(remaining, loaded_event: loaded, starting_url: starting_url) if remaining.positive?
            end
          ensure
            @client.off("Page.loadEventFired", handler)
          end

          deadline
        end

        # Poll document.readyState as a fallback when Page.loadEventFired
        # doesn't fire (CLAUDE.md rules call this out as load-bearing — do
        # not remove). When starting_url is provided, the poll ignores
        # readyState values from the old page (e.g. about:blank reports
        # "complete" while the new page is still loading in the background).
        def poll_ready_state(timeout, loaded_event: nil, starting_url: nil)
          # Use a short per-evaluation timeout because Lightpanda may block
          # all commands while navigating. Without this, a single evaluate()
          # call would consume the entire @options.timeout, making the poll
          # loop effectively a single attempt.
          poll_cmd_timeout = [timeout / 5.0, 2].max

          Utils::Wait.until(timeout: timeout, interval: 0.1) do
            loaded_event&.set? || @client.closed? || page_ready?(poll_cmd_timeout, starting_url)
          end
        rescue TimeoutError
          # Expected — readyState fallback exhausted its budget. The caller
          # (await_navigation) keeps going and lets handle_navigation_crash
          # decide whether the session is recoverable.
        end

        POLL_STATE_JS = "(function(){return{r:document.readyState,u:location.href}})()"
        private_constant :POLL_STATE_JS

        def page_ready?(cmd_timeout, starting_url)
          response = @client.command(
            "Runtime.evaluate",
            { expression: POLL_STATE_JS, returnByValue: true, awaitPromise: true },
            session_id: @session_id,
            timeout: cmd_timeout
          )
          state = response.dig("result", "value")
          return false unless state

          url_changed = starting_url.nil? || state["u"] != starting_url
          url_changed && %w[complete interactive].include?(state["r"])
        rescue Error
          false
        end
      end
    end
  end
end
