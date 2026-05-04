# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le polyfill correspondant dans `lib/capybara/lightpanda/javascripts/polyfills.js` peut être retiré (les `if (!feature)` font de toute façon des no-ops).

---

## ~~Bug #1~~ — `Element.prototype.click()` via `Runtime.callFunctionOn` — RETRACTED 2026-05-04

Le repro minimal du gem ne reproduit pas sur le binaire publié `2026.05.04.034446` (build ~6005, HEAD `6b896ba2`). Probe CDP au `repro/a31-a32-a33-verify/probe3.js` exécutée contre les deux binaires (`/opt/homebrew/bin/lightpanda` ET `~/.cache/lightpanda/lightpanda` — MD5 identique `90de65e41a2d33e2fcd1a9bb888c2789`) :

- `this.click()` via `callFunctionOn` → no `exceptionDetails`
- `try/catch + return info` → `{ typeofClick: "function", threw: null }`
- `HTMLElement.prototype.click.call(this)` → OK
- `setTimeout + this.click()` → OK

Le `CLICK_JS` workaround dans `Capybara::Lightpanda::Node` **reste en place** car la dispatch JS-level reste load-bearing pour Bug #3 (voir ci-dessous) — c'est elle qui permet au monkey-patch `patchDispatch` de rattraper les listeners qui throw pendant la propagation. Le commentaire au-dessus de `CLICK_JS` pointe maintenant vers Bug #3 / DOM §2.9.

---

## ~~Bug #2~~ — `MouseEvent` dispatch via `Runtime.callFunctionOn` — RETRACTED 2026-05-04

Probe CDP : `this.dispatchEvent(new MouseEvent('click', { bubbles: true }))` via `callFunctionOn` retourne OK sur le binaire courant. `Event` constructor aussi. Les deux sont spec-compliant.

Le gem utilise `Event` (construction moins coûteuse, suffisant pour Stimulus / Turbo). Migrer vers `MouseEvent` pour exposer `click(x:, y:, modifiers:)` avec coordonnées fidèles est une amélioration ergonomique future, pas un bug fix.

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

## ~~Bug #5~~ — `HTMLFormElement.prototype.requestSubmit()` — FIXED upstream

PR #2253 (mergé 2026-04-27) implémente `requestSubmit()` avec `event.submitter` correct. Plus de polyfill côté gem.

---

## Bug #6 — `fetch(url, { body: new FormData(...) })` n'encode pas en multipart

`fetch()` reçoit bien un `FormData` mais le coerce en string via `String(formData)` (qui retourne `"[object FormData]"`), URL-encode cette string, et envoie le tout en `Content-Type: application/x-www-form-urlencoded`. Le serveur reçoit donc une seule clé bidon `"object FormData"` à la place des entrées du FormData. Reproductible sur build `1.0.0-dev.6013+6b896ba2` (vérifié 2026-05-04).

### Repro minimal

```js
var fd = new FormData();
fd.append('name', 'Bob');
fd.append('count', '42');
fetch('/echo', { method: 'POST', body: fd })
  .then(function(r) { return r.json(); })
  .then(function(j) { console.log(j); });
```

### Ce qu'on observe côté serveur (Sinatra `request.content_type` + `params`)

```ruby
{
  "method"       => "POST",
  "content_type" => "application/x-www-form-urlencoded",   # devrait être "multipart/form-data; boundary=..."
  "params"       => { "object FormData" => nil },           # devrait être { "name" => "Bob", "count" => "42" }
  "raw_body_len" => 17                                       # = length("object%20FormData")
}
```

### Ce qu'un navigateur conforme produit (HTML §6.4 fetch + XHR steps 4.4)

