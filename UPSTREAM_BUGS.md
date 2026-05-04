# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le polyfill correspondant dans `lib/capybara/lightpanda/javascripts/polyfills.js` peut être retiré (les `if (!feature)` font de toute façon des no-ops).

---

## Bug #1 — `Element.prototype.click()` lève `JsException` quand invoqué via `Runtime.callFunctionOn`

`element.click()` jette une exception générique quand la méthode est appelée depuis le corps d'une fonction CDP `Runtime.callFunctionOn` avec un `objectId` lié — alors que la même méthode marche correctement via `Runtime.evaluate`. Reproductible sur **build `1.0.0-dev.6013+6b896ba2`** (vérifié 2026-05-04).

### Repro minimal — JavaScript

```js
// 1. Page setup
document.body.innerHTML = '<button id="b" type="button">x</button>';
const btn = document.getElementById('b');
btn.addEventListener('click', () => console.log('clicked!'));
```

### Repro côté CDP

#### A. Path qui marche — `Runtime.evaluate` (no objectId binding)

```json
{
  "method": "Runtime.evaluate",
  "params": {
    "expression": "document.getElementById('b').click()",
    "awaitPromise": true,
    "returnByValue": false
  }
}
```

→ Renvoie `{"result": {"type": "undefined"}}`, le handler de l'event `click` est invoqué. **OK.**

#### B. Path qui échoue — `Runtime.callFunctionOn` avec `this` lié à l'objet

```json
{
  "method": "Runtime.callFunctionOn",
  "params": {
    "objectId": "<oid de #b>",
    "functionDeclaration": "function() { this.click() }",
    "awaitPromise": true,
    "returnByValue": true
  }
}
```

→ Renvoie une réponse avec `exceptionDetails` :

```json
{
  "exceptionDetails": {
    "exceptionId": 14,
    "text": "Uncaught",
    "lineNumber": 0,
    "columnNumber": 19,
    "stackTrace": {
      "callFrames": [
        { "functionName": "", "scriptId": "57", "url": "", "lineNumber": 0, "columnNumber": 19 }
      ]
    },
    "exception": {
      "type": "object",
      "subtype": "error",
      "className": "Error",
      "description": "Error: JsException\n    at HTMLButtonElement.<anonymous> (<anonymous>:1:20)"
    }
  }
}
```

La position `1:20` (`columnNumber`) correspond au caractère `(` de `click()` dans `function() { this.click() }`. Le handler `click` n'est **jamais** appelé.

### Caractérisation

Sur le même `objectId` lié au `<button>`, dans le même appel `callFunctionOn` :

| JS executé via callFunctionOn | Résultat |
|---|---|
| `this.click()` | ❌ `JsException` à 1:20 |
| `HTMLElement.prototype.click.call(this)` | ❌ `JsException` à 1:43 |
| `var f = this.click; f.call(this)` | ❌ `JsException` à 1:37 |
| `this.focus()` | ✅ OK |
| `this.blur()` | ✅ OK |
| `this.getBoundingClientRect()` | ✅ OK |
| `this.tagName` | ✅ retourne `"BUTTON"` |
| `setTimeout(() => this.click(), 0)` | ✅ OK — handler invoqué |

Quand on enveloppe dans un `try/catch` JS et qu'on inspecte :

```js
function() {
  var info = { typeofClick: typeof this.click };
  try { this.click(); info.threw = null; }
  catch (e) { info.threw = String(e); info.errorName = e && e.name; }
  return info;
}
```

→ `{ "typeofClick": "function", "threw": "Error: JsException", "errorName": "Error" }`

Donc :
- `Element.prototype.click` **existe** comme `function`
- Mais l'appel synchrone direct depuis le contexte `callFunctionOn` lève une exception JS interne au binding Zig
- L'exception est attrapable côté JS (try/catch fonctionne), donc remontée par le V8 isolate normalement
- L'asynchronicité (`setTimeout`) débloque l'appel — ce qui suggère que le bug est lié à l'état du contexte d'exécution synchrone immédiatement à l'intérieur de `callFunctionOn`

### Surface concernée

Reproduit pour tous les éléments testés (chacun avec son binding `JsApi` Zig dédié) :

| Élément | Stack frame du throw |
|---|---|
| `<button type=button>` | `HTMLButtonElement.<anonymous>` |
| `<button type=submit>` | `HTMLButtonElement.<anonymous>` |
| `<a href>` | `HTMLAnchorElement.<anonymous>` |
| `<input type=checkbox>` | `HTMLInputElement.<anonymous>` |
| `<summary>` | `browser.webapi.element.html.Generic.JsApi.<anonymous>` |

