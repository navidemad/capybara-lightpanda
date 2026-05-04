// Polyfills compensant des limitations du binaire Lightpanda.
// Chaque section est gardée par un test de feature : dès qu'upstream implémente
// l'API native, le polyfill devient un no-op et peut être retiré.
// Voir UPSTREAM_BUGS.md à la racine du gem pour les repros et liens d'issues.
(function () {
  "use strict";

  // ── Bug #4 — HTMLDialogElement.{showModal, show, close} non implémentés ──
  // https://html.spec.whatwg.org/multipage/interactive-elements.html#the-dialog-element
  if (typeof HTMLDialogElement !== "undefined") {
    var dproto = HTMLDialogElement.prototype;
    if (typeof dproto.showModal !== "function") {
      dproto.showModal = function () {
        if (this.hasAttribute("open")) {
          throw new (window.DOMException || Error)(
            "The element already has an 'open' attribute, and therefore cannot be opened modally.",
            "InvalidStateError"
          );
        }
        this.setAttribute("open", "");
      };
    }
    if (typeof dproto.show !== "function") {
      dproto.show = function () {
        if (!this.hasAttribute("open")) this.setAttribute("open", "");
      };
    }
    if (typeof dproto.close !== "function") {
      dproto.close = function (returnValue) {
        if (!this.hasAttribute("open")) return;
        this.removeAttribute("open");
        if (returnValue !== undefined) this.returnValue = String(returnValue);
        this.dispatchEvent(new Event("close"));
      };
    }
  }

  // ── Bug #3 (narrower than originally diagnosed; verified 2026-05-04 against build 6005) ──
  // Native dispatch DOES propagate to ancestors with event.target preserved — but if
  // ANY listener throws, Lightpanda halts the whole dispatch path (incl. the bubble
  // phase) instead of reporting the exception and continuing per DOM §2.9 step 4.
  // Stimulus / Turbo Drive listeners that throw silently swallow document-level
  // delegation. Workaround: catch the propagated JsException and re-walk parents
  // manually, spoofing event.target via Object.defineProperty for delegated handlers.
  (function patchDispatch() {
    if (!window.EventTarget || !EventTarget.prototype.dispatchEvent) return;
    var orig = EventTarget.prototype.dispatchEvent;

    EventTarget.prototype.dispatchEvent = function (event) {
      try {
        return orig.call(this, event);
      } catch (err) {
        if (!event || !event.bubbles || !this.parentNode) throw err;

        var originalTarget = this;
        try {
          Object.defineProperty(event, "target", {
            value: originalTarget,
            configurable: true,
          });
        } catch (_) { /* target not redefinable — continue anyway */ }

        var node = this.parentNode;
        while (node) {
          try {
            Object.defineProperty(event, "currentTarget", {
              value: node,
              configurable: true,
            });
          } catch (_) {}
          try {
            orig.call(node, event);
          } catch (_) { /* ignore intermediate crashes; keep propagating */ }
          if (event.cancelBubble) break;
          node = node.parentNode || node.host || null;
        }
        return !event.defaultPrevented;
      }
    };
  })();
})();
