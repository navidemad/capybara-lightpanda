# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Patches to Lightpanda::Browser#go_to to handle pages where
    # Page.loadEventFired never fires (known Lightpanda limitation).
    #
    # See: lightpanda-io/browser#1801, lightpanda-io/browser#1832
    module BrowserExt
      def go_to(url, wait: true)
        enable_page_events

        if wait
          loaded = Concurrent::Event.new

          handler = proc { loaded.set }
          @client.on("Page.loadEventFired", &handler)

          result = page_command("Page.navigate", url: url)

          unless loaded.wait(@options.timeout)
            poll_ready_state(@options.timeout)
          end

          @client.off("Page.loadEventFired", handler)

          result
        else
          page_command("Page.navigate", url: url)
        end
      end

      private

      def poll_ready_state(timeout)
        deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
        loop do
          ready = evaluate("document.readyState") rescue nil
          break if ready == "complete" || ready == "interactive"
          break if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
        end
      end
    end
  end
end
