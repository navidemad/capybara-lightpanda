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

> Do the four entry points we emulate still have the shape callers expect?

We never adopt Selenium's design. We do not grow the emulation layer — that limit
is stated in `selenium_compat.rb` itself and is a deliberate boundary, not an
oversight. A finding here is only ever "our shape is stale", never "Selenium has a
nice pattern we should copy".

## The only surface in scope

Four entry points, each with its Selenium counterpart:

| Ours (`selenium_compat.rb`) | Selenium counterpart | What must stay true |
| --- | --- | --- |
| `#logs` → `Logs#get(:browser)` | `rb/lib/selenium/webdriver/common/logs.rb` | entries answer `level` / `message` / `timestamp`; `level` is the severity string (`SEVERE`/`WARNING`/`INFO`/`DEBUG`), not the CDP console type |
| `#execute_async_script` | `rb/lib/selenium/webdriver/common/driver.rb` | script receives a completion callback as its last argument |
| `#execute_cdp` | `rb/lib/selenium/webdriver/common/driver.rb` | `(method_string, **params)`, page-session scoped |
| `#switch_to` | `rb/lib/selenium/webdriver/common/target_locator.rb` | we raise `NotSupportedByDriverError` with a migration message; only revisit if Lightpanda ever gains post-hoc dialog handling |

```bash
# Has anything touched the three files we imitate?
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
