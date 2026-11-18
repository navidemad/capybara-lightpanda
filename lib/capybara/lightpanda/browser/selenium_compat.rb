# frozen_string_literal: true

require "date"

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
      # Scope grows only when a real-app helper needs an entry point, each one
      # pinned by test/compatibility/selenium_contract.rb: alias what maps
      # cleanly onto an existing API, and raise something *actionable* where
      # the underlying model genuinely differs (see #switch_to). Mirroring
      # Selenium's API for its own sake is not a goal.
      module SeleniumCompat
        # Alchemy's picture overlay queues navigation keys for whichever
        # element has focus when the caller performs the actions.
        class KeyboardActions
          NAVIGATION_KEYS = { arrow_left: :left, arrow_right: :right, arrow_up: :up, arrow_down: :down,
                              left: :left, right: :right, up: :up, down: :down, enter: :numpad_enter, }.freeze

          def initialize(browser)
            @browser = browser
            @keys = []
          end

          def send_keys(*keys)
            @keys.concat(keys.flatten.map do |key|
              NAVIGATION_KEYS.fetch(key) do
                raise ::Capybara::NotSupportedByDriverError, "Keyboard actions support the arrow keys and Enter"
              end
            end)
            self
          end

          def perform
            unless @keys.empty?
              @browser.keyboard.type(*@keys)
              @keys.clear
              @browser.wait_for_idle
            end
            nil
          end
        end

        def action
          KeyboardActions.new(self)
        end

        # Selenium’s browser log includes console output and uncaught JavaScript errors.
        # `level` is the Selenium severity string ("SEVERE"/"WARNING"/…), not
        # the CDP console type, because that is what callers compare against.
        # `timestamp` is wall-clock epoch milliseconds, as in Selenium, and
        # `time`/`as_json`/`to_s` mirror Selenium::WebDriver::LogEntry.
        LogEntry = Struct.new(:level, :message, :timestamp) do
          def time
            Time.at(timestamp / 1000)
          end

          def as_json(*)
            { "timestamp" => timestamp, "level" => level, "message" => message }
          end

          def to_s
            "#{time} #{level}: #{message}"
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

            console = @browser.console_logs.map do |entry|
              LogEntry.new(
                CONSOLE_LEVELS.fetch(entry[:type], "INFO"),
                entry[:text],
                entry[:received_at]
              )
            end
            errors = @browser.page_errors.map do |error|
              prefix = error[:kind] == "unhandledrejection" ? "Uncaught (in promise)" : "Uncaught"
              message = [error[:url], prefix, error[:message]].reject(&:empty?).join(" ")
              LogEntry.new("SEVERE", message, error[:received_at])
            end
            (console + errors).sort_by { |entry| entry.timestamp || 0 }
          end

          def available_types
            [:browser]
          end
        end

        # NOTE: unlike Chrome's `getLog`, this does NOT drain the buffer —
        # repeated calls re-report the same entries. Draining would let an
        # earlier reader silently swallow a JS error from a later assertion,
        # and the buffer is already scoped to the session (cleared by
        # Driver#reset!). Native callers can clear each source with
        # #clear_console_logs and #clear_page_errors.
        #
        # Not memoized on purpose: Logs holds nothing but a back-reference, and
        # an ivar here would have to be declared in Browser#initialize per the
        # "all ivars initialized in the constructor" rule for these modules.
        def logs
          Logs.new(self)
        end

        # Lightpanda's single virtual window has a fixed origin. Resizing
        # changes the viewport used by matchMedia and by the next document.
        class Window
          def initialize(browser)
            @browser = browser
          end

          def resize_to(width, height)
            width = Integer(width)
            height = Integer(height)
            unless [width, height].all? { |value| value.between?(0, (2**31) - 1) }
              error = if defined?(::Selenium::WebDriver::Error::InvalidArgumentError)
                        ::Selenium::WebDriver::Error::InvalidArgumentError
                      else
                        ArgumentError
                      end
              raise error, "Window dimensions must be nonnegative 32-bit signed integers"
            end
            if width.zero? || height.zero?
              raise ::Capybara::NotSupportedByDriverError, "Lightpanda cannot represent a zero-sized viewport"
            end

            @browser.set_viewport(width, height)
            { "x" => 0, "y" => 0, "width" => width, "height" => height }
          end
        end

        # Chromium's per-page destination, used by Rails download helpers.
        def download_path=(path)
          path = path.to_path if path.respond_to?(:to_path)
          path = path.to_s if path.is_a?(Symbol)
          unless path.is_a?(String)
            error = if defined?(::Selenium::WebDriver::Error::InvalidArgumentError)
                      ::Selenium::WebDriver::Error::InvalidArgumentError
                    else
                      ArgumentError
                    end
            raise error, "download_path must be a directory path"
          end

          downloads.download_path = File.absolute_path(path)
          {}
        end

        # WebDriver's cookie commands operate on the active document. The native
        # cookie jar spans the whole browser context, including other hosts.
        class Manager
          def initialize(browser)
            @browser = browser
          end

          def window
            Window.new(@browser)
          end

          def all_cookies
            document_cookies.map do |raw|
              cookie = Cookies::Cookie.new(raw)
              { name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                expires: cookie.expires&.utc&.to_datetime, secure: cookie.secure?, http_only: cookie.httponly?,
                same_site: cookie.same_site || "Lax", }
            end
          end

          def cookie_named(name)
            cookie = all_cookies.find { |entry| entry[:name] == name }
            return cookie if cookie

            error = if defined?(::Selenium::WebDriver::Error::NoSuchCookieError)
                      ::Selenium::WebDriver::Error::NoSuchCookieError
                    else
                      NoSuchCookieError
                    end
            raise error, "No cookie named #{name.inspect} for the current document"
          end

          def delete_all_cookies
            # Network.deleteCookies strips the leading dot and can remove a
            # parent host's private cookie with the same name and path.
            url = @browser.frame_url
            expired = document_cookies(url).map do |cookie|
              scope = cookie.fetch("domain").start_with?(".") ? { domain: cookie["domain"] } : { url: url }
              cookie.slice("name", "value", "path", "secure", "httpOnly").merge(scope, expires: 1)
            end
            @browser.execute_cdp("Network.setCookies", cookies: expired) unless expired.empty?
            nil
          end

          private

          def document_cookies(url = @browser.frame_url)
            @browser.execute_cdp("Network.getCookies", urls: [url]).fetch("cookies")
          end
        end

        def manage
          Manager.new(self)
        end

        # Selenium's `execute_async_script`: the script receives a completion
        # callback as its last argument. Same contract as
        # Driver#evaluate_async_script, minus the DOM-node unwrapping — callers
        # on this path (axe-core et al.) hand back plain JSON. Runs in the
        # current frame, as Selenium's does.
        def execute_async_script(script, *)
          evaluate_async(script.to_s.strip, *, frame: frame_stack.last)
        end

        # Selenium's raw-CDP escape hatch,
        # `page.driver.browser.execute_cdp(method, **params)`. The parameters
        # are Lightpanda's, not Chrome's: a suite's
        # `execute_cdp("Network.setBlockedURLs", urls: [...])` gets InvalidParams,
        # because Lightpanda takes only
        # `urlPatterns: [{ urlPattern: "*.png", block: true }]`. That list is
        # also browser-wide and survives `reset!`, so clear it
        # (`urlPatterns: []`) when the test that set it is done.
        # Scoped to the page session, matching Selenium — that covers the
        # Page / Runtime / DOM / Network / Emulation domains a suite would
        # reach for. Browser-scoped commands (Target.*, Browser.*) still go
        # through Browser#command.
        #
        # Deliberately unvalidated: the point is to reach CDP surface the gem
        # has not wrapped yet, so an unknown method should fail with
        # Lightpanda's own error rather than one of ours.
        def execute_cdp(method, **params)
          page_command(method.to_s, **params)
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
