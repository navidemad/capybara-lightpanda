# frozen_string_literal: true

require_relative "logger"

module Capybara
  module Lightpanda
    class Options
      DEFAULT_TIMEOUT = ENV.fetch("LIGHTPANDA_DEFAULT_TIMEOUT", 15).to_i
      DEFAULT_PROCESS_TIMEOUT = ENV.fetch("LIGHTPANDA_PROCESS_TIMEOUT", 10).to_i
      # Bounded budget for the WebSocket TCP+Upgrade handshake. Distinct from
      # `timeout` (per-CDP-command budget) because a handshake either succeeds
      # in a few hundred ms or won't — bleeding the full command budget into
      # it just delays the eventual failure.
      DEFAULT_HANDSHAKE_TIMEOUT = ENV.fetch("LIGHTPANDA_HANDSHAKE_TIMEOUT", 5).to_i
      DEFAULT_HOST = "127.0.0.1"
      # 0 = OS-assigned ephemeral port. Lightpanda logs the address it
      # actually bound and Process#wait_for_ready parses it back, so every
      # driver instance — including each parallel test worker — gets its own
      # free port with zero configuration. Pin a fixed port via
      # `Capybara::Lightpanda.configure { |c| c.port = 9222 }` when external
      # tooling needs a known address.
      DEFAULT_PORT = 0
      # Mirrors Lightpanda's own `Viewport.default` (1920x1080) rather than
      # Cuprite's 1024x768. window_size is applied for real now (see below), so
      # a 1024x768 default would silently shrink the viewport of every existing
      # suite and flip `@media` branches under them. Matching the browser's
      # native default keeps `window_size` truthful AND leaves default
      # behavior byte-identical to before it was wired up.
      DEFAULT_WINDOW_SIZE = [1920, 1080].freeze

      # window_size drives Emulation.setDeviceMetricsOverride via
      # Browser#set_viewport on every create_page. This is a JS-visible
      # viewport only — it sets window.innerWidth/innerHeight and the viewport
      # that `matchMedia` / `@media` evaluate against, so responsive branches
      # resolve at the size you ask for. It is NOT real layout: Lightpanda has
      # no rendering engine, so getBoundingClientRect stays synthetic and
      # nothing reflows. Sizing down will not make an off-viewport element
      # report as obscured.
      # headless is accepted for Cuprite drop-in compatibility but inert —
      # headless is the only mode Lightpanda runs in.
      # save_path: directory for downloaded files (Cuprite parity). nil falls
      # back to Capybara.save_path at create_page time; downloads stay off when
      # both are nil (Browser#create_page only opts in when a path exists).
      attr_accessor :host, :port, :timeout, :handshake_timeout, :process_timeout,
                    :window_size, :browser_path, :headless, :logger, :save_path
      attr_writer :ws_url

      def initialize(options = {})
        @host = options.fetch(:host, DEFAULT_HOST)
        @port = options.fetch(:port, DEFAULT_PORT)
        @timeout = options.fetch(:timeout, DEFAULT_TIMEOUT)
        @handshake_timeout = options.fetch(:handshake_timeout, DEFAULT_HANDSHAKE_TIMEOUT)
        @process_timeout = options.fetch(:process_timeout, DEFAULT_PROCESS_TIMEOUT)
        @window_size = validate_window_size(options.fetch(:window_size, DEFAULT_WINDOW_SIZE))
        @browser_path = options[:browser_path]
        @headless = options.fetch(:headless, true)
        @save_path = options[:save_path]
        @ws_url = options[:ws_url]
        @logger = parse_logger(options[:logger])
      end

      def ws_url
        @ws_url || "ws://#{host}:#{port}/"
      end

      def ws_url?
        !@ws_url.nil?
      end

      def to_h
        h = {
          host: host,
          port: port,
          timeout: timeout,
          handshake_timeout: handshake_timeout,
          process_timeout: process_timeout,
          window_size: window_size,
          browser_path: browser_path,
          headless: headless,
          logger: logger,
          save_path: save_path,
        }
        h[:ws_url] = @ws_url if @ws_url
        h
      end

      private

      # Validated here rather than at apply time so a bad value fails before
      # Browser#initialize spawns a Lightpanda process — raising later would
      # orphan it. Upstream reads a 0 dimension as "keep the current one", so
      # forwarding junk would half-apply a viewport instead of failing.
      def validate_window_size(size)
        width, height = size
        return size if width.is_a?(Integer) && height.is_a?(Integer) && width.positive? && height.positive?

        raise ArgumentError, "window_size must be [width, height] of positive Integers, got #{size.inspect}"
      end

      def parse_logger(logger)
        return logger if logger.is_a?(Capybara::Lightpanda::Logger)
        return Capybara::Lightpanda::Logger.new(logger) if logger
        return Capybara::Lightpanda::Logger.new($stdout.tap { |s| s.sync = true }) if ENV["LIGHTPANDA_DEBUG"]

        Capybara::Lightpanda::Logger.new
      end
    end
  end
end
