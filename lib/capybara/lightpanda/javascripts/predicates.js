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
// always passes --enable-external-stylesheets (Lightpanda PR #2487,
// guaranteed by the build floor) — so stylesheet-driven `display:none`
// participates in this check. The remaining gap is viewport emulation:
// `@media` rules and `matchMedia()` evaluate against the hardcoded
// 1920×1080 viewport (no resize), so visibility gated on a non-desktop
// viewport — e.g. a mobile-only CTA under `@media (max-width: …)` —
// resolves like desktop Chrome at 1920×1080. Keep those specs on a
// full-layout driver (README's dual-driver setup).
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
  return !el.contains(hit);
}

// Capybara's `Node#disabled?` is more permissive than CSS `:disabled`:
// an `<option>` inside a disabled `<select>` or a disabled `<fieldset>`
// is reported as disabled, even though those don't match CSS `:disabled`
// per the HTML spec. Mirrors Cuprite's behavior so the shared specs pass.
function isDisabled(el) {
  if (el.matches && el.matches(':disabled')) return true;
  if ((el.tagName || '').toUpperCase() === 'OPTION') {
    var p = el.parentElement;
    while (p) {
      if (p.disabled) return true;
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
