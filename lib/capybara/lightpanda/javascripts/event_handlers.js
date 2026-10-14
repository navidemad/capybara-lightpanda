// --- GlobalEventHandlers on Window and Document ---
// HTML puts the same GlobalEventHandlers `on*` attributes on HTMLElement,
// Document and Window. Lightpanda implements the full set on HTMLElement but
// only a handful on Window (onload, onclick, onerror, …) and Document (onclick,
// touch events), so `'onchange' in window` and `'onsubmit' in window` are false
// where Chrome says true.
//
// jQuery 1.x reads exactly those two expressions at load time to decide
// whether `change` and `submit` bubble. Told they don't, it swaps in its old IE
// shims, which only work in IE: every delegated handler (`$(el).on('change',
// 'select', fn)`, and Backbone's `events: {'change .x': …}`) and every direct
// one on an ancestor (Backbone's `events: {change: …}`) then never fires, even
// though the native event bubbles fine. Solidus's admin is built on that stack
// (country → state swap, the payment form, the calculator picker).
//
// Each missing name gets the IDL attribute's behaviour: the getter returns the
// handler or null, assigning a function registers it as a listener, assigning
// anything else clears it, and a handler returning false cancels the event. The
// names come from HTMLElement.prototype, so nothing exists here that Chrome
// lacks on window (`onfocusin`, for one, stays absent there too). Names the
// browser already implements are left alone.
//
// Delete this file once upstream gives Window and Document the full
// GlobalEventHandlers set and the floor covers it.
function _defineEventHandlerProperty(target, name, eventTarget) {
  var type = name.slice(2);
  var handler = null;
  var listener = null;
  Object.defineProperty(target, name, {
    configurable: true,
    enumerable: true,
    get: function () { return handler; },
    // As in the spec, the listener is registered on the first assignment and
    // kept while the attribute holds a function, so reassigning swaps the
    // handler without moving it behind listeners added in between. Only null
    // (or a non-function) removes it.
    set: function (value) {
      var receiver = eventTarget(this);
      handler = typeof value === 'function' ? value : null;
      if (handler && !listener) {
        listener = function (event) {
          var result = handler.call(this, event);
          if (result === false) event.preventDefault();
          return result;
        };
        receiver.addEventListener(type, listener);
      } else if (!handler && listener) {
        receiver.removeEventListener(type, listener);
        listener = null;
      }
    }
  });
}

function _polyfillGlobalEventHandlers() {
  if (typeof HTMLElement === 'undefined') return;
  var names = Object.getOwnPropertyNames(HTMLElement.prototype).filter(function (name) {
    return name.indexOf('on') === 0;
  });
  names.forEach(function (name) {
    if (!(name in window)) {
      _defineEventHandlerProperty(window, name, function () { return window; });
    }
    if (typeof Document !== 'undefined' && !(name in document)) {
      // Per document, not on Document.prototype: each document keeps its own
      // handler slots, and this script runs once in every document anyway.
      _defineEventHandlerProperty(document, name, function () { return document; });
    }
  });
}

_polyfillGlobalEventHandlers();
