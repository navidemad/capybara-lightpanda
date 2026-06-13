# Cluster #1 — Multipart form submit reaches Rails with an empty body

**Status:** Root cause confirmed (Lightpanda browser-side). NOT minimally reproduced. NOT gem-fixable.
**Last investigated:** 2026-06-13, against browser build `1.0.0-dev.6750+ab53f92a`, gem `0.8.0`.
**Affected tests:** all 25 `AdminLandingPageSectionsBlocksEditorTest#test_*_editor_saves_without_errors` in the target Rails app (`test/system/admin/landing_page_sections/blocks_editor_test.rb`). Largest single cluster in the lightpanda system run (25 of 85 failures).

---

## Symptom

Every editor "save" test errors with:

```
ActionController::BadRequest: Invalid request parameters: Rack::Multipart::EmptyContentError
```

Rack raises this when a request arrives with `Content-Type: multipart/form-data` but an empty body. The error surfaces in middleware (`config/initializers/permissions_policy.rb:39`) but originates wherever Rails first parses `params` — i.e. before the controller action runs.

The split is decisive: the 25 `..._editor_loads_without_errors` tests **pass** (24/25). The 25 `..._editor_saves_without_errors` tests all **error**. Only the form submission fails.

## Confirmed root cause

A **single** native form submission of a `multipart/form-data` form produces an HTTP request whose **body is never written**. Measured at the moment of failure in the live app:

- `submit` events fired: **exactly 1** (instrumented via a capture-phase listener → `console_logs`).
- POST requests: **exactly 1** (one CDP `requestId`, valid boundary).
- That POST: `hasPostData: true`, `Content-Type: multipart/form-data; boundary=<valid-uuid>`, but `Network.getRequestPostData` returns no body (`BrowserError` / `len=nil`).

So it is **NOT a double-submit** (an earlier hypothesis — the "2 `requestWillBeSent` with the same boundary" was the request lifecycle emitting the event twice for one request, not two submissions). It is one submission, empty body, browser-side.

`JS-side new FormData(form)` enumerates the real form correctly (29 entries, 0 files, 111 chars), so the browser *can* read the form data — it just fails to serialize it into the request body on the wire.

## Why it is not gem-fixable

There is only one submission and zero JS involvement (see elimination table). No gem-side JS latch, click-path change, or submit-routing can put bytes into a body the browser drops. Multiple gem-side `CLICK_JS` rewrites were tried (pre-cancel + `requestSubmit`, one-shot native-submit guard); each either failed to fix the app suite or regressed the gem's own "Turbo-compatible form submission" feature tests. All were reverted. `lib/capybara/lightpanda/node.rb` `CLICK_JS` is unchanged from HEAD.

## Elimination table (what was ruled out)

Signal: HTTP response status of the editor POST captured via CDP `Network.responseReceived` (500 = empty body; 2xx/3xx = body delivered). Deterministic.

In the **real Rails app**, ALL of these still produced 500:

| Variant | Result |
|---|---|
| Baseline editor save | 500 |
| `Turbo.session.stop()` before submit | 500 |
| `Turbo.session.drive = false` | 500 |
| Stimulus application stopped | 500 |
| **Form cloned** (every JS listener stripped) | 500 |
| **Brand-new minimal 1-field multipart form** injected, submitted | 500 |
| Minimal form submitted from a simple admin page (not the editor) | 500 |
| Minimal form submitted from a blank `data:` page | 500 |

In **standalone Lightpanda + CDP (no Rails)**, ALL of these delivered the body correctly (NOT reproduced):

| Variant | Body bytes |
|---|---|
| Plain multipart, text + hidden fields | full |
| Multipart with an empty `<input type=file>` | full |
| Multipart + `_method=patch` override | full |
| Fields nested inside `<turbo-frame>` + `data-turbo="false"` | full |
| Real `@hotwired/turbo` loaded on the page | full |
| The **exact captured hero form** (36 elements, 12 selects) | full |
| 29-field `_method=patch` multipart form | 2904 |
| Cookie set (`session_id`) + multiple navigations | 584 |
| 302 redirect on the POST | 584 |
| Through the **full gem `Node#click`** in the gem's own Capybara+Puma test app (3/3 runs) | 1166 |

## The wall

The bug is **100% deterministic but bound to the real Rails app**. A trivial freshly-injected multipart form, submitted from a blank page, to the real app's `/landing_page_sections/:id` endpoint, still arrives empty — yet the same form to a hand-rolled echo server, or to the gem's Puma test app, arrives full. At the CDP request level the failing and working requests look identical (`multipart/form-data`, valid boundary, `hasPostData:true`, no surfaced `Content-Length` in either). The divergence is on the wire — how Lightpanda streams the multipart body to *this specific server* — and could not be reproduced without the actual Rails app running.

## Open question for the next session

What property of the real target Rails app's HTTP handling makes Lightpanda drop the multipart body, when an echo server and the gem's own Puma test app both receive it intact?

