# Ruby CDP Peer Gems

Current design comparisons maintained by sync-upstream. Paths on the gem side are relative to `lib/capybara/lightpanda/`; peer paths are relative to `lib/`. Use symbol names rather than drifting line numbers.

## Ferrum

https://github.com/rubycdp/ferrum — reviewed 2026-11-24; release v0.21.0 (2026-11-24, `58a7628760`), main `37592371c5` (0.22: #728 removes the 0.21 deprecations). Open: #685 (out-of-process iframe idle tracking) only.

0.21 audited, no change needed: #707 one `Deadline` per composite call (immune: `browser/navigation.rb#go_to` shares one deadline, `downloads.rb#wait` sets no latch on timeout, `client/subscriber.rb#unsubscribe` removes by block); `99b6c1710f` all-nil/false positional evaluate arguments dropped (immune: `browser/runtime.rb` tests `args.empty?`, not `any?`); `1b4c3686c0` `cookies.set` accepts `http_only`/`same_site` (ours takes those keywords natively, `cuprite_cookies.rb` maps the CDP spellings); #703/#710 callbacks and raw events yield the object/params alone (`client/subscriber.rb#dispatch` already does); #674 click wait, #696 quad fallback, `Node#moving?`, Fetch/auth, #705 CBOR depth, #704/#706, #711 `wait_for_new_page`, #714 Browser-facade delegation, #715 SameParty removal, #718 Fetch `request_id`/`post_data` renames, #719 toggles, #720 `click(button:, count:, modifiers:)`, #721 scroll `x:`/`y:`, #724 sub-second `request.time`, #725 objectId hashes, #726 `pinpoint`, #727 command return values (no geometry fallback, no interception, single target, no SameParty: N/A); #722 `html` replacing `body` (ours answers both: `browser.rb#body`, alias `html`). The 0.21 renames a migrating suite calls are under Outstanding. `page.cookies` becomes page-URL-scoped while `context.cookies` keeps every cookie; our `Cookies#all` stays context-wide.

### Adopted

- `ferrum/client.rb` ↔ `client.rb#start_message_thread`, `client/web_socket.rb#start_reader_thread`: connection death releases pending commands; transport exceptions must not abort the host process.
- `ferrum/node.rb#exists?` ↔ `node.rb#exists?`: attached-guard probe returns false only for obsolete/missing nodes or missing context; unrelated errors escape.
- `ferrum/utils/event.rb` ↔ `utils/event.rb`: reset iteration counters expose waits raced by a reset.
- `ferrum/cookies/{cookie.rb,../cookies.rb}` ↔ `cookies.rb`: typed/Enumerable cookies and YAML persistence; native `all` returns an Array, the opt-in Cuprite driver's `cuprite_cookies.rb#all` the name-keyed Hash.
- `ferrum/node.rb#wait_for_stop_moving` ↔ `node.rb`: consecutive rect samples; our timeout behavior deliberately differs below.
- `ferrum/network.rb` ↔ `network.rb`: traffic, idle and headers; close redirectResponse hops and loadingFailed entries to avoid stranded pending requests. Only wait_for_idle! raises.
- `ferrum/network/exchange.rb` ↔ `network/exchange.rb`: Exchange/Response answer `request.url`, `response.status`, `finished?`, but subclass Hash so symbol-key traffic assertions keep working.
- `ferrum/headers.rb` ↔ `request_headers.rb`: get/set/add/clear; `add(permanent: false)` keeps a Referer off subrequests and sends it with `Page.navigate` only, as Ferrum 0.20 does (0.21 drops it, see Outstanding). Session reset clears overrides.
- Ferrum `Page#wait_for_reload` ↔ `browser/navigation.rb#wait_for_reload`: returns on a main-frame load, a same-document navigation or expiry, truthy either way.
- `ferrum/contexts.rb#reset` ↔ `browser.rb#reset`, `driver.rb#reset!`: context disposal isolates sessions; Network#reset must forget the disposed domain's enabled state. Failed reset discards the browser.
- `ferrum/utils/attempt.rb` ↔ `utils/attempt.rb`: bounded retry with the peer's 6 × 0.1 s defaults, which no caller uses: `browser.rb#with_default_context_wait` passes 3 tries with no sleep (it waits on executionContextCreated instead), `client/web_socket.rb#connect_with_retry` 10 × 0.1 s on a refused TCP connect.
- `ferrum/errors.rb` ↔ `errors.rb`: CDP error hierarchy, response/code/data and JavaScript stack formatting; compat-only classes remain valid rescue constants.
- Ferrum callback dispatch ↔ `client/subscriber.rb#dispatch`: per-callback rescue prevents one handler from blocking others.
- `ferrum/frame/runtime.rb` ↔ `browser/runtime.rb`: evaluate awaits promises, execute discards values, evaluate_async supplies Capybara's callback. Ferrum's named-argument API differs; keep Capybara positional arguments here.
- `ferrum/downloads.rb` ↔ `downloads.rb`: browser-level events and blocking wait; ours needs begin-grace because click may return before downloadWillBegin is processed. The block form (`wait { click }`) records the baseline before yielding and gives the download the full timeout to start.
- Ferrum Process::Output ↔ `process.rb#output`, `browser/navigation.rb#crash_output`: retain bounded startup/runtime output for crash diagnosis.
- Ferrum WebSocket#force_close ↔ `client/web_socket.rb#close_socket`: release the socket even when the connection is already dead.
- Ferrum bounded write ↔ `client/web_socket.rb#write`: nonblocking send with a no-progress timeout; a stalled browser must not freeze caller and close under the driver mutex.
- `ferrum/cookies.rb#set` ↔ `cookies.rb#set`: preserve the browser's success verdict rather than claiming every cookie was accepted.
- Ferrum CyclicObject ↔ `browser/runtime.rb#serialize_remote_object`: ours replaces the whole refused value; Ferrum's deep serializer can preserve everything but the back-reference.
- Ferrum lone-surrogate recovery ↔ `client/web_socket.rb#parse_message`: replace unpaired UTF-16 escapes with U+FFFD only after JSON parse failure, so the response is delivered rather than lost.
- Ferrum cross-world error mapping ↔ `client.rb#handle_error`: stale argument handles map to NodeNotFoundError, allowing Capybara reload.
- Ferrum #723 connect bounds ↔ `client/web_socket.rb#connect_with_retry`, `#connect`: the TCP connect shares `handshake_timeout` (an unreachable `ws_url` host no longer waits out the OS timeout), and a connect that fails before the reader starts closes its socket.

