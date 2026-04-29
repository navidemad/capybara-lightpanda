# frozen_string_literal: true

module Capybara
  module Lightpanda
    module Utils
      # Generic retry helper for transient CDP-class errors. Mirrors ferrum's
      # Utils::Attempt — extracted so callsites don't have to rebuild the
      # rescue/sleep loop. Default `max` and `wait` match ferrum's
      # INTERMITTENT_ATTEMPTS / INTERMITTENT_SLEEP so behavior is predictable
      # across the two ecosystems.
      module Attempt
        INTERMITTENT_ATTEMPTS = 6
        INTERMITTENT_SLEEP = 0.1

        def self.with_retry(errors:, max: INTERMITTENT_ATTEMPTS, wait: INTERMITTENT_SLEEP)
          attempts = 0
          begin
            yield
          rescue *Array(errors)
            attempts += 1
            raise if attempts >= max

            sleep wait
            retry
          end
        end
      end
    end
  end
end
