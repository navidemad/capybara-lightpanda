// --- DOM visibility / state predicates ---
// Centralized so node.rb's predicate methods (visible?, obscured?, disabled?)
// and the visible_text walker share one implementation of the ancestor
// cascade. Available in iframes too because the bundle is registered via
// Page.addScriptToEvaluateOnNewDocument.
//
// These are bare top-level function declarations — attach.js exposes them on
// window._lightpanda. They reference each other by name (visibleText calls
// isVisible), not through `this`, so they keep working when node.rb invokes
// `_lightpanda.visibleText(this)` with `this` bound to a DOM element by CDP.

// Returns true if `el` is visible per Capybara's semantics. Lightpanda's
// `checkVisibility()` walks ancestors and rejects `display:none` from
// inline styles, stylesheets, and the UA sheet (PR #2294 — covers
// HEAD/SCRIPT/STYLE/NOSCRIPT/TEMPLATE/TITLE, `[hidden]`, `[type=hidden]`,
// closed-<details> children). `visibility:hidden|collapse` is handled
// separately because checkVisibility's defaults (per spec) ignore it.
//
// External `<link rel=stylesheet>` ARE fetched and applied — the gem
// always passes `--load-resources stylesheet` (Lightpanda PR #2487,
// guaranteed by the build floor) — so stylesheet-driven `display:none`
// participates in this check. `@media` rules evaluate against the
// emulated viewport (`window_size`, 1920×1080 by default), so a
// mobile-only CTA under `@media (max-width: …)` needs a narrow
// `window_size` — or `resize_to` then `visit`, since a loaded document's
// cascade doesn't re-resolve on resize.
function isVisible(el) {
  if (!el || el.nodeType !== 1) return false;
  var win = el.ownerDocument.defaultView || window;
  var style = win.getComputedStyle(el);
  if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  return el.checkVisibility();
}

// Returns true if the element is obscured at its center point — i.e.
// hit-testing elementFromPoint at the center returns something that is
// not the element or its descendant. `visibility:hidden|collapse` is
// short-circuited explicitly because those elements still produce a
// layout box (so the rect-zero check below can't catch them); every
// other "not rendered" case (display:none, [hidden], descendants of
// either) falls out naturally because getBoundingClientRect returns
// DOMRect{0,0,0,0} for elements with no layout box.
function isObscured(el) {
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
  if (el.contains(hit)) return false;
  // A hit inside a shadow tree is retargeted to its host, and there is no
  // ShadowRoot.elementFromPoint to look further, so landing on one of el's own
  // hosts is the best "not obscured" answer available.
  var root = el.getRootNode ? el.getRootNode() : doc;
  while (root && root !== doc && root.host) {
    if (hit === root.host) return false;
    root = root.host.getRootNode();
  }
  return true;
}

// Capybara's `Node#disabled?` is more permissive than CSS `:disabled`:
// an `<option>` inside a disabled `<select>` or a disabled `<fieldset>`
// is reported as disabled, even though those don't match CSS `:disabled`
// per the HTML spec — the Capybara shared specs expect them disabled.
function isDisabled(el) {
  if (el.matches && el.matches(':disabled')) return true;
  if ((el.tagName || '').toUpperCase() === 'OPTION') {
    var p = el.parentElement;
    while (p) {
      // `=== true`: a <form>'s `disabled` is named field access, so
      // `<input name="disabled">` makes `form.disabled` that input.
      if (p.disabled === true) return true;
      p = p.parentElement;
    }
  }
  return false;
}

// True if the element is the host of a contenteditable region: it (or any
// ancestor) has a non-"false" `contenteditable` attribute. Lightpanda's
// native `HTMLElement.isContentEditable` (PR #2310) is hardwired to return
// `false` for every element — it has no caret/keyboard editing pipeline —
// so the IDL property is useless here and we walk ancestors ourselves.
function isContentEditable(el) {
  var n = el;
  while (n && n.nodeType === 1) {
    if (n.hasAttribute && n.hasAttribute('contenteditable')) {
      var v = (n.getAttribute('contenteditable') || '').toLowerCase();
      return v !== 'false';
    }
    n = n.parentElement;
  }
  return false;
}

