# frozen_string_literal: true

module Capybara
  module Lightpanda
    module Utils
      module_function

      def with_retry(errors:, max: 3, wait: 0.1)
        attempts = 0
        begin
          yield
        rescue *errors
          attempts += 1
          raise if attempts >= max

          sleep(wait)
          retry
        end
      end
    end
  end
end
