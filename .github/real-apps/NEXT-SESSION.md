# Kickoff prompts for the remaining baseline work

Two prompts to paste into a fresh session. They exist because the knowledge
needed to continue is now on disk (`causes.yml`, `findings/`, `real-apps.yml`),
so a new session can reload it in a few reads instead of re-deriving it — but
only if it is pointed at the right files and told what has already been tried.

## What is actually left

101 baseline failures, all attributed in `causes.yml`. They are not 101 pieces
of work:

| Lot | N | Reality |
| --- | --- | --- |
| `layout-measuring-js` | 38 | Never fixable. Needs a layout engine. Document it, stop counting it as debt. |
| `select-optgroup-invisible` | 15 | Root-caused 2026-07-25 (wishlist A52, `findings/cluster-3-…`). Browser-side, not gem-fixable; needs an upstream fix then a floor bump. |
| `form-method-dialog` | 5 | Already fixed. Waiting on upstream lightpanda-io/browser#3054, then a `MINIMUM_NIGHTLY_BUILD` bump. |
| `selenium-only-api` | 2 | Already fixed by #104; drops at the next scheduled run. |
| `selenium-only-api` (`switch_to`) | 1 | Fails by design. Lightpanda pre-arms dialog responses. |
| Everything else | **40** | Genuinely open, mechanism not identified. |

Targeting "101" rewards gaming the baseline and makes 38 inherent limitations
look like a lack of effort. The honest target is 40.

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
> - `layout-measuring-js` (38 entries). Inherent, needs real layout. Leave it.
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

**Reconcile A45.** `findings/cluster-1-multipart-empty-body.md` (2026-06-13)
states "root cause confirmed, browser-side": one submission, `hasPostData:
true`, a valid boundary, and `Network.getRequestPostData` returning no body.
Wishlist A45 (2026-07-24) states the opposite: the generic path is exonerated on
both platforms, `Content-Length` always matched the bytes sent, root cause
unknown. Both cannot describe the same path. This is 11 baseline entries and the
oldest open item, and it can be settled without the new harness — the finding
came from the private app that `APP_DIR` already drives. If it revives a
confirmed root cause, it changes what the harness needs to capture.

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

**Next largest addressable cluster**: `ajax-partial-not-applied` (7, likely).
Same harness, same method — the question there is whether the request is issued
at all, which `network.traffic` answers in one run.
