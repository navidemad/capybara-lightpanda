// Polyfills compensant des limitations du binaire Lightpanda.
// Chaque section est gardée par un test de feature : dès qu'upstream implémente
// l'API native, le polyfill devient un no-op et peut être retiré.
// Voir UPSTREAM_BUGS.md à la racine du gem pour les repros et liens d'issues.
(function () {
  "use strict";

  // ── Bug #7 (residual) — form-* IDL gaps on submitters + `form.enctype` ──
  // Form-side `method`/`action`/`target`/`name`/`acceptCharset` are native
  // since 2026-03-15 (Form.zig:208-211), so the `defineIfMissing` guard
  // (`name in proto`) auto-no-ops those branches. What remains upstream-missing
  // and load-bearing:
  //
  //   • `HTMLFormElement.enctype` — Turbo's `FormSubmission` constructor
  //     does `(submitter?.formEnctype || form.enctype).toLowerCase()`. With
  //     `enctype` returning `undefined`, Turbo crashes on the first submit.
  //   • Submitter overrides on `HTMLButtonElement` / `HTMLInputElement`:
  //     `formEnctype`, `formMethod`, `formAction`, `formTarget`,
  //     `formNoValidate`. Per WHATWG HTML these must always return a string
  //     (empty string is the missing-value default for the override side)
  //     so `submitter.formX || form.X` resolves to the form's value.
  //
  // Polyfill strategy: only define each getter when missing on the prototype,
  // so a future Lightpanda nightly that lands native support wins automatically.
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
      defineIfMissing(HTMLFormElement.prototype, "enctype",
                      function () { return normEnctype(this.getAttribute("enctype")); });
    }
    function patchSubmitter(Ctor) {
      if (typeof Ctor === "undefined") return;
      var p = Ctor.prototype;
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
})();
