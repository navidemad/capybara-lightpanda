# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le workaround correspondant côté gem peut être retiré.

## Bugs résolus / rétractés

Numérotation conservée — référencée depuis les tests et la wishlist.

- **Bug #1** — `Element.prototype.click()` via `Runtime.callFunctionOn`. Rétracté 2026-05-04 (ne reproduit pas en probe CDP pur). `CLICK_JS` reste en place car load-bearing pour Bug #3.
- **Bug #2** — `MouseEvent` dispatch via `Runtime.callFunctionOn`. Rétracté 2026-05-04.
- **Bug #5** — `HTMLFormElement.prototype.requestSubmit()`. Fixé upstream par PR #2253 (mergé 2026-04-27).
- **Bug #6** — `fetch` / `XHR` n'encodent pas `FormData` en multipart. Fixé upstream 2026-05-06 par PR #2358 ("net: multipart-encode FormData bodies in fetch and XMLHttpRequest"). Build floor ~6090, couvert par `MINIMUM_NIGHTLY_BUILD = 6109`. Aucun polyfill côté gem n'existait (encoding en Zig). Les 4 tests `skip` dans `test/features/hotwire_zones_probe_test.rb` peuvent maintenant tomber.
- **Bug #7** — IDL `enctype` / `formMethod` / `formEnctype` / `formAction` / `formTarget` / `formNoValidate` retournaient `undefined` quand l'attribut HTML correspondant était absent. Fixé upstream 2026-05-14 par PR #2450 ("forms: add enctype + 5 submitter form-* IDL accessors", commit `143bffdfe`). Le polyfill `patchFormIDL` a été retiré et `lib/capybara/lightpanda/javascripts/polyfills.js` supprimé — c'était le dernier polyfill du fichier. ⚠️ PR #2450 a mergé après le cut du nightly 2026-05-14 : `MINIMUM_NIGHTLY_BUILD` doit être bumpé au premier nightly contenant `143bffdfe` avant que le retrait soit shippable.
- **Bug #8** — `addEventListener` pendant capture-phase invisible à la bubble-phase. Fixé upstream 2026-05-11 par commit `8d5eef44` ("Improve events"). Premier nightly portant le fix : ≥6198. `MINIMUM_NIGHTLY_BUILD = 6199` couvre déjà.

---

## Bug #3 — `dispatchEvent` halt sur listener throw au lieu de "report exception" (DOM §2.9 step 4)

**Scope précisé 2026-05-04** sur `1.0.0-nightly.6005+b8144d3e`. La propagation par bubble fonctionne sur le happy path (vérifié leaf → mid → body → doc avec `event.target` préservé). MAIS si un listener throw pendant le dispatch, Lightpanda halt tout le dispatch path : les listeners suivants sur le même nœud sont skippés ET la propagation aux ancêtres ne tourne pas. L'exception remonte à l'appelant.

