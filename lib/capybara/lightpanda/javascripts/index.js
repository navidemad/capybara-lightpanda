(function() {
  if (window._lightpanda) return;

  window._lightpanda = {
    // XPath polyfill: converts XPath expressions to CSS selectors (~80% coverage).
    // Used for finding elements since Lightpanda lacks native XPath support.
    xpathFind: function(expression, contextNode) {
      if (typeof contextNode.evaluate === 'function' && typeof XPathResult !== 'undefined' &&
          !XPathResult._polyfilled) {
        try {
          var result = contextNode.evaluate(expression, contextNode, null,
            XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
          var nodes = [];
          for (var i = 0; i < result.snapshotLength; i++) {
            nodes.push(result.snapshotItem(i));
          }
          return nodes;
        } catch(e) {
          return [];
        }
      }

      try {
        var css = expression
          .replace(/^\.\//g, '')
          .replace(/\/\//g, '')
          .replace(/\[@/g, '[')
          .replace(/\//g, ' > ');
        if (css.startsWith(' > ')) css = css.substring(3);
        var found = Array.from(contextNode.querySelectorAll(css));
        if (found.length === 0 && expression === '/html') {
          found = [contextNode.documentElement || document.documentElement];
        }
        return found;
      } catch(e) {
        return [];
      }
    }
  };

  // Install XPath polyfill globals if needed
  if (typeof XPathResult === 'undefined') {
    window.XPathResult = {
      ORDERED_NODE_SNAPSHOT_TYPE: 7,
      FIRST_ORDERED_NODE_TYPE: 9,
      _polyfilled: true
    };
  }
  if (!document.evaluate) {
    document.evaluate = function(expression, contextNode) {
      var nodes = window._lightpanda.xpathFind(expression, contextNode);
      return {
        snapshotLength: nodes.length,
        snapshotItem: function(i) { return nodes[i] || null; },
        singleNodeValue: nodes[0] || null
      };
    };
  }
})();
