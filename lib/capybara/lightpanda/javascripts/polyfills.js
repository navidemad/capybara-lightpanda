// Polyfills compensant des limitations du binaire Lightpanda.
// Chaque section est gardée par un test de feature : dès qu'upstream implémente
// l'API native, le polyfill devient un no-op et peut être retiré.
// Voir UPSTREAM_BUGS.md à la racine du gem pour les repros et liens d'issues.
(function () {
  "use strict";

  // ── Bug #7 — HTMLFormElement / HTMLButtonElement / HTMLInputElement form-* IDL gaps ──
  // Lightpanda doesn't expose `form.enctype`, `form.method`, `form.action`,
  // `form.target`, nor the submitter-side `formEnctype` / `formMethod` /
  // `formAction` / `formTarget` overrides. Per WHATWG HTML these must always
  // return a string (with the spec's missing-value default) so consumers can
  // call `.toLowerCase()` etc. directly. Turbo's `FormSubmission` constructor
  // does exactly that and crashes with `Cannot read properties of undefined
  // (reading 'toLowerCase')` when it touches enctype.
  //
  // Polyfill strategy: only define the IDL getter when it's missing on the
  // prototype, so a future Lightpanda nightly that adds native support wins
  // automatically. Each getter falls back to the underlying attribute, with
  // the spec's default if the attribute is absent. For submitter overrides
  // (formEnctype, formMethod, etc.) we return the empty string when the
  // override attribute is unset — Turbo and Hotwire all use the
  // `submitter.formX || form.X` idiom, which resolves correctly when the
  // submitter side returns "".
  (function patchFormIDL() {
    var ENCTYPE_VALUES = ["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"];
    function normEnctype(v) {
      if (!v) return "application/x-www-form-urlencoded";
      v = String(v).toLowerCase();
      return ENCTYPE_VALUES.indexOf(v) >= 0 ? v : "application/x-www-form-urlencoded";
    }
    function normMethod(v) {
      if (!v) return "get";
      v = String(v).toLowerCase();
      return (v === "post" || v === "dialog") ? v : "get";
    }
    function defineIfMissing(proto, name, getter) {
      if (!proto || name in proto) return;
      try { Object.defineProperty(proto, name, { configurable: true, enumerable: true, get: getter }); } catch (_) {}
    }
    if (typeof HTMLFormElement !== "undefined") {
      var fp = HTMLFormElement.prototype;
      defineIfMissing(fp, "enctype", function () { return normEnctype(this.getAttribute("enctype")); });
      defineIfMissing(fp, "method",  function () { return normMethod(this.getAttribute("method")); });
      defineIfMissing(fp, "action",  function () {
        var a = this.getAttribute("action");
        if (a == null || a === "") return (this.ownerDocument && this.ownerDocument.URL) || "";
        try { return new URL(a, (this.ownerDocument && this.ownerDocument.URL) || undefined).href; }
        catch (_) { return a; }
      });
      defineIfMissing(fp, "target",  function () { return this.getAttribute("target") || ""; });
    }
    function patchSubmitter(Ctor) {
      if (typeof Ctor === "undefined") return;
      var p = Ctor.prototype;
      // Empty string is the spec's missing-value default for the submitter-side
      // IDL attrs — keep Turbo's `submitter.formX || form.X` idiom flowing
      // through to the form's value.
      defineIfMissing(p, "formEnctype", function () {
        var v = this.getAttribute("formenctype");
        return v == null ? "" : normEnctype(v);
      });
      defineIfMissing(p, "formMethod", function () {
        var v = this.getAttribute("formmethod");
        return v == null ? "" : normMethod(v);
      });
      defineIfMissing(p, "formAction", function () {
        var a = this.getAttribute("formaction");
        if (a == null || a === "") return "";
        try { return new URL(a, (this.ownerDocument && this.ownerDocument.URL) || undefined).href; }
        catch (_) { return a; }
      });
      defineIfMissing(p, "formTarget", function () { return this.getAttribute("formtarget") || ""; });
      defineIfMissing(p, "formNoValidate", function () { return this.hasAttribute("formnovalidate"); });
    }
    patchSubmitter(typeof HTMLButtonElement !== "undefined" ? HTMLButtonElement : null);
    patchSubmitter(typeof HTMLInputElement  !== "undefined" ? HTMLInputElement  : null);
  })();

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
  //
  // ── Bug #8 (added 2026-05-05) — sync remove + re-add lost across dispatch phases ──
  // WHATWG DOM specifies that each phase of a dispatch snapshots `currentTarget`'s
  // listener list AT THAT PHASE. Listeners removed and re-added during the capture
  // phase correctly appear in the bubble-phase snapshot in Chrome/Cuprite. Lightpanda
  // takes the snapshot once at dispatch start, so a remove+add during capture loses
  // the listener for the in-flight bubble. This breaks Turbo's `FormSubmitObserver`
  // pattern, where `submitCaptured` does `remove+add` on its own `submitBubbled` to
  // ensure that handler runs LAST in bubble — under Lightpanda, `submitBubbled` is
  // dropped entirely and Turbo never intercepts form submissions.
  //
  // Native form submission via `requestSubmit()` doesn't route through JS-exposed
  // `dispatchEvent`, so we can't detect "in-flight dispatch" by patching that. The
  // workaround instead targets the remove+add idiom directly: defer every
  // `removeEventListener` to a microtask. When `addEventListener` runs in the same
  // synchronous turn with the SAME (target, type, fn, capture), we cancel the
  // pending remove — the listener was never actually unregistered, so the in-flight
  // bubble snapshot still contains it. Genuine removes (no matching add follows)
  // happen at end-of-tick, indistinguishable from the unpatched behavior modulo
  // tick boundary.
  //
  // Trade-offs:
  //   • A page that removes a listener and reads listener state synchronously
  //     before the microtask flush will see the listener as still-attached. This
  //     is exotic; no known framework relies on it.
  //   • If a page removes listener X then adds listener Y of the same type on the
  //     same target before the flush, the add still happens but the remove fires
  //     late, removing X *after* Y is registered. Y persists, X is gone. Same end
  //     state as without the polyfill, just reordered in time.
  (function patchListenerLifecycle() {
    if (!window.EventTarget || !EventTarget.prototype.addEventListener) return;
    if (typeof Promise === "undefined") return; // need microtasks
    var origAdd    = EventTarget.prototype.addEventListener;
    var origRemove = EventTarget.prototype.removeEventListener;

    function captureFlag(opts) {
      return opts === true || (opts && typeof opts === "object" && opts.capture === true);
    }

    var pending = [];      // [{ target, type, fn, capture, cancelled }]
    var flushScheduled = false;

    function scheduleFlush() {
      if (flushScheduled) return;
      flushScheduled = true;
      Promise.resolve().then(function () {
        flushScheduled = false;
        var queue = pending;
        pending = [];
        for (var i = 0; i < queue.length; i++) {
          var r = queue[i];
          if (r.cancelled) continue;
          try {
            // Re-derive opts from the captured capture flag so we pass the
            // right phase to native removeEventListener.
            origRemove.call(r.target, r.type, r.fn, r.capture);
          } catch (_) {}
        }
      });
    }

    EventTarget.prototype.removeEventListener = function (type, fn, opts) {
      if (!fn) return origRemove.call(this, type, fn, opts);
      pending.push({
        target:    this,
        type:      type,
        fn:        fn,
        capture:   captureFlag(opts),
        cancelled: false,
      });
      scheduleFlush();
      // Return undefined like the spec — removeEventListener has no return value.
    };

    EventTarget.prototype.addEventListener = function (type, fn, opts) {
      if (!fn) return origAdd.call(this, type, fn, opts);
      var capture = captureFlag(opts);
      // Cancel a pending remove for the same tuple so the listener stays
      // registered without churn. Search from the end (LIFO) so the most
      // recent pending remove wins for the common remove-then-add idiom.
      // Then ALWAYS call native add: addEventListener is idempotent for the
      // same (type, fn, capture) tuple per DOM spec, and Lightpanda has been
      // verified to honor that. Skipping the call risks losing the listener
      // when a downstream caller later does an unmatched remove that the
      // polyfill flushes at microtask time.
      for (var i = pending.length - 1; i >= 0; i--) {
        var r = pending[i];
        if (r.cancelled) continue;
        if (r.target === this && r.type === type && r.fn === fn && r.capture === capture) {
          r.cancelled = true;
              break;
        }
      }
      return origAdd.call(this, type, fn, opts);
    };
  })();
})();