`fetch` doit invoquer le « extract a body » algorithme défini par [Fetch §6.5](https://fetch.spec.whatwg.org/#concept-bodyinit-extract). Pour un `FormData`, ça produit un `multipart/form-data; boundary=…` avec une `MIME boundary` séparant chaque entrée de `name`/`value`. Lightpanda saute cette étape et tombe directement sur le fallback `String(body)` qu'il applique aux strings nues.

### Surface concernée — vérifié dans le même probe pass (4 tests dédiés Zone 1)

| Path                                                                 | Content-Type                        | Server reçoit |
|---|---|---|
| `fetch(body: "name=A&role=B")` (string nue)                          | `application/x-www-form-urlencoded` | ✅ `{ name: "A", role: "B" }` |
| `fetch(body: new URLSearchParams([...]))`                            | `application/x-www-form-urlencoded` | ✅ `{ name: "C", count: "7" }` |
| `fetch(body: new FormData())` + `fd.append(...)`                     | `application/x-www-form-urlencoded` | ❌ `{ "object FormData" => nil }` |
| `fetch(body: new FormData(form))` (the Turbo Drive shape)            | `application/x-www-form-urlencoded` | ❌ `{ "object FormData" => nil }` |
| **`XMLHttpRequest.send(formData)`** (different code path)            | `application/x-www-form-urlencoded` | ❌ `{ "object FormData" => nil }` |

Conclusions :
- Seul `FormData` est cassé. Les autres formes documentées par la spec (`Blob`, `ArrayBuffer`, `ReadableStream`) non testées.
- **fetch et XHR ont la même signature de bug** → un seul fix upstream couvre les deux paths. La cause racine est partagée (cf. site à patcher en bas du `Want` de A34 dans le wishlist).

### Impact

Bloquant pour Turbo Drive : tous les `<form>` submits passent par `new FormData(form)` côté Turbo. Sans encoding multipart correct, le serveur ne reçoit aucun champ → 422 systématique sur les form submits Turbo.

Aussi bloquant pour les **uploads de fichier** côté JS — `<input type=file>` sérialisé via `FormData` perd la pièce jointe.

### Workaround côté gem

Aucun. Le bug est dans le code C/Zig de `fetch` côté Lightpanda — pas accessible depuis JS. Les apps Hotwire qui veulent contourner doivent encoder manuellement en `URLSearchParams` (qui marche) :

```js
// Au lieu de
fetch(url, { method: 'POST', body: new FormData(form) });

// Côté Turbo on remplacerait par (impossible sans monkey-patcher Turbo) :
var qs = new URLSearchParams(new FormData(form).entries());
fetch(url, { method: 'POST', body: qs });
```

### À vérifier upstream

L'algorithme « extract a body » de Fetch (probablement dans `src/browser/webapi/fetch/` côté Zig) ne discrimine pas le type `FormData`. Voir si :

1. `instanceof FormData` est implémenté pour les inputs entrants
2. Si oui, brancher l'encodage multipart standard (boundary aléatoire `------WebKitFormBoundary…`, header `Content-Disposition: form-data; name="…"` par entry)

Modèle : `URLSearchParams` est déjà géré correctement, l'API de discrimination existe donc déjà dans le code.

---

## Méthode de découverte

Tous les bugs upstream sont isolés en deux étapes :

1. Comparaison du même test Capybara entre Selenium/Cuprite (qui passent) et Lightpanda (qui échoue).
2. Réduction du repro JS minimal en exécutant des fragments via `Capybara.driver.evaluate_script` et `browser.call_function_on`. Si le repro Capybara reproduit mais le repro CDP-pur ne reproduit pas, suspecter une mauvaise attribution gem-side du symptôme (ex. : Bug #3 listener-throw qui surface comme `JsException` au boundary du `call_function_on`, fait passer Bug #1 pour cassé alors qu'il ne l'est pas — d'où la rétractation Bug #1 ci-dessus). Suspecter aussi des bugs du test (cf. Bug #6 trouvé après isolation de mon `arguments[0]` au lieu de `arguments[arguments.length - 1]` : tous les "async timeouts" qu'on voyait initialement étaient des erreurs de spec, pas des bugs upstream).

`spec/features/hotwire_zones_probe_spec.rb` couvre les 4 grandes surfaces dont Turbo Drive / Stimulus dépendent (fetch + FormData, `<template>` + DOMParser, MutationObserver, History API + popstate). Sur build 6013, **20/21 passes** ; le seul échec est Bug #6 ci-dessus.

L'enrichissement de `Capybara::Lightpanda::JavaScriptError` (className + stack trace dans le message) et la variable d'environnement `LIGHTPANDA_DEBUG=1` (qui logge l'expression et la réponse CDP à chaque échec) ont rendu la chasse aux bugs nettement plus rapide.

## Statut historique

| Bug | Build 5267 (brew, 2026-04) | Build 6005 (2026-05-04) | Note |
|---|---|---|---|
| #1 `Element.click()` via callFunctionOn | broken (rapporté) | ✅ ne reproduit pas (probe CDP) | Rétracté 2026-05-04 — voir ci-dessus. Le `CLICK_JS` workaround reste pour Bug #3. |
| #2 `MouseEvent` dispatch via callFunctionOn | broken | ✅ fixed | |
| #3 `dispatchEvent` halt sur listener throw | broken | broken (scope précisé) | A33 wishlist. Polyfill load-bearing. |
| #4 `HTMLDialogElement.{showModal, show, close}` | broken | broken | B12 wishlist. À driver upstream. |
| #5 `HTMLFormElement.requestSubmit()` | broken | ✅ fixed (PR #2253) | A14 wishlist (mergé). |
| #6 `fetch + FormData` ne fait pas multipart | non testé | broken (verified 6013) | Nouveau — bloque tous les form submits Turbo. À filer en wishlist. |
