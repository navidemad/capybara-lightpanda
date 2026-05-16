# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Hash subclass that downcases the lookup key. CDP returns response headers
    # with lowercased names ("content-type"), but Capybara callers reach for
    # the canonical casing ("Content-Type"). Mirrors capybara-playwright-driver's
    # Headers class (lib/capybara/playwright/page.rb).
    class Headers < Hash
      def [](key)
        super(key.to_s.downcase)
      end
    end
  end
end
