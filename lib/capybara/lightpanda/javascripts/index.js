(function() {
  if (window._lightpanda) return;

  // --- readystatechange re-dispatch (upstream gap, wishlist A36) ---
  // Lightpanda transitions document.readyState correctly but never fires the
  // readystatechange event. Turbo's PageObserver listens ONLY for that event
  // to reach pageLoaded() — without it, turbo:load never fires. Re-dispatch
  // from the two lifecycle events Lightpanda does fire: DOMContentLoaded
  // (readyState=interactive) and window load (readyState=complete).
  // Drop this block once the upstream fix is covered by MINIMUM_NIGHTLY_BUILD.
  function _fireReadyStateChange() {
    document.dispatchEvent(new Event('readystatechange'));
  }
  document.addEventListener('DOMContentLoaded', _fireReadyStateChange);
  window.addEventListener('load', _fireReadyStateChange);

  // --- Turbo activity tracking ---
  // Tracks pending Turbo operations so the driver can wait for Turbo to settle.
  // Inspired by the CapybaraLockstep approach for stabilizing Turbo integration tests.
  // Events are not perfectly symmetrical in Turbo, so we track multiple pairs
  // and use a counter to handle overlapping operations.
  //
  // Transitions across 0 emit `__lightpanda_turbo_busy` / `__lightpanda_turbo_idle`
  // sentinels via console.debug. Browser#wait_for_turbo subscribes to those
  // sentinels (Runtime.consoleAPICalled) and toggles a Concurrent::Event so the
  // Ruby side can wait event-driven instead of polling.
  //
  // Pages without Turbo never trigger _turboStart, so no sentinels fire and the
  // Ruby Event stays set (idle by default) — wait_for_turbo returns immediately.
  var _pendingTurboOps = 0;
  function _signalTurbo(state) {
    try { console.debug('__lightpanda_turbo_' + state); } catch (e) {}
  }
  function _turboStart() {
    _pendingTurboOps++;
    if (_pendingTurboOps === 1) _signalTurbo('busy');
  }
  function _turboEnd() {
    if (_pendingTurboOps > 0) {
      _pendingTurboOps--;
      if (_pendingTurboOps === 0) _signalTurbo('idle');
    }
  }

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

  // Drive page visits: turbo:load fires after the page is fully rendered.
  // Also serves as a safety reset — clears any counter leaks from aborted fetches.
  // Always re-signal idle so the Ruby Event re-arms even if some `_turboEnd`
  // call dropped on the floor mid-navigation.
  document.addEventListener('turbo:load', function() {
    _pendingTurboOps = 0;
    _signalTurbo('idle');
  });

  // --- Main API ---

  window._lightpanda = {
    turbo: {
      pending: function() { return _pendingTurboOps; },
      idle: function() { return _pendingTurboOps <= 0; }
    },

    // --- DOM visibility / state predicates ---
    // Centralized so node.rb's predicate methods (visible?, obscured?, disabled?)
    // and the visible_text walker share one implementation of the ancestor
    // cascade. Available in iframes too because index.js is registered via
    // Page.addScriptToEvaluateOnNewDocument.

    // Returns true if `el` is visible per Capybara's semantics. Lightpanda's
    // `checkVisibility()` walks ancestors and rejects `display:none` from
    // inline styles, stylesheets, and the UA sheet (PR #2294 — covers
    // HEAD/SCRIPT/STYLE/NOSCRIPT/TEMPLATE/TITLE, `[hidden]`, `[type=hidden]`,
    // closed-<details> children). `visibility:hidden|collapse` is handled
    // separately because checkVisibility's defaults (per spec) ignore it.
    //
    // Intentional upstream out-of-scope (upstream-wishlist.md C10):
    // Lightpanda is a headless agentic browser and deliberately doesn't
    // load external `<link rel=stylesheet>` or apply `@media` rules to
    // the cascade, and `matchMedia()` returns false for every query.
    // Responsive patterns that hide one of two mobile/desktop CTA
    // duplicates via `@media (min-width: …) { display: none }` leak
    // both variants past this check — Capybara then raises
    // `Ambiguous: found 2 elements`. There is no in-gem fix: rebuilding
    // the CSS cascade in JS would need a CSS parser, sync access to
    // remote stylesheets, and a real media-query evaluator. Run
    // cuprite for responsive-UI assertions.
    isVisible: function(el) {
      if (!el || el.nodeType !== 1) return false;
      var win = el.ownerDocument.defaultView || window;
      var style = win.getComputedStyle(el);
      if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
      return el.checkVisibility();
    },

    // Returns true if the element is obscured at its center point — i.e.
    // hit-testing elementFromPoint at the center returns something that is
    // not the element or its descendant. `visibility:hidden|collapse` is
    // short-circuited explicitly because those elements still produce a
    // layout box (so the rect-zero check below can't catch them); every
    // other "not rendered" case (display:none, [hidden], descendants of
    // either) falls out naturally because getBoundingClientRect returns
    // DOMRect{0,0,0,0} for elements with no layout box.
    isObscured: function(el) {
      var doc = el.ownerDocument;
      var win = doc.defaultView || window;
      var style = win.getComputedStyle(el);
      if (style.visibility === 'hidden' || style.visibility === 'collapse') return true;
      var r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return true;
      var cx = r.left + (r.width / 2);
      var cy = r.top + (r.height / 2);
      var w = win.innerWidth || doc.documentElement.clientWidth;
      var h = win.innerHeight || doc.documentElement.clientHeight;
      if (cx < 0 || cy < 0 || cx > w || cy > h) return true;
      var hit = doc.elementFromPoint(cx, cy);
      if (!hit) return true;
      if (hit === el) return false;
      return !el.contains(hit);
    },

    // Capybara's `Node#disabled?` is more permissive than CSS `:disabled`:
    // an `<option>` inside a disabled `<select>` or a disabled `<fieldset>`
    // is reported as disabled, even though those don't match CSS `:disabled`
    // per the HTML spec. Mirrors Cuprite's behavior so the shared specs pass.
    isDisabled: function(el) {
      if (el.matches && el.matches(':disabled')) return true;
      if ((el.tagName || '').toUpperCase() === 'OPTION') {
        var p = el.parentElement;
        while (p) {
          if (p.disabled) return true;
          p = p.parentElement;
        }
      }
      return false;
    },

    // True if the element is the host of a contenteditable region: it (or any
    // ancestor) has a non-"false" `contenteditable` attribute. Lightpanda's
    // native `HTMLElement.isContentEditable` (PR #2310) is hardwired to return
    // `false` for every element — it has no caret/keyboard editing pipeline —
    // so the IDL property is useless here and we walk ancestors ourselves.
    isContentEditable: function(el) {
      var n = el;
      while (n && n.nodeType === 1) {
        if (n.hasAttribute && n.hasAttribute('contenteditable')) {
          var v = (n.getAttribute('contenteditable') || '').toLowerCase();
          return v !== 'false';
        }
        n = n.parentElement;
      }
      return false;
    },

    // Walk descendants and accumulate text from visible nodes only. Inserts
    // newlines around block-display containers so paragraphs/lists render with
    // natural breaks (Capybara expects this from Chrome's innerText).
    // Lightpanda's innerText returns textContent verbatim (no rendering, so no
    // hidden-descendant filtering), so we DIY the visibility filtering here.
    visibleText: function(el) {
      var BLOCK_DISP = { BLOCK:1, FLEX:1, GRID:1, 'LIST-ITEM':1, TABLE:1, 'TABLE-ROW':1,
                         'TABLE-CAPTION':1, 'TABLE-CELL':1 };
      var BLOCK_TAG = { ADDRESS:1, ARTICLE:1, ASIDE:1, BLOCKQUOTE:1, DETAILS:1, DIALOG:1,
                        DIV:1, DL:1, DT:1, DD:1, FIELDSET:1, FIGCAPTION:1, FIGURE:1,
                        FOOTER:1, FORM:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, HEADER:1,
                        HGROUP:1, HR:1, LI:1, MAIN:1, NAV:1, OL:1, P:1, PRE:1, SECTION:1,
                        TABLE:1, TR:1, UL:1 };
      var self = this;

      // Collapse runs of ASCII whitespace (preserving NBSP) to a single space —
      // matches Chrome's innerText whitespace handling for text nodes.
      function normText(s) {
        return s.replace(/[\t\n\r\f\v ]+/g, ' ');
      }

      function walk(node) {
        if (node.nodeType === 3) return normText(node.nodeValue);
        // DocumentFragment / ShadowRoot — no element of its own to test
        // for visibility, just walk children.
        if (node.nodeType === 11) {
          var fout = '';
          for (var k = 0; k < node.childNodes.length; k++) fout += walk(node.childNodes[k]);
          return fout;
        }
        if (node.nodeType !== 1) return '';
        if (!self.isVisible(node)) return '';
        var tag = (node.tagName || '').toUpperCase();
        if (tag === 'TEXTAREA') return node.value || '';
        if (tag === 'BR') return '\n';
        var win = node.ownerDocument.defaultView || window;
        var style = win.getComputedStyle(node);
        var disp = (style.display || '').toUpperCase();
        var isBlock = BLOCK_DISP[disp] || BLOCK_TAG[tag];
        var out = '';
        for (var i = 0; i < node.childNodes.length; i++) {
          out += walk(node.childNodes[i]);
        }
        // Block-level elements get wrapped in \n…\n only when they actually
        // contribute visible text. An empty <div> between two inline siblings
        // would otherwise introduce a phantom line break that Chrome's
        // innerText algorithm collapses out (required line breaks around
        // empty blocks coalesce in the line-collapse pass).
        if (isBlock && /\S/.test(out)) out = '\n' + out + '\n';
        return out;
      }

      return walk(el);
    }
  };
})();
