# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Lightweight metadata view of a CDP frame, populated from
    # Page.frameAttached / Page.frameNavigated / Page.frame{Started,Stopped}Loading
    # events. Mirrors a subset of ferrum's Frame.
    #
    # NOTE: this is purely introspection — Lightpanda's frame loading events
    # are not reliable enough to drive `wait_for_navigation` (#1801, #1832),
    # so the gem still drives navigation waits via Page.loadEventFired with
    # readyState polling. The frame map is useful for diagnostics, listing
    # iframes, and resolving frame metadata (name/URL) without callFunctionOn.
    class Frame
      STATES = %i[started_loading navigated stopped_loading detached].freeze

      attr_reader :id, :parent_id
      attr_accessor :name, :url, :state

      def initialize(id, parent_id = nil, name: nil, url: nil)
        @id = id
        @parent_id = parent_id
        @name = name
        @url = url
        @state = nil
      end

      def main?
        @parent_id.nil?
      end
    end
  end
end
