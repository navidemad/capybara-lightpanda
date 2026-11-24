# Sync target: Selenium (Ruby bindings)

Repo: https://github.com/SeleniumHQ/selenium (only `rb/lib/selenium/webdriver/`)
Role: **the API we imitate, not a design we borrow from.** Selenium is not a peer
CDP client — it is WebDriver-based and shares no architecture with this gem. It is
in scope for exactly one reason: `lib/capybara/lightpanda/browser/selenium_compat.rb`
answers to Selenium-named methods that shared Rails helpers call through
`page.driver.browser.<x>`, and a NoMethodError there kills every example in a file
before one real assertion runs.

Rules destination: `.claude/rules/ruby-cdp-peers.md` — but **only** when the shape
we emulate has actually drifted. This target usually produces no edit at all.

## This is a conformance check, not an adoption check

Ferrum and Cuprite answer "what should we adopt?". Selenium answers a narrower,
one-directional question:

> Do the entry points we emulate still have the shape callers expect?

We never adopt Selenium's design. The surface grows only when a real-app helper
needs an entry point (each one is pinned by `test/compatibility/selenium_contract.rb`
and listed in `CUPRITE_COMPATIBILITY.md`), never to mirror Selenium's API. A finding
here is only ever "our shape is stale", never "Selenium has a nice pattern we
should copy". A Selenium method we don't answer is a feature request, not drift.

## The only surface in scope

Each entry point with its Selenium counterpart (paths under
`rb/lib/selenium/webdriver/common/`; surface as of 2026-11-24, PRs #277–#283, #287, #288, #309):

| Ours | Selenium counterpart | What must stay true |
| --- | --- | --- |
| `selenium_compat.rb#logs` → `Logs#get(:browser)`, `#available_types` | `logs.rb`, `log_entry.rb` | entries answer `level` / `message` / `timestamp` (wall-clock epoch ms) and `time` / `as_json` / `to_s` (`"#{time} #{level}: #{message}"`), matching `LogEntry` exactly (checked 2026-11-20); `level` is the severity string (`SEVERE`/`WARNING`/`INFO`/`DEBUG`), not the CDP console type; uncaught page errors are SEVERE entries |
| `#manage.window.resize_to` | `manager.rb`, `window.rb` | `(width, height)` integers; we reject zero |
| `#manage.all_cookies` / `cookie_named` / `delete_all_cookies` | `manager.rb` | document-scoped; Hash keys `name value domain path expires(DateTime) secure http_only same_site`; `cookie_named` raises `NoSuchCookieError` |
| `#download_path=` | `driver_extensions/downloads_files.rb` | directory path |
| `#execute_async_script` | `driver.rb` | script receives a completion callback as its last argument |
| `#execute_cdp` | `driver_extensions/has_cdp.rb` | `(method_string, **params)`, page-session scoped |
| `#switch_to` | `target_locator.rb` | we raise `NotSupportedByDriverError` with a migration message; only revisit if Lightpanda ever gains post-hoc dialog handling |
| `#action.send_keys(*keys).perform` | `driver.rb#action(**)`, `action_builder.rb` | arrow keys and Enter only, others raise `NotSupportedByDriverError`; takes and ignores Selenium's `async:`/`devices:`/`duration:` (`Remote::Bridge#action`), an unknown keyword raises (#309) |
| `node.rb#native` (self) + `#attribute` | `element.rb` | `attribute` reads live properties (e.g. `validationMessage`) as strings |

```bash
# Has anything touched the files we imitate?
gh api 'repos/SeleniumHQ/selenium/commits?per_page=60&path=rb/lib/selenium/webdriver/common' \
  --jq '.[] | {sha: .sha[0:8], date: .commit.author.date[0:10], msg: (.commit.message | split("\n")[0])}'
```

## When to run it

**Not every sync.** These are among the most stable APIs in the Ruby ecosystem —
`Logs#get` has been shape-stable for a decade. Run it only when:

- `selenium_compat.rb` changed since the last sync, or
- a real-app failure shows a shared helper hitting a Selenium-named method we
  don't answer (that's a *missing* entry point, which is a gem feature request,
  not a drift finding), or
- the user asks for it explicitly.

Otherwise skip and say so. A full-repo Selenium recon is expensive and almost
always empty: SeleniumHQ/selenium is a multi-language monorepo (Java, Python, C#,
JS, Rust) where the overwhelming majority of traffic cannot touch `rb/`.

## Do not use PR #12429 as an anchor

Checked 2026-07-25 at the user's suggestion, and recorded here so it isn't
re-proposed: **SeleniumHQ/selenium#12429 is not relevant to this gem.** It is
`[rb] move Driver Finder logic out of Selenium Manager` — opened 2023-07-27 by
titusfortner, **CLOSED without merge**, touching `rb/lib/selenium/webdriver/common/driver_finder.rb`,
`selenium_manager.rb` and the logger. Selenium Manager's job is locating a
*WebDriver executable* (chromedriver/geckodriver) for a browser it did not ship.
This gem has no WebDriver layer at all; the nearest analogue,
`Capybara::Lightpanda::Binary`, downloads a single known binary from a known URL
and shares neither the problem nor the solution. Nothing in that PR transfers.

The general lesson is worth keeping even though this instance was a miss: scope
any Selenium check to `rb/lib/selenium/webdriver/common/` and to the four methods
above. Anything outside that path is out of scope by construction.