Per [DOM §2.9 step 4 ("inner invoke")](https://dom.spec.whatwg.org/#concept-event-listener-inner-invoke), l'algorithme doit "report exception" (la surfacer au global error handler) puis continuer à invoquer les listeners restants.

### Repro

```js
const btn = document.createElement('button');
document.body.appendChild(btn);

let localHit = false;
let docHit = false;
btn.addEventListener('click', () => { localHit = true; throw new Error('boom'); });
document.addEventListener('click', () => docHit = true);

let threw = null;
try {
  btn.dispatchEvent(new Event('click', { bubbles: true, cancelable: true }));
} catch (e) {
  threw = String(e);
}

console.log({ localHit, docHit, threw });
// Expected (Chromium): { localHit: true, docHit: true, threw: null }
// Actual   (Lightpanda): { localHit: true, docHit: false, threw: 'Error: JsException' }
```

Reproductible aussi dans `spec/features/upstream_bugs_spec.rb` "invokes the document handler even when the local handler throws" — sans le polyfill, ce test fail avec `JavaScriptError: Error: JsException` au boundary `call_function_on` du gem, et `window.__hits` ne contient que la phase `leaf`.

### Impact

**Bug le plus impactant pour Hotwire** : un seul Stimulus controller buggy ou un edge-case Turbo Drive qui throw désactive silencieusement la délégation document-wide jusqu'à la prochaine navigation.

### Workaround

Voir `polyfills.js` `patchDispatch` IIFE (~45 LOC) : monkey-patch de `EventTarget.prototype.dispatchEvent` qui catch la `JsException` surfacée, puis re-walk `parentNode` manuellement, en spoofant `event.target` via `Object.defineProperty`. Pair avec `CLICK_JS` qui dispatch via JS-level `dispatchEvent` (pour que le patch puisse intercepter) et fournit le default action manuel (`form.submit()` / `location.href`).

Limites du workaround : pas de `CAPTURING_PHASE`, `eventPhase` incorrect pour les targets spoofés, `composedPath` non polyfilled. Suffisant pour Stimulus / Turbo (qui n'inspectent pas ces propriétés), peut casser des handlers exotiques.

### Fix upstream attendu

Probable `try/catch` autour de chaque invocation de callback dans le dispatch loop (`src/browser/webapi/event/EventTarget.zig` ou équivalent), avec l'exception attrapée forwardée à l'inspector / global error handler au lieu de remonter l'appelant.

---

## Bug #4 — `HTMLDialogElement.prototype.{showModal, show, close}` non implémentés

**Confirmé 2026-05-04** : le constructor `HTMLDialogElement` existe (`typeof HTMLDialogElement === 'function'`), mais `prototype.showModal`, `prototype.show`, `prototype.close` sont tous `undefined`. Probe au `repro/a31-a32-a33-verify/probe2.js`.

Bloque toute UI utilisant `<dialog>` natif (très courant en Rails 8 + DaisyUI / Tailwind UI / shadcn).

### Workaround

`polyfills.js` ajoute `showModal()` (avec parité `InvalidStateError`), `show()`, `close([returnValue])` sur le prototype. Toggle de `[open]` + dispatch d'un event `'close'`. Pas de focus trap, pas de backdrop, pas de top-layer (Lightpanda n'a pas de moteur de layout de toute façon).

### Suivi

Tracé dans `references/upstream-wishlist.md` comme **B12** — à driver upstream prochainement.

---

## Bug #9 — `requestSubmit()` jette quand un listener cancel le SubmitEvent

Per HTML §4.10.21.5 step 5, si la soumission est cancellée (un listener du `submit` event a appelé `event.preventDefault()`), `requestSubmit()` doit retourner silencieusement. Lightpanda jette `JsException` à la place. Reproductible quand Turbo's `submitBubbled` cancel proprement le SubmitEvent et que le code appelant (`CLICK_JS` du gem ou code utilisateur) n'attrape pas l'exception → toute la chaîne click → form submit foire.

### Workaround côté gem

`node.rb` → `try { this.form.requestSubmit(this); } catch (e) {}` autour de l'appel dans `CLICK_JS`. Le listener qui a cancellé est responsable de la suite (par ex. Turbo Drive lance son propre `fetch` via le path `formSubmitted` → `Navigator.submitForm`).

---

## Bug #10 — `Runtime.evaluate` retient les bindings `const` / `let` top-level entre appels CDP

V8 spec : chaque `Runtime.evaluate` exécute son source dans un nouveau script, donc `const x = 1` au top-level n'a pas de scope partagé entre deux appels successifs. Lightpanda partage le scope → un second appel avec `const sel = ...` lève `SyntaxError: Identifier 'sel' has already been declared`.

### Repro minimal (CDP brut)

```bash
# Connecté à une session Lightpanda via WebSocket :
{"id":1,"method":"Runtime.evaluate","params":{"expression":"const sel = document.body"}}
# → OK
{"id":2,"method":"Runtime.evaluate","params":{"expression":"const sel = document.body"}}
# → exceptionDetails: SyntaxError: Identifier 'sel' has already been declared
```

### Impact

Tout test Capybara qui exécute deux `page.execute_script` ou `evaluate_script` partageant un nom de variable au top-level échoue silencieusement (le gem n'inspectait pas `exceptionDetails` sur la fast-path no-args de `execute`). Bloquant pour les helpers Capybara qui utilisent `const` (idiomatique en JS moderne).

### Workaround côté gem

`browser.rb` → wrap chaque expression de `evaluate(expression)` et `execute(expression)` no-args path dans une IIFE `(function(){return EXPR})()` / `(function(){EXPR})()`. La déclaration `const`/`let` se retrouve dans un function scope qui est jeté à la sortie de l'IIFE. Aligné avec ce que fait déjà la branche args via `Runtime.callFunctionOn`. **Aussi** : raise `JavaScriptError` quand `exceptionDetails` est présent dans la réponse de `execute`, sinon les exceptions JS étaient avalées silencieusement.
