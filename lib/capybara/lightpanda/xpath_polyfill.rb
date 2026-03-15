# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Simplified XPath polyfill for Lightpanda.
    #
    # Lightpanda does not implement the XPath Web APIs (document.evaluate,
    # XPathResult). Since Capybara converts all selectors to XPath internally
    # (find, click_on, fill_in, assert_selector, etc.), the driver is unusable
    # without this polyfill.
    #
    # The polyfill provides a best-effort XPath → CSS conversion that covers
    # ~80% of the XPath expressions Capybara generates. Complex XPath (axes,
    # function predicates) will fall back to an empty result.
    #
    # Must be re-injected after every navigation because the JS context is
    # lost between pages.
    module XPathPolyfill
      JS = <<~JAVASCRIPT
        if (typeof XPathResult === 'undefined') {
          window.XPathResult = {
            ORDERED_NODE_SNAPSHOT_TYPE: 7,
            FIRST_ORDERED_NODE_TYPE: 9
          };
          if (!document.evaluate) {
            document.evaluate = function(expression, contextNode) {
              var nodes = [];
              try {
                var css = expression
                  .replace(/^\\.\\//g, '')
                  .replace(/\\/\\//g, '')
                  .replace(/\\[@/g, '[')
                  .replace(/\\//g, ' > ');
                if (css.startsWith(' > ')) css = css.substring(3);
                nodes = Array.from(contextNode.querySelectorAll(css));
              } catch(e) {
                nodes = [];
              }
              if (nodes.length === 0 && expression === '/html') {
                nodes = [document.documentElement];
              }
              return {
                snapshotLength: nodes.length,
                snapshotItem: function(i) { return nodes[i] || null; },
                singleNodeValue: nodes[0] || null
              };
            };
          }
        }
      JAVASCRIPT
    end
  end
end
