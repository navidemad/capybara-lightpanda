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

  // ── Bug #3 — `Element.dispatchEvent` crash pendant la propagation aux ancêtres
  // ── (les listeners locaux fonctionnent, mais le bubble jusqu'à document/body
  // ── lève une JsException qui empêche Stimulus / Turbo Drive d'observer le click).
  // Workaround : intercepter le crash et propager l'event manuellement sur chaque
  // ancêtre, en spoofant `event.target` pour que les handlers délégués reçoivent
  // la cible originale.
  (function patchDispatch() {
    if (!window.EventTarget || !EventTarget.prototype.dispatchEvent) return;
    var orig = EventTarget.prototype.dispatchEvent;

    EventTarget.prototype.dispatchEvent = function (event) {
      try {
        return orig.call(this, event);
      } catch (err) {
        // Si l'event ne bubble pas ou qu'on n'est pas un Node, propager l'erreur.
        if (!event || !event.bubbles || !this.parentNode) throw err;

        var originalTarget = this;
        try {
          Object.defineProperty(event, "target", {
            value: originalTarget,
            configurable: true,
          });
        } catch (_) {
          // Si target n'est pas redéfinissable, on continue quand même.
        }

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
          } catch (_) {
            // Ignorer les crashes intermédiaires, continuer la propagation.
          }
          if (event.cancelBubble) break;
          node = node.parentNode || node.host || null;
        }
        return !event.defaultPrevented;
      }
    };
  })();
})();
