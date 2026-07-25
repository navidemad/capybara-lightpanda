# Local boot harness for the real-apps matrix

Brings up one target from `.github/workflows/real-apps.yml` on a dev machine so
a single failing spec can be run and watched, with the gem's own instruments
attached.

Every unresolved cause in `.github/real-apps/causes.yml` carries the same
`next_step` — "boot the app and watch". This is that step, automated.

```bash
script/real-app/boot.sh solidus                    # provision (cold: ~10 min, warm: ~5 s)
script/real-app/spec.sh solidus \
  spec/features/admin/orders/order_details_spec.rb \
  -e "should allow me to make a split"
```

## What it is

`boot.sh` is `.github/workflows/real-apps.yml` ported step for step: same pinned
SHA, same Ruby/Node, same `work_dir` vs `spec_dir` split, same
`__CAPYBARA_LIGHTPANDA_PATH__` substitution, same pre-provisioned Lightpanda
binary. The matrix is **read out of the workflow**, not copied — `targets.rb`
parses `jobs.smoke.strategy.matrix.include`, so a re-pinned target needs no
change here. Only the parts CI does with `apt`, `systemctl` and service
containers are overridden, each with a note explaining why.

`spec.sh` runs rspec in the right directory with `--require probe.rb`, then
compares the failures against `.github/real-apps/baselines/<target>.txt` and
names the matching cause from `causes.yml`.

The app checkout is never modified beyond its patch: the Ruby version comes from
`mise exec` rather than a written `.tool-versions`, and the probe is injected
with rspec's `--require`, not a Gemfile entry or a `spec_helper` edit.

## Layout

```
~/.cache/capybara-lightpanda/real-apps/<target>/     # $REAL_APP_HOME
├── target/                  # the app checkout at the pinned SHA, patched
├── .state/                  # step markers — what makes a re-boot cheap
└── artifacts/<timestamp>/   # one directory per spec.sh run
    ├── rspec.log
    ├── report.json          # rspec JSON, the same shape CI compares
    ├── NNNN-<example>.json  # console_logs + network traffic for a failure
    └── NNNN-<example>.html  # the page body at failure time
```

`<target>/` mirrors CI's workspace layout (the checkout is at `target/`) so
`GITHUB_WORKSPACE=$ROOT` makes gem-sourced absolute spec paths normalize to the
same baseline keys CI records.

Artifacts are never pruned — a full-subset run of a target with 68 known
failures writes ~7 MB of page bodies. Delete old `artifacts/*` directories when
they stop being interesting, or run with `LIGHTPANDA_PROBE_HTML=0`.

## What a failing run tells you

```
─── lightpanda probe ─── Order Details as Admin Shipment edit page splitting …
  url      http://127.0.0.1:52341/admin/orders/R123456789/shipments [200]
  console  4 message(s), 1 error(s)
    [error] Uncaught TypeError: e.select2 is not a function
  network  18 request(s), 0 >=400, 1 without a response
    POST (no response) http://127.0.0.1:52341/admin/orders/R123456789/shipments/1/split
  full     …/artifacts/20260725-041233/0001-order-details-….json (+ .html)

[real-app] baseline: 1 failed of 1 run (0 not in .github/real-apps/baselines/solidus.txt)
  known ./spec/features/admin/orders/order_details_spec.rb # Order Details … make a split
        cause: select2-v3-flow (likely)
```

`console_logs` and `network.traffic` are the two instruments the harness exists
for: they separate "the request was never issued" from "it was issued and the
response never applied" — which is exactly the fork every `likely` cause in
`causes.yml` is stuck on.

The full JSON carries every console message (`type`, `text`, `timestamp`) and
every request (`method`, `url`, `response.status`, `response.headers`,
`mime_type`, plus `response: null` for anything still in flight). Raw CDP
`RemoteObject` args are dropped from the console entries; use
`LIGHTPANDA_DEBUG=1` if you need the wire.

## If the probe writes nothing

