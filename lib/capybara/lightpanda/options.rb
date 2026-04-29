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
      DEFAULT_PORT = 9222
      DEFAULT_WINDOW_SIZE = [1024, 768].freeze

      attr_accessor :host, :port, :timeout, :handshake_timeout, :process_timeout,
                    :window_size, :browser_path, :headless, :logger
      attr_writer :ws_url

      def initialize(options = {})
        @host = options.fetch(:host, DEFAULT_HOST)
        @port = options.fetch(:port, DEFAULT_PORT)
        @timeout = options.fetch(:timeout, DEFAULT_TIMEOUT)
        @handshake_timeout = options.fetch(:handshake_timeout, DEFAULT_HANDSHAKE_TIMEOUT)
        @process_timeout = options.fetch(:process_timeout, DEFAULT_PROCESS_TIMEOUT)
        @window_size = options.fetch(:window_size, DEFAULT_WINDOW_SIZE)
        @browser_path = options[:browser_path]
        @headless = options.fetch(:headless, true)
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
        }
        h[:ws_url] = @ws_url if @ws_url
        h
      end

      private

      def parse_logger(logger)
        return logger if logger.is_a?(Capybara::Lightpanda::Logger)
        return Capybara::Lightpanda::Logger.new(logger) if logger
        return Capybara::Lightpanda::Logger.new($stdout.tap { |s| s.sync = true }) if ENV["LIGHTPANDA_DEBUG"]

        Capybara::Lightpanda::Logger.new
      end
    end
  end
end