### Transport constraints

- `client.rb#next_command_id` locks ids; WebSocket text/close/parse share @driver_mutex. The handshake parse precedes the reader thread. This avoids the two races described by Ferrum #602.
- JRuby audit (2026-10-26): script/audit_websocket.rb passed an idle reader plus 100 messages from four senders with pings on MRI 4.0.9/JRuby 10.1.2.0 + websocket-driver 0.8.1. Removing the reader-readiness guard hung past 15 s. Ferrum #680's merged writer queue is not a reason to remove that guard; this is a bounded probe, not universal JRuby safety.
- `client.rb#command`'s `timeout` is one deadline for lock wait, write and response. A frame still queued behind `@driver_mutex` at the deadline raises TimeoutError and keeps the connection; a frame cut off mid-write raises DeadBrowserError and closes it (a partial frame can't be reused); a response that landed during the send is still returned. Close/pong frames keep the no-progress `options.timeout`.
- `client.rb#observe_async_command`: navigation arms its handlers before `Page.navigate` is sent and never blocks on the reply, so a late reply can't delay the page or answer the next visit. `command(on_success:)` applies its state change on the message thread before the caller wakes or the next event dispatches; the callback must not issue CDP commands.

### Outstanding adoption candidates

- **[medium]** Ferrum Frame lifecycle events ↔ Network idle/Turbo tracking: Lightpanda exposes lifecycle events and, from 11698, `LP.waitUntil` with a `settled` state, but adopt another signal only after a real-app failure demonstrates a gap.
- **[medium]** Ferrum 0.21 API ↔ `browser/navigation.rb`, `request_headers.rb#add`, `network.rb`, `downloads.rb`, `cuprite_driver.rb`: `go_to(url, referrer:)` replaces `headers.add(permanent:)` (`5743cc85dc`), `network.emulate(user_agent:, accept_language:)` replaces navigator overrides through headers (`4702d99a79`), and the wait family becomes `await_navigation { }`, `await_download { }`, `network.wait_idle(!)`, `go_to!`/`refresh!`/`back!`/`forward!` (#716, #717; the 0.20 names forward with a warning until 0.22). Cuprite 0.21 docs show the new names (#367–#370), so a suite written against them gets ArgumentError/NoMethodError on our Cuprite page. Keep `permanent:` and the 0.20 names for native callers; the private `browser/navigation.rb#await_navigation` (returns a deadline) must be renamed before a Ferrum-shaped one is exposed. Ferrum's go_to Referer-resend fix doesn't transfer: `RequestHeaders#set` already resets `@referrer`. Ferrum 0.21.0 shipped 2026-11-24 and Cuprite main requires it (`1c21c997ff`); ship before Cuprite 0.21 releases.

### Diverged on purpose

- `ferrum/frame/runtime.rb` ↔ `browser/runtime.rb`: no Chrome deep serialization in Lightpanda; use node/array handles and plain-object returnByValue. Node identity stays objectId-only, avoiding peer frontend-nodeId invalidation bugs.
- Ferrum isolated worlds ↔ `_lightpanda` page-world bundle: frame node handles and Lightpanda's top-context callFunctionOn require the existing page-world/frame-eval paths.
- Ferrum console ↔ `browser/console.rb`: page_errors is separate from console_logs; combining Runtime.exceptionThrown/Log with console messages breaks suites asserting a clean console. Console stackTrace is browser-blocked.
- `ferrum/mouse.rb` ↔ `node.rb#click`: approximate geometry does not justify a coordinate Mouse API. Synthetic CLICK_JS events drive anchor navigation; do not assume native click-in-progress behavior applies.
- Ferrum NodeMovingError ↔ `node.rb#wait_for_stop_moving`: proceed after bounded polls; without real animation/layout, persistent rect changes are script mutation rather than a reason to fail.
- Ferrum Frame ↔ `browser.rb#frame_stack`: iframe Nodes already provide the top/parent/element switching surface; a wrapper has no demonstrated consumer.
- Ferrum #672/#685 frame idling ↔ `browser.rb` navigation sniff: ours waits on the main frame, so the Chrome PDF/OOPIF child-detach wait defect does not transfer directly. No claim of child-frame idle parity.
- Ferrum #675 thrown values ↔ `browser/runtime.rb#raise_on_js_error!`: inspect exceptionDetails regardless of Error subtype; a returned Error is a value, not an exception.

## Cuprite

https://github.com/rubycdp/cuprite — reviewed 2026-11-24; release v0.20 (gem 0.20.1), main `91fd6fa8ba` (requires the released Ferrum ~> 0.21.0, Cuprite 0.21 unreleased). Open: #376 (device user agent through `network.emulate`; N/A: devices are skipped, Lightpanda refuses Mozilla UAs). Merged since v0.20, converging on ours or N/A: #356 (reset!/quit without a started browser; ours since #208), #360 (ObsoleteNode before the click hit test; ours is immune, the isConnected guard runs inside CLICK_JS's own callFunctionOn, which never hit-tests), #353 (window url/title via `location.href`), #363 (await scrollIntoView/scrollTo; our scroll_to is a no-op), #366 (Ferrum 0.21 dialog chain and closed windows; N/A: LP pre-arm, single window). #373 `browser.html` (ours answers it), #374 `pinpoint` click points (N/A: no coordinate clicks); #367–#370 feed the Ferrum 0.21 candidate above (#369: `trigger("click")` now waits through `await_navigation!(watch:)`; ours sniffs `Browser::SNIFF_WINDOW`).

### Adopted

- `capybara/cuprite/driver.rb#send_keys` ↔ `driver.rb#send_keys`: target the active element; node send_keys focuses without clicking.
- Peer invalid_element_errors/native_args ↔ `driver.rb`: unwrap Capybara nodes and retry only missing-node/context/obsolete-node errors on this JS path.
- Peer Node#[] ↔ `node.rb#PROPERTY_OR_ATTRIBUTE_JS`: resolve URL attributes and live boolean properties.
- Peer all_text ↔ `node.rb#filter_text`: normalize controls, whitespace and NBSP for Capybara matching.
- Peer shadow_root/parents ↔ `node.rb`, `browser/finder.rb#parents_of`: Node wrappers, excluding ownerDocument from ancestors.
- Peer time inputs ↔ `node.rb#fill_input`: month %Y-%m and ISO week %G-W%V; calendar year is wrong around New Year.
- Peer default_domain ↔ `driver.rb#default_domain`: current host, app_host, then loopback; @started permits cookie setup before first visit.
- Peer trigger ↔ `node.rb#TRIGGER_JS`: constructor appropriate to mouse/focus/input; unknown custom names still dispatch a generic Event.
- Peer invalid selector mapping ↔ `browser/finder.rb`: LIGHTPANDA_INVALID_SELECTOR marker wraps CSS parse errors, since Lightpanda may throw generic Error rather than DOMException.
- Peer unhandled modal option ↔ `browser/modals.rb#check_unhandled_modal!`: accept and defer the error to the caller thread; LP pre-arm bookkeeping is single-shot.
- Peer node attachment check ↔ `node.rb#wrap_with_attached_guard`: fold isConnected into the operation's own callFunctionOn, avoiding a check/use race and extra round-trip.
- Peer page extension setup ↔ `browser.rb#register_auto_scripts`: register for future documents AND evaluate into the initial blank page; the idempotency guard permits both.
- Peer HTML5 drag script ↔ `node.rb#HTML5_DRAG_JS`: drop only when accepted, otherwise dragleave; never both. Coordinate fallback is unsupported. Keep the port's corrected rect/key variables.
- Peer registration and driver API ↔ `cuprite_driver.rb` (`Capybara::Lightpanda.register_cuprite_driver`): keeps the app's driver name, rejects before launch what Lightpanda can't honor (HTTP `url:`, non-`ws://` `ws_url`, headed mode, unknown options), and `visit` raises Ferrum's `StatusError` (ours without Ferrum) on a refused navigation. `network_traffic(:blocked)` raises rather than returning empty. Per-area boundaries: `CUPRITE_COMPATIBILITY.md`; shared examples: `test/compatibility/{cuprite,selenium}_contract.rb`.
- Peer driver.rb#evaluate_async_script + Ferrum ScriptTimeoutError ↔ `driver.rb#evaluate_async_script`, `browser/runtime.rb#evaluate_async`: the Capybara session wait bounds the callback; a miss raises ScriptTimeoutError, transport and JavaScript errors keep their types.
- Peer click modifiers ↔ `node.rb#mouse_event_options`: Shift/Control/Alt/Meta reach mouse handlers.

### Outstanding adoption candidates

- **[tiny]** Peer javascripts/index.js#setValue native HTMLInputElement setter ↔ node.rb#SET_VALUE_JS: bypass framework value interception only when a real-app regression motivates it.
- **[medium]** Peer driver.rb `url_blocklist`/`url_allowlist` options (#361, legacy `url_blacklist`/`url_whitelist`) ↔ options.rb/browser.rb: the gem has neither, and `register_cuprite_driver` rejects them before launch. Lightpanda's `Network.setBlockedURLs` takes only `urlPatterns: [{urlPattern, block}]` and sets browser-wide state that context disposal keeps, so a blocklist must be cleared in `reset!`; an allowlist needs Fetch interception. From Cuprite #375 string patterns raise ArgumentError (Regexp only).

### Diverged on purpose

- Peer set types characters ↔ `node.rb#SET_VALUE_JS`: direct value plus input/change is faster and more robust here, with one synthetic keydown/keyup pair around it so keyup-bound filters run (beta feedback 2026-11-18); use send_keys for per-keystroke handlers.
- Peer finder hints (#347, merged 2026-11-19: `finder/hints.rb` answers visibility, texts, styles and position in one evaluate and pins them as a snapshot, as Selenium does) ↔ `driver.rb`/`node.rb`/`predicates.js#findHints`: ours caches immutable tag names only and keeps mutable hints live, because Capybara filters a lazy Result after it returns; text filtering stops at 512 candidates and keeps the first 10 when none holds the text so Capybara keeps its failure message. Contract: `.codex/rules/finder-hints.md`.
- Peer coordinate clicks ↔ `node.rb#CLICK_JS`: same constraint as Ferrum; no real layout/mouse fallback.
- Peer iframe-offset obscuration ↔ `javascripts/predicates.js`: owning-document hit tests descend outer shadow roots first; feature-detect ShadowRoot.elementFromPoint and keep the older-browser host fallback.
- Peer visibility walker ↔ native checkVisibility: native handles stylesheet/UA cascade more accurately here. Opacity zero remains visible unless a real app requires an explicit check.
- Peer visibleText walker ↔ native innerText behind an isVisible gate: hidden innerText falls back to textContent, so keep the gate; fragments need visible-child concatenation.
- Peer JS bundle ↔ `javascripts/{turbo,predicates,attach}.js` + auto_scripts.rb: classic scripts linked into an idempotent IIFE, without module syntax/build tooling.
- Peer drop ↔ `node.rb#attach_drop_input`/DROP_JS: same disk-file transport, but ours attaches in the dropzone's document (iframe-safe) and fires dragenter/dragover/drop; preserve both differences.
- Peer XPath handling ↔ `browser/finder.rb#XPATH_FIND_FRAGMENT`: parse errors return [] so Capybara can retry without its empty exact-text hint; invalid XPath consequently matches nothing instead of raising InvalidSelector. capybara#2860 remains watched.
