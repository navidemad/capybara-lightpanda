# frozen_string_literal: true

require "concurrent-ruby"

module Capybara
  module Lightpanda
    module Utils
      # Concurrent::Event with an iteration counter so callers can detect
      # that the event was reset (e.g. a new navigation started) while they
      # were waiting on it. Mirrors ferrum's Utils::Event.
      #
      # The base Concurrent::Event allows wait/set/reset cycles, but a wait
      # that returns true after a reset → set is indistinguishable from one
      # that returned true on the original set. The iteration counter,
      # bumped on every reset, lets callers compare before and after to
      # tell whether the event was raced by a reset.
      class Event < Concurrent::Event
        def initialize
          super
          @iteration = 0
        end

        def iteration
          synchronize { @iteration }
        end

        def reset
          synchronize do
            @iteration += 1
            @set = false if @set
            @iteration
          end
        end
      end
    end
  end
end