The run announces itself in two places — `[lightpanda-probe] armed → …` when the
suite starts and `wrote N artifact(s)` when it ends. If a failing example
produces no artifact, one of these is true:

- the arming line never printed → the target's suite doesn't load
  capybara-lightpanda (wrong driver, or the patch didn't apply);
- it printed but nothing was written → the failing example never had a live
  Lightpanda session (it failed before `visit`, or ran on `rack_test`).

The capture hangs off `Driver#reset!` rather than an `after` hook, because
config-level `after` hooks run in reverse registration order and Capybara's
`reset_sessions!` would otherwise clear both buffers first. If a future Capybara
changes that ordering, the artifacts stay correct — the after-hook sweep is the
fallback — but the `phase` field in the JSON flips from `pre-reset` to
`after-hook`, which is the tell.

## Cost of a re-run

Each expensive step leaves a marker in `.state/` and is skipped next time: the
checkout, the bundle, the JS deps, the database and the generated dummy app all
survive. A second `boot.sh` is a few seconds; `spec.sh` alone skips it entirely.

Redo one step with `FORCE=<step>` (`checkout`, `patch`, `bundle`, `node`, `db`,
`pre_spec`, or `all`). Editing a patch under `.github/real-apps/patches/`
invalidates the patch marker on its own — the marker is keyed by the patch's
checksum — and drops the bundle marker with it, since the Gemfile just changed.

Re-applying the patch resets the checkout to the pinned tree first, so any edits
you made inside `target/` while debugging are discarded at that point. Keep
throwaway probes in the spec invocation (`-e`, `--seed`) or the artifacts, not in
the app.

## Targets and what they need

| Target | Ruby | Node | Services | Notes |
| --- | --- | --- | --- | --- |
| `solidus` | 3.3 | — | none (sqlite) | generates a dummy app in `pre_spec`; `brew install shared-mime-info` |
| `spree` | 3.3 | — | none (sqlite) | nested layout: `work_dir=spree/admin`; same MIME db |
| `forem` | 3.3.9 exact | 20 | postgres, redis | needs pgvector (`CREATE EXTENSION "vector"`) |
| `decidim` | 3.4 | 22 | postgres | generates + moves a dummy app |
| `mastodon` | 4.0 | 24 | postgres, redis | `brew install libidn` for idn-ruby |
| `alonetone` | 4.0 | 22 | mysql (root/root) | `brew install mysql` |

Missing Rubies and Node versions are installed through `mise` on demand
(`SKIP_RUBY_INSTALL=1` to refuse instead). Services are checked before anything
slow runs, because an unreachable database otherwise surfaces minutes later as
an adapter error.

**Postgres credentials.** CI uses `postgres/postgres`; Postgres.app creates a
superuser named after the login user. `boot.sh` probes both and exports whichever
answers — export `PGUSER`/`PGPASSWORD` yourself to override.

## Env knobs

| Variable | Effect |
| --- | --- |
| `REAL_APP_HOME` | where checkouts live (default `~/.cache/capybara-lightpanda/real-apps`) |
| `FORCE=<step\|all>` | redo a completed boot step |
| `SKIP_RUBY_INSTALL=1` | fail instead of installing a missing toolchain |
| `LIGHTPANDA_PROBE_ALWAYS=1` | capture passing examples too |
| `LIGHTPANDA_PROBE_HTML=0` | skip the page-body dump |
| `LIGHTPANDA_DEBUG=1` | the gem's own CDP-level logging |

## Related

- `.github/real-apps/README.md` — the manual version of this, and how patches are
  refreshed when a target is re-pinned.
- `.github/real-apps/causes.yml` — why each baseline failure fails; the thing
  this harness exists to move from `likely`/`unknown` to `confirmed`.
- `script/real-app-coverage/` — the same idea for the private Rails app: a
  Minitest reporter injected through `RUBYOPT`, run over a whole suite for
  coverage trends rather than one spec for diagnosis.
