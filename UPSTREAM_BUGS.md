# Bugs upstream Lightpanda (`lightpanda-io/browser`)

Inventaire des limitations du binaire Lightpanda découvertes en exécutant des suites Capybara réelles (Rails 8 + Hotwire). Chaque bug est documenté avec un repro minimal et un workaround côté gem.

Quand un bug est résolu upstream, le workaround correspondant côté gem peut être retiré.

La numérotation démarre à #11 : les bugs #1–#10, résolus ou rétractés upstream, ont été retirés de ce fichier. Les numéros sont conservés (pas de renumérotation) car ils restent référencés depuis les tests (`test/features/upstream_bugs_test.rb`).

Derniers retraits (2026-06-12) :

- **Bug #9** (`requestSubmit()` jetait quand un listener cancel le SubmitEvent) — résolu upstream, vérifié par probe CDP pur sur nightly 6736 (très probablement PR upstream #2639). Le workaround `try/catch` de `CLICK_JS` avait déjà été retiré lors d'un refactor antérieur ; un contract test couvre désormais le chemin (`upstream_bugs_test.rb`, « Bug #9 »).
- **Bug #10** (`Runtime.evaluate` retenait les `const`/`let` top-level entre appels) — rétracté : parité Chrome, pas un bug. Chrome lève la même `SyntaxError` sans `replMode` ; les déclarations lexicales top-level persistent entre classic scripts per spec. Fix gem : `browser.rb` passe `replMode: true` (sémantique console DevTools) au lieu du wrapping IIFE ; le raise sur `exceptionDetails` est conservé. Contract tests : `upstream_bugs_test.rb`, « Bug #10 ».

---

## Bug #11 — Réponse 3xx sans header `Location` : navigation avortée, body jamais rendu

Per RFC 9110 §15.4 (et le fetch spec), une réponse 3xx sans header `Location` est une réponse finale normale dont le body doit être délivré — Chrome la rend. Lightpanda route tout status 300–399 dans le chemin redirect (`src/browser/HttpClient.zig`, `processOneMessage`) et `handleRedirect` retourne `error.LocationNotFound` quand le header est absent. L'ancien document est détruit, rien ne le remplace : la page n'a plus de nœud `<html>` (Capybara : `Unable to find xpath "/html"`).

### Repro minimal

App Rack où `POST /submit` → `[303, {"content-type" => "text/html"}, ["<h1>Thank you</h1>"]]` ; cliquer le bouton submit du formulaire via le gem → plus de document. Contrôle : la même réponse avec status 422 est rendue correctement. Vérifié 2026-06-12 sur nightly 6703.

### Impact

Idiome Rails pour satisfaire le check Turbo « Form responses must redirect to another location » sans rediriger : `render 'thank_you', status: 303` (pas de `Location`). Rencontré sur le flow signup d'alonetone (`spec/features/account_requests_spec.rb`, « submits the form and succeeds ») en l'ajoutant à la suite real-apps ; avec Turbo devant, le symptôme s'adoucit en « la page reste sur le formulaire ».

### Workaround côté gem

Aucun possible — la gestion des redirects vit dans le client HTTP Zig. La suite real-apps épingle le spec alonetone sur l'exemple error-render (`account_requests_spec.rb:4`) en attendant le fix. Suivi : wishlist **A43** (fix shape inclus) — issue upstream pas encore filée.
