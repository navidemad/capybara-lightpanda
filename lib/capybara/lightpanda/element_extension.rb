# frozen_string_literal: true

# Escape hatch onto Capybara::Node::Element so users can reach our driver-level
# Node (and its remote_object_id, `call`, etc.) without going through
# `element.base`. Mirrors capybara-playwright-driver's
# `with_playwright_element_handle` (lib/capybara/playwright/node.rb). The is_a?
# guard keeps the patch safe when both this gem and another Capybara driver
# are loaded in the same process.
module Capybara
  module Lightpanda
    module ElementExtension
      def with_lightpanda_node(&block)
        raise ArgumentError, "block must be given" unless block
        raise "#{base.inspect} is not a Capybara::Lightpanda::Node" unless base.is_a?(Capybara::Lightpanda::Node)

        block.call(base)
      end
    end
  end
end
Capybara::Node::Element.prepend(Capybara::Lightpanda::ElementExtension)
