# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Logger
      attr_reader :output

      def initialize(output = nil)
        @output = output
        @suppressed = false
        @started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def puts(message)
        return if @suppressed || @output.nil?

        @output.puts(message)
      end

      def suppress
        prev = @suppressed
        @suppressed = true
        yield
      ensure
        @suppressed = prev
      end

      def suppressed?
        @suppressed
      end

      def elapsed_time
        format("%.3fs", ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - @started_at)
      end
    end
  end
end
