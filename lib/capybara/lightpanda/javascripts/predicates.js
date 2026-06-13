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

// Walk descendants and accumulate text from visible nodes only. Inserts
// newlines around block-display containers so paragraphs/lists render with
// natural breaks (Capybara expects this from Chrome's innerText).
// Lightpanda's innerText returns textContent verbatim (no rendering, so no
// hidden-descendant filtering), so we DIY the visibility filtering here.
function visibleText(el) {
  var BLOCK_DISP = { BLOCK:1, FLEX:1, GRID:1, 'LIST-ITEM':1, TABLE:1, 'TABLE-ROW':1,
                     'TABLE-CAPTION':1, 'TABLE-CELL':1 };
  var BLOCK_TAG = { ADDRESS:1, ARTICLE:1, ASIDE:1, BLOCKQUOTE:1, DETAILS:1, DIALOG:1,
                    DIV:1, DL:1, DT:1, DD:1, FIELDSET:1, FIGCAPTION:1, FIGURE:1,
                    FOOTER:1, FORM:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, HEADER:1,
                    HGROUP:1, HR:1, LI:1, MAIN:1, NAV:1, OL:1, P:1, PRE:1, SECTION:1,
                    TABLE:1, TR:1, UL:1 };

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
    if (!isVisible(node)) return '';
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
