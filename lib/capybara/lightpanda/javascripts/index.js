(function() {
  if (window._lightpanda) return;

  // --- Turbo activity tracking ---
  // Tracks pending Turbo operations so the driver can wait for Turbo to settle.
  // Inspired by the CapybaraLockstep approach for stabilizing Turbo integration tests.
  // Events are not perfectly symmetrical in Turbo, so we track multiple pairs
  // and use a counter to handle overlapping operations.
  var _pendingTurboOps = 0;
  function _turboStart() { _pendingTurboOps++; }
  function _turboEnd() { if (_pendingTurboOps > 0) _pendingTurboOps--; }

  // Fetch requests (covers Drive, Frames, and Form submission fetches)
  document.addEventListener('turbo:before-fetch-request', _turboStart);
  document.addEventListener('turbo:before-fetch-response', _turboEnd);
  document.addEventListener('turbo:fetch-request-error', _turboEnd);

  // Form submissions (can outlast their underlying fetch)
  document.addEventListener('turbo:submit-start', _turboStart);
  document.addEventListener('turbo:submit-end', _turboEnd);

  // Frame rendering (can outlast the fetch that triggered it)
  document.addEventListener('turbo:before-frame-render', _turboStart);
  document.addEventListener('turbo:frame-render', _turboEnd);

  // Stream rendering (no symmetric end event — wrap the render function)
  document.addEventListener('turbo:before-stream-render', function(event) {
    _turboStart();
    if (event.detail && event.detail.render) {
      var originalRender = event.detail.render;
      event.detail.render = function(streamElement) {
        var result = originalRender(streamElement);
        if (result && typeof result.then === 'function') {
          return result.finally(_turboEnd);
        }
        _turboEnd();
        return result;
      };
    } else {
      _turboEnd();
    }
  });

  // --- Main API ---

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
    },

    turbo: {
      pending: function() { return _pendingTurboOps; },
      idle: function() { return _pendingTurboOps <= 0; }
    }
  };

  // --- XPathResult polyfill ---

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

  // --- requestSubmit polyfill ---
  // Required for Turbo form interception. Turbo listens for the `submit` event,
  // but form.submit() doesn't fire it. requestSubmit() does.

  if (typeof HTMLFormElement !== 'undefined' && !HTMLFormElement.prototype.requestSubmit) {
    HTMLFormElement.prototype.requestSubmit = function(submitter) {
      if (submitter) {
        var validTypes = {submit: 1, image: 1};
        if (!validTypes[(submitter.type || '').toLowerCase()]) {
          throw new TypeError('The specified element is not a submit button.');
        }
        if (submitter.form !== this) {
          throw new DOMException('The specified element is not owned by this form element.', 'NotFoundError');
        }
      }
      var event;
      if (typeof SubmitEvent === 'function') {
        event = new SubmitEvent('submit', {bubbles: true, cancelable: true, submitter: submitter || null});
      } else {
        event = new Event('submit', {bubbles: true, cancelable: true});
        event.submitter = submitter || null;
      }
      if (this.dispatchEvent(event)) {
        this.submit();
      }
    };
  }
})();
