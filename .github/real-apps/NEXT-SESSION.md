# Kickoff prompts for the remaining baseline work

Two prompts to paste into a fresh session. They exist because the knowledge
needed to continue is now on disk (`causes.yml`, `findings/`, `real-apps.yml`),
so a new session can reload it in a few reads instead of re-deriving it — but
only if it is pointed at the right files and told what has already been tried.

## What is actually left

14 baseline failures as of the 2026-10-12 refresh (run 38261324053, gem 0.14.1
on that day's nightly), all attributed in `causes.yml`. The refresh dropped 83
entries, including whole clusters this file used to call permanent:
`layout-measuring-js` (38, "never fixable") and `multipart-content-loss` (A45)
both cleared. Nobody has checked which upstream change cleared them, so don't
read either as understood.

| Lot | N | Reality |
| --- | --- | --- |
| `jquery1-change-shim` | 5 | Fixed in the gem (`event_handlers.js`, 2026-10-14). Drops at the next refresh; upstream wishlist A61. |
| `no-change-on-blur` | 1 | Confirmed upstream gap (wishlist A62). |
| `selenium-only-api` (`switch_to.alert`) | 1 | Fails by design. Lightpanda pre-arms dialog responses. |
| `selenium-textarea-text` | 1 | `likely` — the spec relies on Selenium's visible text including a textarea's child text. |
| `customer-switch-refill` | 2 | Open, `unknown`. |
| `decidim-account-js` | 2 | Open, `likely` (avatar widget visibility). |
| `select2-v3-flow`, `js-component-not-rendering` | 2 | Open, one entry each. |

Once the jquery1 entries drop, the open work is the 6 entries in the last three rows, plus filing A62 upstream.

---

## Prompt 1 — build the local boot harness — DONE (2026-07-25)

Shipped as `script/real-app/` (`boot.sh`, `spec.sh`, `probe.rb`, `targets.rb`);
see its README. `boot.sh solidus` takes a clean machine to a runnable suite,
`spec.sh <target> <spec> -e "<example>"` runs one example with `console_logs` +
`network.traffic` captured per failure and tells you which `causes.yml` entry the
failure matches. Warm re-runs are ~1 s. The original prompt is kept below for
provenance.

> Build `script/real-app/boot.sh <target>`: bring up one real-apps matrix target
> locally so a single failing spec can be run and instrumented.
>
> This is the blocker for everything else. Every unresolved cause in
> `.github/real-apps/causes.yml` carries the same `next_step` — "boot the app and
> watch" — and nothing automates that, so every past investigation rebuilt the
> setup by hand. That is why A45 has been open since June.
>
> **Read first**
> - `.github/workflows/real-apps.yml` — the boot recipe already exists here, per
>   target: pinned SHA, ruby/node versions, `work_dir` vs `spec_dir`, `db_create`,
>   `pre_spec`, and the `__CAPYBARA_LIGHTPANDA_PATH__` sed. The step comments
>   record the traps (why `DATABASE_URL` must not be set job-wide, why the
>   Lightpanda binary is pre-provisioned before WebMock loads, why Forem pins an
>   exact Ruby patch). Port them; do not rediscover them.
> - `script/real-app-coverage/run.sh` — the pattern for injecting a reporter via
>   `RUBYOPT` without touching the app's Gemfile or test helper. Reuse the idea.
> - `.github/real-apps/README.md` — the manual steps this replaces.
>
> **Done when**
> 1. `script/real-app/boot.sh solidus` takes a clean machine to a runnable suite.
> 2. One spec can then be run in isolation, e.g. `order_details_spec.rb -e "should
>    allow me to make a split"`, and it fails the same way CI reports it.
> 3. That run surfaces the gem's own instruments: `browser.console_logs` and
>    `network.traffic` for the failing example. Without those two, the harness
>    has not solved the problem it exists for.
> 4. Re-running is cheap — the checkout, bundle and DB survive between runs.
>
> **Non-goals**
> - Don't modify the target app beyond its patch.
> - Don't hard-code the private app path from `script/real-app-coverage/`.
> - Don't try to make any spec pass. This session builds observability, nothing else.

---

## Prompt 2 — investigate one cluster

Run once per cluster. Substitute the slug.

> Take the `<slug>` cluster from `.github/real-apps/causes.yml` from its current
> confidence to `confirmed`, or prove it belongs elsewhere.
>
> **Read first**
> - the cause's entry in `causes.yml` — summary, confidence, `next_step`
> - `script/real-app-coverage/findings/cluster-1-multipart-empty-body.md` — the
>   expected output format. Note the elimination table: hypotheses ruled out, one
>   per row, with the signal that ruled each one out. That table is the artifact,
>   not the prose around it.
> - `.claude/skills/lightpanda-upstream-pr/references/upstream-wishlist.md` for
>   whether a neighbouring entry already covers it
>
> **Done when**
> 1. The mechanism is named and *proven* — instrumented on a booted app, not
>    inferred from reading the spec's source.
> 2. It has a disposition: a gem fix, an upstream issue with a CDP-only
>    reproducer (never Ruby/Capybara — see the `lightpanda-upstream-pr` skill),
>    or "inherent" with a dual-driver note.
> 3. `causes.yml` is updated: confidence, `reference`, and `next_step` removed
>    or replaced.
> 4. A finding is written in the format above.
>
> "The test passes" is deliberately **not** the criterion. For a driver gem,
> turning an unknown into a confirmed cause filed upstream is real progress even
> while the test stays red.
>
> **Non-goals**
> - Editing a baseline to make a number smaller.
>
> **Traps already paid for**
> - A probe that loops over variants inherits the previous iteration's state. A
>   viewport left at 375px made four CSSOM mutations look like they forced a
>   re-cascade; none of them did. Reset between iterations, and be suspicious of
>   a probe where every variant "works".
> - The GitNexus index goes stale and reports `0 callers` for symbols that have
>   them. Confirm with grep before treating an edit as low-risk.
> - `capybara-specs` is gated on `github.event_name == 'push'` with
>   `on.push.branches: [main]`, so the Capybara battery never runs on a pull
>   request. A green PR does not mean the battery passed — run
>   `bundle exec rake spec:shared:parallel` locally before saying it did.

---

## Do these first

**~~Reconcile A45~~ — moot 2026-10-12.** Every `multipart-content-loss` entry
passed on run 38261324053 and the cause was retired. Reopen it only if
`Invalid request parameters` / `ActionController::BadRequest` comes back as a
new failure; the diagnosis is in `git log -p .github/real-apps/causes.yml` and
wishlist A45.

**~~Then `select2-v3-flow`~~ — DONE 2026-07-25.** The premise was wrong: the
helper reaches select2 fine and the pick registers. 15 of the 16 entries are
`select-optgroup-invisible` (wishlist A52) — Lightpanda's `HTMLSelectElement`
walks direct children only, so the destination `<option>`s inside `<optgroup>`
are invisible to `options`/`value`/`selectedIndex`/`selectedOptions` and to form
submission; jQuery's `.val()` setter then drives `selectedIndex` to -1 and the
getter returns `null`, and solidus's handler throws before it can POST. Confirmed
in the booted app and with a Ruby-free flat-vs-grouped reproducer; not
gem-fixable. See `findings/cluster-3-select-optgroup-options.md`. The 16th entry
(`products/edit/taxons_spec.rb`) is still `select2-v3-flow` and still open.

**Done 2026-10-14**: `ajax-partial-not-applied`, `address-state-not-toggled`
and `search-returns-nothing` were mostly one bug, jQuery 1.12's change shim
(wishlist A61), fixed in the gem. **Next**: `customer-switch-refill` (2,
unknown), same harness, same method.
