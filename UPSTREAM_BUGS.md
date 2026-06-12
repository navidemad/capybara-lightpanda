# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le workaround correspondant côté gem peut être retiré.

La numérotation démarre à #9 : les bugs #1–#8, résolus ou rétractés upstream, ont été retirés de ce fichier. Les numéros sont conservés (pas de renumérotation) car ils restent référencés depuis les tests (`test/features/upstream_bugs_test.rb`).

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

---

## Bug #11 — Réponse 3xx sans header `Location` : navigation avortée, body jamais rendu

Per RFC 9110 §15.4 (et le fetch spec), une réponse 3xx sans header `Location` est une réponse finale normale dont le body doit être délivré — Chrome la rend. Lightpanda route tout status 300–399 dans le chemin redirect (`src/browser/HttpClient.zig`, `processOneMessage`) et `handleRedirect` retourne `error.LocationNotFound` quand le header est absent. L'ancien document est détruit, rien ne le remplace : la page n'a plus de nœud `<html>` (Capybara : `Unable to find xpath "/html"`).

### Repro minimal

App Rack où `POST /submit` → `[303, {"content-type" => "text/html"}, ["<h1>Thank you</h1>"]]` ; cliquer le bouton submit du formulaire via le gem → plus de document. Contrôle : la même réponse avec status 422 est rendue correctement. Vérifié 2026-06-12 sur nightly 6703.

### Impact

Idiome Rails pour satisfaire le check Turbo « Form responses must redirect to another location » sans rediriger : `render 'thank_you', status: 303` (pas de `Location`). Rencontré sur le flow signup d'alonetone (`spec/features/account_requests_spec.rb`, « submits the form and succeeds ») en l'ajoutant à la suite real-apps ; avec Turbo devant, le symptôme s'adoucit en « la page reste sur le formulaire ».

### Workaround côté gem

Aucun possible — la gestion des redirects vit dans le client HTTP Zig. La suite real-apps épingle le spec alonetone sur l'exemple error-render (`account_requests_spec.rb:4`) en attendant le fix. Suivi : wishlist **A43** (fix shape inclus) — issue upstream pas encore filée.