// The element a real pointer press on `el` would focus: the nearest focusable
// inclusive ancestor, or null when the press lands on nothing focusable (Chrome
// then moves focus to the body). Lightpanda's handleClick stopped focusing
// controls in upstream #3702 (build 9968), and an untrusted `mousedown` — the
// only kind CLICK_JS can dispatch — never runs the focus default, so the
// driver has to apply it itself or `click` then `page.send_keys` types nowhere.
function pointerFocusTarget(el) {
  function isEditingHost(n) {
    if (!n.hasAttribute || !n.hasAttribute('contenteditable')) return false;
    return (n.getAttribute('contenteditable') || '').toLowerCase() !== 'false';
  }
  function isFocusable(n) {
    if (isDisabled(n)) return false;
    switch ((n.tagName || '').toUpperCase()) {
      case 'INPUT': return (n.getAttribute('type') || '').toLowerCase() !== 'hidden';
      case 'SELECT': case 'TEXTAREA': case 'BUTTON': case 'IFRAME': case 'SUMMARY': return true;
      case 'A': case 'AREA': return n.hasAttribute('href');
    }
    return n.hasAttribute('tabindex');
  }

  for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
    // A press on a <label> lands on its control (the label's activation
    // behavior); the label itself is never focusable.
    if ((n.tagName || '').toUpperCase() === 'LABEL' && n.control) {
      return isFocusable(n.control) ? n.control : null;
    }
    if (isEditingHost(n)) {
      // Focus goes to the outermost element of a contiguous editable region.
      while (n.parentElement && isEditingHost(n.parentElement)) n = n.parentElement;
      return n;
    }
    if (isFocusable(n)) return n;
  }
  return null;
}

// Capybara's "visible text" = WebDriver getText semantics, which native
// innerText alone doesn't provide at two edges: a non-rendered element must
// yield "" (innerText returns textContent per the HTML getter's step 1), and a
// ShadowRoot/DocumentFragment has no innerText at all. So we gate on visibility
// and otherwise delegate the rendered-text collection — block line breaks +
// display:none descendant skipping + whitespace — to native innerText
// (Lightpanda #2785/#2795, guaranteed by the build floor). node.rb#visible_text
// normalizes the whitespace on top.
function visibleText(el) {
  if (el.nodeType === 1) return isVisible(el) ? el.innerText : '';
  // ShadowRoot / DocumentFragment: no innerText of its own. Concatenate the
  // native innerText of each visible element child with the text nodes between
  // them — collapsing the latter's whitespace to a single space so template
  // newlines between inline children render as a separating space, not a break.
  var out = '';
  for (var i = 0; i < el.childNodes.length; i++) {
    var c = el.childNodes[i];
    if (c.nodeType === 3) out += c.nodeValue.replace(/[\t\n\r\f\v ]+/g, ' ');
    else if (c.nodeType === 1 && isVisible(c)) out += c.innerText;
  }
  return out;
}

// Capybara's finder hints (SelectorQuery#find_nodes_by_selector_format): answer
// in the find's own round-trip what Capybara would otherwise ask every node for
// one CDP call at a time. `spec` is {texts, visible, position, styles}; the
// answers ride back on the returned array as a JSON string, so they can't come
// from a different page than the nodes, and node.rb's #initial_cache serves them.
//
// `texts` are Capybara's text fragments — the `text:` option split on
// whitespace — so a node is dropped only when one fragment is in neither its
// textContent nor its visible text, compared case-insensitively. Capybara would
// reject that node anyway; anything it could match stays. Any failure returns
// the nodes untouched and unhinted: a hint is an optimization, never a verdict.
function findHints(nodes, spec) {
  // Same normalization node.rb#filter_text applies before Capybara compares:
  // zero-width marks dropped, NBSP read as a space, whitespace runs collapsed.
  function haystack(text) {
    return String(text || '')
      .replace(/[\u200B\u200E\u200F]/g, '')
      .replace(/[\s\u00A0]+/g, ' ')
      .toLowerCase();
  }
  try {
    var needles = (spec.texts || []).map(function (t) {
      return String(t).replace(/ /g, ' ').toLowerCase();
    });
    if (needles.length) {
      nodes = nodes.filter(function (el) {
        var hay = haystack(el.textContent) + '\n' + haystack(visibleText(el));
        return needles.every(function (n) { return hay.indexOf(n) !== -1; });
      });
    }
    var hints = nodes.map(function (el) {
      var h = { tag_name: el.tagName ? el.tagName.toLowerCase() : '' };
      if (spec.visible) h.visible = isVisible(el);
      if (spec.position) {
        var r = el.getBoundingClientRect();
        h.position = { x: r.x, y: r.y, top: r.top, bottom: r.bottom, left: r.left,
                       right: r.right, width: r.width, height: r.height };
      }
      if (spec.styles) {
        var cs = (el.ownerDocument.defaultView || window).getComputedStyle(el);
        h.style = {};
        spec.styles.forEach(function (name) { h.style[name] = cs[name]; });
      }
      return h;
    });
    nodes.__lightpandaHints = JSON.stringify(hints);
  } catch (e) {}
  return nodes;
}
