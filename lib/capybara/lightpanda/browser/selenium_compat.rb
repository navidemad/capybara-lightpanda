# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # Selenium-shaped entry points onto capability the gem already has under
      # its own names.
      #
      # Rails suites reach through `page.driver.browser.<x>` in *shared* helpers
      # — `expect_no_js_errors` (the widely-copied "catch JavaScript errors in
      # your system tests" helper) calls `browser.logs.get(:browser)`, and the
      # axe-core accessibility matchers call `browser.execute_async_script`.
      # Both are driver-agnostic in intent but Selenium-named in fact, so on
      # this driver they raised NoMethodError — which takes out every example in
      # the file before a single real assertion runs. Two aliases buy back whole
      # spec files (decidim's `account_spec.rb` + the shared "accessible page"
      # examples, real-apps run 30116365373).
      #
      # Scope is deliberately narrow: alias what maps cleanly onto an existing
      # API, and raise something *actionable* where the underlying model
      # genuinely differs (see #switch_to). We do not grow a Selenium
      # emulation layer.
      module SeleniumCompat
        # Selenium's `Logs#get(:browser)` shape over Browser#console_logs.
        # `level` is the Selenium severity string ("SEVERE"/"WARNING"/…), not
        # the CDP console type, because that is what callers compare against.
        LogEntry = Struct.new(:level, :message, :timestamp) do
          def to_s
            "#{timestamp} #{level} #{message}"
          end
        end

        # CDP `Runtime.consoleAPICalled` type -> Selenium log level. Anything
        # unlisted (log, info, dir, table, …) is INFO, matching Chrome. "warn"
        # is mapped alongside "warning" because Lightpanda emitted the former
        # before upstream #2731.
        CONSOLE_LEVELS = {
          "error" => "SEVERE",
          "assert" => "SEVERE",
          "warning" => "WARNING",
          "warn" => "WARNING",
          "debug" => "DEBUG",
          "trace" => "DEBUG",
        }.freeze

        # Selenium's `driver.logs` accessor. Only the `:browser` type has a
        # meaning here; other Selenium log types (`:driver`, `:client`,
        # `:server`) have no analogue and read as empty rather than raising, so
        # a helper that probes several types still works.
        class Logs
          def initialize(browser)
            @browser = browser
          end

          def get(type = :browser)
            return [] unless type.to_sym == :browser

            @browser.console_logs.map do |entry|
              LogEntry.new(
                CONSOLE_LEVELS.fetch(entry[:type], "INFO"),
                entry[:text],
                entry[:timestamp]
              )
            end
          end

          def available_types
            [:browser]
          end
        end

        # NOTE: unlike Chrome's `getLog`, this does NOT drain the buffer —
        # repeated calls re-report the same entries. Draining would let an
        # earlier reader silently swallow a JS error from a later assertion,
        # and the buffer is already scoped to the session (cleared by
        # Driver#reset!). Use #clear_console_logs for an explicit reset.
        #
        # Not memoized on purpose: Logs holds nothing but a back-reference, and
        # an ivar here would have to be declared in Browser#initialize per the
        # "all ivars initialized in the constructor" rule for these modules.
        def logs
          Logs.new(self)
        end

        # Selenium's `execute_async_script`: the script receives a completion
        # callback as its last argument. Same contract as
        # Driver#evaluate_async_script, minus the DOM-node unwrapping — callers
        # on this path (axe-core et al.) hand back plain JSON.
        def execute_async_script(script, *)
          evaluate_async(script.to_s.strip, *)
        end

        # Selenium's post-hoc `switch_to.alert` cannot be honored: Lightpanda
        # requires the accept/dismiss response to be armed BEFORE the action
        # that opens the dialog (LP.handleJavaScriptDialog, upstream #2261 —
        # Page.handleJavaScriptDialog deliberately errors), so by the time a
        # caller could ask for the alert there is nothing left to answer. Fake
        # it and the dialog silently keeps whatever default it already took.
        # Raise with the migration instead of NoMethodError.
        def switch_to
          raise ::Capybara::NotSupportedByDriverError,
                "Lightpanda arms dialog responses before the triggering action, so Selenium's " \
                "post-hoc switch_to.alert has nothing to act on. Wrap the action instead: " \
                "accept_alert/accept_confirm/accept_prompt (or Driver#accept_modal/#dismiss_modal), " \
                "which pre-arm the response and still expose the dialog text."
        end
      end
    end
  end
end
