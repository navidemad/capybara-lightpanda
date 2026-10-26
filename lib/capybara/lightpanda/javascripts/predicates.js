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
  // Document hit testing retargets a shadow child to its outermost host.
  // Check each enclosing shadow tree from the outside in: an inner root must
  // never let us see through an overlay covering its host in an outer root.
  var roots = [], root = el.getRootNode ? el.getRootNode() : doc;
  while (root && root !== doc && root.host) {
    roots.push(root);
    root = root.host.getRootNode();
  }
  for (var i = roots.length - 1; i >= 0; i--) {
    root = roots[i];
    if (hit !== root.host) break;
    // Older supported builds have no shadow hit testing. A hit on our own
    // host remains the best available evidence that the child is actionable.
    if (typeof root.elementFromPoint !== 'function') return false;
    hit = root.elementFromPoint(cx, cy);
    if (!hit) return true;
  }
  return hit !== el && !el.contains(hit);
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

// Capture intrinsics before page scripts can replace them. Array operations use
// indexed loops: an overridden map must never detach cache rows from node IDs.
var hintStringify = JSON.stringify;
var hintLowerCase = Function.prototype.call.bind(String.prototype.toLowerCase);

// Capybara keeps Result candidates for lazy enumeration, possibly after the DOM
// changes. Only immutable tag names belong in initial_cache; mutable visibility,
// geometry and styles must be read live. Text hints are a conservative prefilter.
function findHints(nodes, spec) {
  // Bound eager subtree text walks: nested candidates otherwise make first()
  // quadratic even though Capybara would inspect only the first candidate.
  if (nodes.length > 512) return nodes;
  try {
    var texts = spec.texts || [];
    var needles = [];
    for (var i = 0; i < texts.length; i++) {
      // Ruby splits ASCII whitespace, not every Unicode separator. Unicode
      // casing can also depend on context (Greek final sigma). Fail open.
      if (/[^\x00-\x7F]/.test(texts[i])) return nodes;
      needles[i] = hintLowerCase(texts[i]);
    }
    var kept = [];
    var hints = [];
    for (var j = 0; j < nodes.length; j++) {
      var el = nodes[j];
      var matches = true;
      if (needles.length) {
        var all = el.textContent || '';
        var visible = visibleText(el) || '';
        // The driver's all_text and visible_text normalize Unicode differently.
        // Retain such candidates for Capybara's authoritative text comparison.
        if (!/[^\x00-\x7F]/.test(all + visible)) {
          all = hintLowerCase(all);
          visible = hintLowerCase(visible);
          for (var k = 0; k < needles.length; k++) {
            if (all.indexOf(needles[k]) === -1 && visible.indexOf(needles[k]) === -1) {
              matches = false;
              break;
            }
          }
        }
      }
      if (matches) {
        hints[kept.length] = { tag_name: el.nodeType === 11 ? 'ShadowRoot' :
          (el.tagName ? hintLowerCase(el.tagName) : '') };
        kept[kept.length] = el;
      }
    }
    // Publish only after every read succeeds. Any exception returns the exact
    // original array, without partial filtering or partially constructed hints.
    kept.__lightpandaHints = hintStringify(hints);
    return kept;
  } catch (e) {
    return nodes;
  }
}
