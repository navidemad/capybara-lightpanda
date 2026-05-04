# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le polyfill correspondant dans `lib/capybara/lightpanda/javascripts/polyfills.js` peut être retiré (les `if (!feature)` font de toute façon des no-ops).

## Bug #1 — `HTMLElement.prototype.click()` non implémenté via `Runtime.callFunctionOn`

`Element.click()` lève `JsException` quand la méthode est invoquée via une fonction CDP `Runtime.callFunctionOn` avec un `objectId` lié — alors que la même méthode marche via `Runtime.evaluate` direct.

### Repro

```ruby
# Capybara::Lightpanda::Browser path
btn_object_id = node.remote_object_id
browser.call_function_on(btn_object_id, "function() { this.click() }")
# => Capybara::Lightpanda::JavaScriptError: Error: JsException
#    at HTMLButtonElement.<anonymous> (<anonymous>:1:20)
```

```js
// Browser-side equivalent (succeeds in Chromium, throws in Lightpanda)
// (executed in the context of a callFunctionOn frame with `this` bound to a button)
this.click();
```

### Impact

Tous les `click_on` de Capybara passent par `node.click` qui invoque `this.click()` via callFunctionOn. Bloquant pour toute interaction utilisateur.

### Workaround

Voir `Capybara::Lightpanda::Node::CLICK_JS` — dispatch d'un `Event('click', { bubbles: true })` synthétique + fallback `form.submit()` / `location.href`.

---

## Bug #2 — `MouseEvent` dispatch crash via `Runtime.callFunctionOn`

`dispatchEvent(new MouseEvent(...))` lève `JsException` dans le même contexte que le bug #1. Différent de `Event(...)` qui lui fonctionne.

### Repro

```js
// Via callFunctionOn avec `this` bound à un Element
this.dispatchEvent(new MouseEvent('click', { bubbles: true })); // throws JsException
this.dispatchEvent(new Event('click', { bubbles: true }));      // OK (mais cf bug #3)
```

### Impact

Empêche d'utiliser `MouseEvent` comme alternative à `.click()`. Pas de manière de simuler un vrai click utilisateur (avec coordonnées, button, modifiers) au niveau JS.

### Workaround

Idem #1 — utiliser `Event('click', ...)` à la place.

---

## Bug #3 — Crash pendant la propagation de `dispatchEvent` aux ancêtres

L'event est correctement délivré aux listeners locaux sur la cible, puis lève `JsException` quand il commence à remonter (capture/bubble) vers les ancêtres. Conséquence : tous les handlers délégués au niveau `document` (Stimulus, Turbo Drive) sont sautés.

### Repro

```js
const btn = document.createElement('button');
document.body.appendChild(btn);

let localHit = false;
let docHit = false;
btn.addEventListener('click', () => localHit = true);
document.addEventListener('click', () => docHit = true);

let threw = null;
try {
  btn.dispatchEvent(new Event('click', { bubbles: true, cancelable: true }));
} catch (e) {
  threw = String(e);
}

console.log({ localHit, docHit, threw });
// Expected (Chromium): { localHit: true, docHit: true, threw: null }
// Actual (Lightpanda): { localHit: true, docHit: false, threw: 'Error: JsException' }
```

### Impact

**Le bug le plus impactant** pour les apps Hotwire :
- Stimulus utilise event delegation au document — ses controllers ne reçoivent jamais le click.
- Turbo Drive intercepte clicks et submits au document — désactivé silencieusement.
- Tout pattern « event listener at document » est cassé.

### Workaround

Voir `polyfills.js` — monkey-patch de `EventTarget.prototype.dispatchEvent` qui intercepte le crash et propage manuellement l'event à chaque `parentNode`, en spoofant `event.target` via `Object.defineProperty` pour que les handlers délégués reçoivent la cible originale.

Limites du workaround : la propagation manuelle ne respecte pas exactement la spec DOM (pas de phase `CAPTURING_PHASE`, `eventPhase` incorrect, `composedPath` non polyfilled). Suffisant pour Stimulus/Turbo qui n'inspectent pas ces propriétés, mais peut casser des handlers plus exotiques.

---

## Bug #4 — `HTMLDialogElement.prototype.{showModal, show, close}` non implémentés

Le constructor `HTMLDialogElement` existe mais aucune des trois méthodes n'est définie sur son prototype.

### Repro

```js
const d = document.createElement('dialog');
document.body.appendChild(d);

console.log(typeof HTMLDialogElement);     // 'function'
console.log(typeof d.showModal);            // 'undefined'   (Chromium: 'function')
console.log(typeof d.show);                 // 'undefined'   (Chromium: 'function')
console.log(typeof d.close);                // 'undefined'   (Chromium: 'function')

d.showModal();                              // throws: TypeError: d.showModal is not a function
```

### Impact

Bloquant pour toutes les UI utilisant `<dialog>` natif (très courant en Rails 8 + DaisyUI / Tailwind UI). Le dialog n'a jamais l'attribut `open`, donc invisible.

### Workaround

Voir `polyfills.js` — ajoute `showModal()`, `show()`, `close()` sur `HTMLDialogElement.prototype`. Implémentation : toggle de l'attribut `open`, dispatch d'un event `'close'` sur close. Pas de gestion du focus trap modal ni du backdrop (Lightpanda n'a pas de moteur de layout de toute façon).

---

## Bug #5 — `HTMLFormElement.prototype.requestSubmit()` non implémenté

`form.requestSubmit()` (qui dispatch un `submit` event suivi du POST natif) est non défini.

### Repro

```js
const f = document.createElement('form');
console.log(typeof f.requestSubmit);  // 'undefined'  (Chromium: 'function')
f.requestSubmit();                     // throws: TypeError
```

### Impact

`requestSubmit()` est l'API moderne pour soumettre un form en émettant l'event `submit` (alors que `form.submit()` natif le bypasse). Sans elle, on ne peut pas combiner « émet l'event submit » + « fait le POST natif » en une seule call.

### Workaround

Pas de polyfill explicite ; CLICK_JS dispatche manuellement `Event('submit')` puis appelle `form.submit()` si le default n'a pas été prévenu.

---

## Investigation à mener — Turbo Drive fetch lifecycle

Symptôme observé après application des polyfills #3 et #4 : Turbo Drive intercepte correctement les events `click` et `submit` (preventDefault appelé), mais le fetch HTTP qui devrait suivre n'est jamais émis (vérifié dans les logs Rails). Probablement un bug dans `fetch`, `FormData` ou `XMLHttpRequest` qui crash silencieusement dans le fetch interne de Turbo. À documenter en bug #6+ après isolation.

---

## Méthode de découverte

Tous les bugs ci-dessus ont été isolés en deux étapes :

1. Comparaison du même test Capybara entre Selenium/Cuprite (qui passent) et Lightpanda (qui échoue).
2. Réduction du repro JS minimal en exécutant des fragments via `Capybara.driver.evaluate_script` et `browser.call_function_on`.

L'enrichissement de `Capybara::Lightpanda::JavaScriptError` (className + stack trace dans le message) et la variable d'environnement `LIGHTPANDA_DEBUG=1` (qui logge l'expression et la réponse CDP à chaque échec) ont rendu la chasse aux bugs nettement plus rapide.