Untested hypotheses (each is a concrete next experiment):
1. **`Expect: 100-continue` handling.** Does Puma-under-Rails send an interim `100 Continue` that Puma-under-the-gem-test-app does not (e.g. due to body size, or a Rack/Rails config), and does Lightpanda send headers then fail to send the body after it? Capture whether the failing request ever waits on a `100 Continue`.
2. **Request body size threshold.** The real `landing_page_section` body (~1–3 KB across 29 fields) is in the same range as passing standalone repros, but the real app's *total request* (cookies, CSRF, many headers) is larger. Test a standalone multipart POST with a large header block + large cookie to push past a buffer boundary.
3. **A specific middleware in the real stack** consuming/rewinding `rack.input` before Lightpanda finishes streaming. The stack includes `Utf8SanitizerMiddleware`, `DevelopersZenparkHostRedirectMiddleware`, `PlatformDetectionMiddleware`, `Rack::Attack`, `RackSessionAccess::Middleware`. Reproduce by mounting just one of these in front of the gem's test app (note: inserting middleware into a booted Rails stack fails with `FrozenError` — build a minimal Rack app that `use`s the suspect middleware instead).
4. **Keep-alive / connection reuse.** The real session reuses a connection across many requests; the standalone repros use fresh `Connection: close` responses. Test a standalone server with `Connection: keep-alive` and several prior requests on the same socket, then a multipart POST.
5. **HTTP layer probe.** Capture the raw bytes Lightpanda puts on the socket for the failing POST (e.g. a TCP proxy/`tcpdump` between Lightpanda and Puma) to see exactly where the body is or isn't — this is the most direct path and bypasses all guessing.

The most efficient next step is hypothesis 5 (raw wire capture) or 1 (`100-continue`), because they look at the transport directly rather than re-permuting app conditions.

## How to reproduce the failure (fastest)

```bash
# 1. Point the target Rails app at the local gem (so any CLICK_JS edits load):
cd $APP_DIR
# in Gemfile line 126, swap to: gem "capybara-lightpanda", path: "../capybara-lightpanda", require: false
bundle install

# 2. Run one failing test (uses the dev.6750+ build in ~/.cache/lightpanda):
BROWSER=lightpanda PARALLEL_WORKERS=0 bundle exec rails test \
  test/system/admin/landing_page_sections/blocks_editor_test.rb \
  -n "/hero_editor_saves_without_errors/"
# => ActionController::BadRequest: Rack::Multipart::EmptyContentError

# 3. Restore the Gemfile + Gemfile.lock when done (back up first).
```

The empty-body signal in code: subscribe to CDP `Network.responseReceived` for the editor POST `requestId`; status 500 == empty body.

---

## RESUME PROMPT (paste into a fresh Opus session in /Users/navid/code/capybara-lightpanda)

> You are resuming a paused investigation in the `capybara-lightpanda` gem. Read
> `script/real-app-coverage/findings/cluster-1-multipart-empty-body.md`
> in full before doing anything — it contains the complete prior findings, an
> elimination table, and untested hypotheses. Do NOT re-run the experiments that
> are already in the elimination table; trust them.
>
> Context in one line: a `multipart/form-data` form submitted from Lightpanda
> reaches the real the target Rails app app with an empty body (`Rack::Multipart::EmptyContentError`),
> but every standalone reproduction (pure Lightpanda+CDP, and the gem's own
> Capybara+Puma test app) delivers the body intact. One submission, no
> double-submit, no JS involvement — confirmed browser-side, not gem-fixable.
>
> Your goal: find the minimal Rails-free reproducer by attacking the HTTP
> transport directly. Start with hypothesis 5 (raw wire capture between
> Lightpanda and the server — a TCP proxy or tcpdump on the loopback port the
> Capybara Puma server binds) to see exactly where the body is or isn't on the
> socket; then hypothesis 1 (`Expect: 100-continue`). The browser binary is at
> `~/.cache/lightpanda/lightpanda` (verify it is still `dev.675x+`; if the gem
> re-downloaded a published nightly, rebuild from `/Users/navid/code/browser`
> `main` with `zig build -Doptimize=ReleaseSafe` — note: a from-scratch V8
> build needs full Xcode, not just CLT; this machine is CLT-only, so the
> already-built `zig-out/bin/lightpanda` is the fallback).
>
> Constraints and discipline:
> - This is a browser bug; do NOT attempt a gem-side `CLICK_JS` workaround
>   (already tried and reverted — there is nothing to latch onto).
> - To test against the app, point its Gemfile line 126 at
>   `path: "../capybara-lightpanda"`, `bundle install`, and ALWAYS restore the
>   backed-up Gemfile + Gemfile.lock when finished. Run system tests with
>   `BROWSER=lightpanda PARALLEL_WORKERS=0 bundle exec rails test <file>`.
> - Signal: CDP `Network.responseReceived` status for the editor POST — 500 ==
>   empty body, 2xx/3xx == body delivered. It is deterministic in-app.
> - Keep both repos clean: revert any diagnostic edits to `test/support/test_app.rb`
>   and `lib/capybara/lightpanda/node.rb`, and remove scratch files when done.
> - Budget honestly. If the wire capture pins the cause, write it up and file an
>   upstream issue per the `lightpanda-upstream-pr` skill (it needs a minimal,
>   Rails-free repro — the wire capture should give you one). If you again hit
>   "needs the full app," say so plainly and stop rather than thrashing.
>
> Deliverable: either a minimal Rails-free reproducer (HTML + tiny server +
> CDP submit script that shows the empty body) ready for an upstream issue, or
> an updated findings file with the new elimination rows and a sharpened next
> hypothesis.