La frame pour `<summary>` expose le chemin Zig interne : c'est bien le code natif `browser.webapi.element.html.Generic.JsApi` qui throw — pas un bug côté V8 / CDP.

### Impact

Bloque toute interaction utilisateur via Capybara puisque `click_on`, `find(...).click`, etc. passent tous par `Runtime.callFunctionOn` avec un objectId pour appeler la méthode native du DOM. Sans workaround, la suite système d'une app Hotwire échoue dès le premier `click_on`.

### Workaround dans le gem

Voir `Capybara::Lightpanda::Node::CLICK_JS` :

```ruby
CLICK_JS = <<~JS
  function() {
    var clickEvt = new Event('click', { bubbles: true, cancelable: true });
    var notCancelled = true;
    try {
      notCancelled = this.dispatchEvent(clickEvt);
    } catch (e) { /* defensive */ }
    if (!notCancelled || clickEvt.defaultPrevented) return;
    if (this.tagName === 'BUTTON' && this.type === 'submit' && this.form) {
      var submitEvt = new Event('submit', { bubbles: true, cancelable: true });
      var submitOk = this.form.dispatchEvent(submitEvt);
      if (submitOk && !submitEvt.defaultPrevented) this.form.submit();
    } else if (this.tagName === 'A' && this.href && this.target !== '_blank') {
      window.location.href = this.href;
    }
  }
JS
```

Stratégie :
1. Dispatcher un `Event('click')` synthétique qui bubble (vu par Stimulus, Turbo Drive, etc.) — `dispatchEvent`, contrairement à `click()`, n'a pas le bug
2. Si le default n'a pas été prévenu, déclencher manuellement la default action (`form.submit()`, `window.location.href`)

Limite : ne couvre pas tous les détails fidèles d'un vrai click (pas de coordonnées `clientX/Y`, pas de `MouseEvent` avec `button: 0`). Suffisant pour Hotwire et la plupart des UI.

### À vérifier upstream

Hypothèse pour le commit fix : l'implémentation de `Element.click()` dans `browser/src/webapi/element/element.zig` (ou équivalent) tente probablement d'accéder à un état du contexte V8 (isolate, scope, microtask queue) qui n'est pas valide quand l'appel arrive synchroniquement depuis `Runtime.callFunctionOn`. Le fait que `setTimeout` débloque suggère qu'une queue de microtasks ou une transition de scope manque entre le retour de `callFunctionOn` et l'invocation native.

Vérifier aussi pourquoi `focus()` / `blur()` / `getBoundingClientRect()` n'ont pas le même problème — leur implémentation Zig pourrait servir de modèle pour fixer `click()`.

---

## Investigation à mener — Turbo Drive fetch lifecycle

Symptôme observé sur un projet Rails 8 + Turbo : avec les workarounds en place, Turbo Drive intercepte correctement les events `click` et `submit` (preventDefault appelé), mais le fetch HTTP qui devrait suivre n'est jamais émis (vérifié dans les logs Rails). Probablement un bug dans `fetch`, `FormData` ou `XMLHttpRequest` qui crash silencieusement dans le code interne de Turbo. À documenter en bug séparé après isolation.

---

## Méthode de découverte

Tous les bugs upstream sont isolés en deux étapes :

1. Comparaison du même test Capybara entre Selenium/Cuprite (qui passent) et Lightpanda (qui échoue).
2. Réduction du repro JS minimal en exécutant des fragments via `Capybara.driver.evaluate_script` et `browser.call_function_on`.

L'enrichissement de `Capybara::Lightpanda::JavaScriptError` (className + stack trace dans le message) et la variable d'environnement `LIGHTPANDA_DEBUG=1` (qui logge l'expression et la réponse CDP à chaque échec) ont rendu la chasse aux bugs nettement plus rapide.

## Statut historique

| Bug | Build 5267 (brew, 2026-04) | Build 6013 (2026-05-04) |
|---|---|---|
| #1 `Element.click()` via callFunctionOn | broken | **broken — voir ci-dessus** |
| #2 `MouseEvent` dispatch via callFunctionOn | broken | ✅ fixed |
| #3 bubble continue quand un listener throw | broken | ✅ fixed |
| #4 `HTMLDialogElement.{showModal, show, close}` | broken | broken (out of scope ici) |
| #5 `HTMLFormElement.requestSubmit()` | broken | ✅ fixed |
