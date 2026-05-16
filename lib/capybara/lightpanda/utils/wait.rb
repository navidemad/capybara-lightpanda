# frozen_string_literal: true

module Capybara
  module Lightpanda
    module Utils
      # Block-based polling helper. Borrowed from selenium-webdriver's
      # Wait class (rb/lib/selenium/webdriver/common/wait.rb). Sibling
      # of Utils::Attempt — Attempt retries on a specific error class,
      # Wait loops until the block returns truthy.
      module Wait
        DEFAULT_INTERVAL = 0.1

        # Polls the block until it returns a truthy value or `timeout`
        # seconds elapse. Exceptions whose class is listed in `ignore`
        # are swallowed between polls; the most recent one is appended
        # to the timeout message so the failure stays diagnosable.
        #
        # @raise [Capybara::Lightpanda::TimeoutError] if the block never
        #   returns truthy within `timeout` seconds.
        # @return the truthy value returned by the block.
        def self.until(timeout:, interval: DEFAULT_INTERVAL, ignore: [], message: nil)
          deadline = monotonic_time + timeout
          last_error = nil
          loop do
            begin
              result = yield
              return result if result
            rescue *Array(ignore) => e
              last_error = e
            end

            break if monotonic_time > deadline

            sleep interval
          end

          msg = message || "timed out after #{timeout}s"
          msg = "#{msg} (#{last_error.message})" if last_error
          raise Capybara::Lightpanda::TimeoutError, msg
        end

        def self.monotonic_time
          ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
