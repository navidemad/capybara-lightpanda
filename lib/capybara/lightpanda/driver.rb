# frozen_string_literal: true

require "forwardable"
require "uri"

module Capybara
  module Lightpanda
    class Driver < ::Capybara::Driver::Base
      extend Forwardable

      attr_reader :app, :options

      delegate %i[current_url title status_code response_headers frame_url frame_title] => :browser

      def initialize(app, options = {})
        super()
        @app = app
        @options = options
        @browser = nil
        @started = false
      end

      def browser
        @browser = nil if @browser && !browser_alive?
        @browser ||= Browser.new(@options)
      end

      def browser_alive?
        !@browser.nil? && @browser.alive?
      end

      # Escape hatch to the underlying Browser for callers that need raw CDP
      # access — e.g. Lightpanda's `LP.*` extensions (`getMarkdown`,
      # `getSemanticTree`, `detectForms`, …) that aren't worth exposing through
      # the Capybara DSL. Mirrors `capybara-playwright-driver`'s
      # `with_playwright_page`. Yields the Browser; returns whatever the block
      # returns.
      #
      #   driver.with_lightpanda_browser do |browser|
      #     browser.page_command("LP.getMarkdown")
      #   end
      def with_lightpanda_browser(&block)
        raise ArgumentError, "block must be given" unless block

        block.call(browser)
      end

      def visit(url)
        @started = true
        browser.go_to(url)
      end

      def go_back
        browser.back
      end

      def go_forward
        browser.forward
      end

      def refresh
        browser.refresh
      end

      def html
        browser.body
      end
      alias body html

      def active_element
        oid = browser.active_element
        oid && Node.new(self, oid)
      end

      # Capybara's Session#send_keys routes to Driver#send_keys; Cuprite's pattern
      # is to fan that out to whatever element currently has focus.
      def send_keys(*keys)
        active_element&.send_keys(*keys)
      end

      def find_xpath(selector)
        object_ids = browser.find("xpath", selector)
        object_ids.map { |oid| Node.new(self, oid) }
      end

      def find_css(selector)
        object_ids = browser.find("css", selector)
        object_ids.map { |oid| Node.new(self, oid) }
      end

      def evaluate_script(script, *args)
        unwrap_script_result(browser.evaluate(script.strip, *native_args(args)))
      end

      def execute_script(script, *args)
        browser.execute(script.strip, *native_args(args))
        nil
      end

      def evaluate_async_script(script, *args)
        unwrap_script_result(browser.evaluate_async(script.strip, *native_args(args)))
      end

      # -- Network Inspection --

      # Network tracker (lazily auto-enabled). Exposes `traffic`, `clear`,
      # `wait_for_idle`, header overrides, etc. Cuprite parity.
      def network
        browser.network
      end

      # Block until in-flight HTTP traffic settles. Auto-enables the tracker
      # on first call so callers don't have to remember to flip it on.
      # Returns true on success, false on timeout.
      def wait_for_network_idle(timeout: 5, connections: 0)
        network.enable
        network.wait_for_idle(timeout: timeout, connections: connections)
      end

      # -- Downloads --
      # Files downloaded since the session started (absolute paths). Capture is
      # on whenever a destination exists (the :save_path driver option, else
      # Capybara.save_path) and the server sends `Content-Disposition:
      # attachment`. Ferrum/Cuprite expose downloads on the driver too.

      def downloads
        browser.downloads.files
      end

      # Block until in-flight downloads finish (or timeout); returns the file
      # list. Click the download trigger first, then call this.
      def wait_for_download(timeout: 5)
        browser.downloads.wait(timeout: timeout)
      end

      # -- Cookie Management --

      def set_cookie(name, value, **options)
        cookie_options = { domain: options[:domain] || default_domain }
        cookie_options[:path] = options[:path] if options[:path]
        cookie_options[:secure] = options[:secure] if options.key?(:secure)
        if options.key?(:httpOnly) || options.key?(:http_only)
          cookie_options[:http_only] =
            options[:httpOnly] || options[:http_only]
        end
        cookie_options[:expires] = options[:expires] if options[:expires]

        browser.cookies.set(name: name, value: value, **cookie_options)
      end

      def clear_cookies
        browser.cookies.clear
      end

      def remove_cookie(name, **)
        browser.cookies.remove(name: name, **)
      end

      # -- Frame Support --
      # Passes Node objects (with remote_object_id) to Browser's frame stack.
      # callFunctionOn on the iframe element scopes finding to its contentDocument.

      def switch_to_frame(frame)
        case frame
        when :top
          browser.clear_frames
        when :parent
          browser.pop_frame
        when Node
          browser.push_frame(frame)
        else
          # Capybara passes a Capybara::Node::Element; extract our driver Node
          browser.push_frame(frame.base)
        end
      end

      # -- Window Support --
      # Single-window driver. Lightpanda's BrowserContext is 1:1:1 with
      # Session/Page/target and rejects a second Target.createTarget with
      # TargetAlreadyLoaded (upstream #1962, maintainer-owned), so there is
      # exactly one window and its handle is the CDP target id.
      #
      # Resizing drives Emulation.setDeviceMetricsOverride, so it is real for
      # window.innerWidth/innerHeight and for what `matchMedia` reports. Two
      # limits worth knowing before writing a responsive spec:
      #
      #   1. It is not layout. Element geometry stays synthetic, so a resize
      #      changes which CSS branch applies, never where anything sits.
      #   2. `@media` rules do NOT re-resolve for the document already on
      #      screen — Lightpanda fixes the cascade at parse time and a metrics
      #      change doesn't invalidate it. So resize, THEN visit:
      #
      #        page.current_window.resize_to(375, 667)
      #        visit "/pricing"   # parses under the new metrics
      #        assert_selector "#mobile-cta"
      #
      #      Resizing without re-visiting leaves `matchMedia` and the rendered
      #      branch disagreeing. See Browser#set_viewport for the verification.

      def current_window_handle
        browser.target_id
      end

      def window_handles
        [browser.target_id]
      end

      def switch_to_window(handle)
        return if handle == browser.target_id

        raise NoSuchPageError, "Window #{handle.inspect} does not exist. " \
                               "Lightpanda supports a single window per session."
      end

      # Capybara's Window#current? rescues this to decide whether a handle is
      # still live, so it must be a class, not a raise.
      def no_such_window_error
        NoSuchPageError
      end

      def window_size(handle)
        assert_current_window!(handle)
        browser.viewport_size
      end

      def resize_window_to(handle, width, height)
        assert_current_window!(handle)
        browser.set_viewport(width, height)
      end

      # No window manager and no layout, so "as large as the screen" has no
      # meaning beyond the configured size. Both reset to it rather than
      # raising, because suites call maximize defensively in setup and a
      # raise there would take out the example before it starts.
      def maximize_window(handle)
        assert_current_window!(handle)
        browser.set_viewport
      end

      alias fullscreen_window maximize_window

      def open_new_window(_kind = :tab)
        raise Capybara::NotSupportedByDriverError,
              "Lightpanda serves a single target per CDP connection (upstream lightpanda-io/browser#1962), " \
              "so a second window cannot be opened. Drive the second page in its own Capybara session instead."
      end

      def close_window(_handle)
        raise Capybara::NotSupportedByDriverError,
              "Lightpanda has a single window per session; closing it would end the session. " \
              "Use Driver#reset! to start a fresh one."
      end

      # -- Modal/Dialog Support --

      # find_modal owns the wait default (browser.options.timeout) — pass
      # wait only when the caller overrode it.
      def accept_modal(type, **options, &block)
        browser.accept_modal(type, text: options[:with])
        block&.call
        browser.find_modal(type, **{ text: options[:text], wait: options[:wait] }.compact)
      end

      def dismiss_modal(type, **options, &block)
        browser.dismiss_modal(type)
        block&.call
        browser.find_modal(type, **{ text: options[:text], wait: options[:wait] }.compact)
      end

      # -- Screenshots --
      # Lightpanda has no rendering engine so screenshots are blank,
      # but we handle the call gracefully so Rails' before_teardown
      # (screenshot on failure) doesn't raise NotSupportedByDriverError.

      def save_screenshot(path, **_options)
        browser.screenshot(path: path)
      rescue BinaryError, BinaryNotFoundError, BrowserError, TimeoutError
        # Browser can't start (version too old), is already dead (DeadBrowserError),
        # the CDP call timed out, or returned any other CDP-level error. Teardown
        # screenshots are best-effort — swallow so the real test failure surfaces
        # instead of a "browser already gone" stack trace.
        nil
      end

      # capybara-screenshot's fallback for unregistered drivers calls
      # `driver.render(path)` (the Cuprite/Ferrum spelling). Without the alias
      # every failed test in a capybara-screenshot suite logged
      # "Screenshot could not be saved: undefined method 'render'".
      alias render save_screenshot

      # -- Headers (Cuprite-compatible driver surface) --
      # Delegates to Network, which lazily enables the Network domain. The
      # overrides do NOT survive reset!: disposing the BrowserContext takes
      # setExtraHTTPHeaders with it, so Network#reset drops its cached copy
      # rather than report headers the browser stopped sending (pinned by
      # network_test.rb "clears extra_headers"). Cuprite exposes these on the
      # driver, and real suites call them there (page.driver.headers = ...).

      def headers
        browser.network.extra_headers
      end

      def headers=(headers)
        browser.network.headers = headers
      end

      def add_headers(headers)
        browser.network.add_headers(headers)
      end

      # -- Lifecycle --

      # Thin Cuprite-style wrapper. The interesting work — disposing the
      # BrowserContext (cookies, storage, all targets) and starting a fresh
      # one — happens in Browser#reset.
      #
      # Rescue is the gem hierarchy plus raw IO escapees only — NOT
      # StandardError: reset! runs between every test, so a blanket rescue
      # turns programmer errors (e.g. a NoMethodError in browser.rb) into a
      # silent quit-and-respawn on every example with zero signal. The warn
      # keeps repeated respawns visible.
      def reset!
        browser.reset
      rescue Error, SystemCallError, IOError => e
        warn "[capybara-lightpanda] reset! failed (#{e.class}: #{e.message}); respawning browser"
        @browser&.quit
        @browser = nil
      ensure
        @started = false
      end

      def quit
        @browser&.quit
        @browser = nil
      end

      def needs_server?
        true
      end

      def wait?
        true
      end

      # Expanded error list for Capybara retry logic (Cuprite pattern).
      # MouseEventFailed is in Cuprite's list, but Lightpanda has no
      # rendering engine and the gem dispatches clicks through JS — the
      # underlying CDP Input.dispatchMouseEvent path doesn't run, so
      # MouseEventFailed is never raised.
      def invalid_element_errors
        [
          NodeNotFoundError,
          NoExecutionContextError,
          ObsoleteNode,
        ]
      end

      # Pause execution for interactive debugging.
      def pause
        if $stdin.tty?
          warn "\nPaused. Press Enter to continue."
          $stdin.gets
        else
          warn "\nPaused. Send SIGCONT (kill -CONT #{::Process.pid}) to continue."
          trap("CONT") {} # rubocop:disable Lint/EmptyBlock
          ::Process.kill("STOP", ::Process.pid)
        end
      end

      private

      # Every window method takes a handle because Capybara's Window objects
      # carry one; with a single window the only valid value is the current
      # target id. Reject anything else rather than silently operating on the
      # wrong window.
      def assert_current_window!(handle)
        return if handle.nil? || handle == browser.target_id

        raise NoSuchPageError, "Window #{handle.inspect} does not exist. " \
                               "Lightpanda supports a single window per session."
      end

      # Unwrap arguments before sending to the browser. Capybara::Node::Element wraps
      # our Lightpanda::Node — pull `.base` out so `serialize_argument` can build
      # `{objectId: …}` for the CDP payload. Cuprite's `native_args` pattern.
      def native_args(args)
        args.map { |a| a.is_a?(Capybara::Node::Element) ? a.base : a }
      end

      # Lightpanda's `Network.setCookie` requires either `domain` or `url`
      # (storage.zig → Cookie.parseDomain). When the caller doesn't supply one,
      # use the host of the current page if any, else `Capybara.app_host`,
      # else loopback. Cuprite parity — lets pre-visit cookie setup just work.
      def default_domain
        candidate = (@started && safe_uri_host(browser.current_url)) ||
                    safe_uri_host(Capybara.app_host)
        candidate || "127.0.0.1"
      end

      def safe_uri_host(url)
        return nil if url.nil? || url.empty? || url == "about:blank"

        URI(url).host
      rescue URI::InvalidURIError
        nil
      end

      # Walk through evaluate-script results turning DOM-node markers (the
      # `{ Browser::NODE_MARKER => "..." }` hashes produced by
      # `Browser#unwrap_call_result`) into Lightpanda::Node instances so
      # Capybara can wrap them as elements.
      def unwrap_script_result(value)
        case value
        when Array then value.map { |v| unwrap_script_result(v) }
        when Hash
          if value.size == 1 && value.key?(Browser::NODE_MARKER)
            Node.new(self, value[Browser::NODE_MARKER])
          else
            value.transform_values { |v| unwrap_script_result(v) }
          end
        else value
        end
      end
    end
  end
end
