# Ruby CDP Peer Gems

Current design comparisons maintained by sync-upstream. Paths on the gem side are relative to `lib/capybara/lightpanda/`; peer paths are relative to `lib/`. Use symbol names rather than drifting line numbers.

## Ferrum

https://github.com/rubycdp/ferrum — reviewed 2026-11-27; release v0.21.0 (2026-11-24, `58a7628760`), main `af77fc9b3e` (0.22: #728 removes the 0.21 deprecations, #729 raises ArgumentError for bad arguments; N/A with a single page: #733 `new_window:`, #734 `close_target`, #735 `on_page` (ours sets its page up in `browser.rb#create_page`), #736 drops `Target#page=`). Open: #685 (out-of-process iframe idle tracking) only.

0.21 audited, no change needed. Immune by design: one deadline per composite call (#707: `browser/navigation.rb#go_to` shares one, `downloads.rb#wait` sets no latch on timeout, `client/subscriber.rb#unsubscribe` removes by block) and all-nil positional evaluate arguments (`browser/runtime.rb` tests `args.empty?`, not `any?`). Already ours: cookie `http_only`/`same_site` keywords, block-only callbacks (`client/subscriber.rb#dispatch`), `html` beside `body`. The rest is N/A (geometry/coordinate APIs, Fetch interception, several targets, SameParty). The 0.21 names a migrating suite calls are under Cuprite → Adopted. 0.21's `page.cookies` is page-URL-scoped; our `Cookies#all` stays context-wide.

### Adopted

- `ferrum/client.rb` ↔ `client.rb#start_message_thread`, `client/web_socket.rb#start_reader_thread`: connection death releases pending commands; transport exceptions must not abort the host process.
- `ferrum/node.rb#exists?` ↔ `node.rb#exists?`: attached-guard probe returns false only for obsolete/missing nodes or missing context; unrelated errors escape.
- `ferrum/utils/event.rb` ↔ `utils/event.rb`: reset iteration counters expose waits raced by a reset.
- `ferrum/cookies/{cookie.rb,../cookies.rb}` ↔ `cookies.rb`: typed/Enumerable cookies and YAML persistence; native `all` returns an Array, the opt-in Cuprite driver's `cuprite_cookies.rb#all` the name-keyed Hash.
- `ferrum/node.rb#wait_for_stop_moving` ↔ `node.rb`: consecutive rect samples; our timeout behavior deliberately differs below.
- `ferrum/network.rb` ↔ `network.rb`: traffic, idle and headers; close redirectResponse hops and loadingFailed entries to avoid stranded pending requests. Only wait_for_idle! raises.
- `ferrum/network/exchange.rb` ↔ `network/exchange.rb`: Exchange/Response answer `request.url`, `response.status`, `finished?`, but subclass Hash so symbol-key traffic assertions keep working.
- `ferrum/headers.rb` ↔ `request_headers.rb`: get/set/add/clear; `add(permanent: false)` keeps a Referer off subrequests and sends it with `Page.navigate` only, as Ferrum 0.20 does; 0.21 replaced it with `go_to(referrer:)`, and both work here. Session reset clears overrides.
- Ferrum `Page#wait_for_reload` ↔ `browser/navigation.rb#wait_for_reload`: returns on a main-frame load, a same-document navigation or expiry, truthy either way.
- `ferrum/contexts.rb#reset` ↔ `browser.rb#reset`, `driver.rb#reset!`: context disposal isolates sessions; Network#reset must forget the disposed domain's enabled state. Failed reset discards the browser.
- `ferrum/utils/attempt.rb` ↔ `utils/attempt.rb`: bounded retry with the peer's 6 × 0.1 s defaults, which no caller uses: `browser.rb#with_default_context_wait` passes 3 tries with no sleep (it waits on executionContextCreated instead), `client/web_socket.rb#connect_with_retry` 10 × 0.1 s on a refused TCP connect.
- `ferrum/errors.rb` ↔ `errors.rb`: CDP error hierarchy, response/code/data and JavaScript stack formatting; compat-only classes remain valid rescue constants.
- Ferrum callback dispatch ↔ `client/subscriber.rb#dispatch`: per-callback rescue prevents one handler from blocking others.
- Ferrum #730 newline as Enter ↔ `keyboard.rb#char_definition`: a typed `"\n"` is the Enter key, so `send_keys("query\n")` runs Enter handlers and submits the form, as with chromedriver.
- `ferrum/frame/runtime.rb` ↔ `browser/runtime.rb`: evaluate awaits promises, execute discards values, evaluate_async supplies Capybara's callback. Ferrum's named-argument API differs; keep Capybara positional arguments here.
- `ferrum/downloads.rb` ↔ `downloads.rb`: browser-level events and blocking wait; ours needs begin-grace because click may return before downloadWillBegin is processed. The block form (`wait { click }`) records the baseline before yielding and gives the download the full timeout to start.
- Ferrum Process::Output ↔ `process.rb#output`, `browser/navigation.rb#crash_output`: retain bounded startup/runtime output for crash diagnosis.
- Ferrum WebSocket#force_close ↔ `client/web_socket.rb#close_socket`: release the socket even when the connection is already dead.
- Ferrum bounded write ↔ `client/web_socket.rb#write`: nonblocking send with a no-progress timeout; a stalled browser must not freeze caller and close under the driver mutex.
- `ferrum/cookies.rb#set` (≤ 0.20) ↔ `cookies.rb#set`: return the browser's success verdict rather than claiming every cookie was accepted. Ferrum 0.21 returns nil and raises on a refusal (`Storage.setCookies`); ours keeps the verdict, so a caller testing truthiness still works.
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

https://github.com/rubycdp/cuprite — reviewed 2026-11-27; release v0.21 (2026-11-25, `cae4281068`, requires Ferrum ~> 0.21.0), main `a89d117386` (0.22-dev, builds against Ferrum main). No open PRs. Unreleased main: #396 removes the 0.21 deprecations; #399 makes `driver.browser` a plain Ferrum browser, adds `driver.current_page` for the switched-to window (ours has none), moves the URL lists and `raise_on_unhandled_modal=` to the driver, and restarts a dead browser in `reset!`; #397/#398 (Ferrum public API only, N/A).

0.21 audited, converging on ours or N/A. Immune by design: ObsoleteNode before a click hit test (#360: CLICK_JS's isConnected guard runs in its own callFunctionOn, which never hit-tests), refocusing after a `\n` submit (#382: `node.rb#fill_text_input` never refocuses), optgroup options in a multiple select's value (#387: value JS reads `selectedOptions`). Already ours: reset!/quit without a started browser, window url/title, `browser.html`, case-insensitive `response_headers`, `Node#style`, a navigation sniff after `trigger("click")` (`Browser::SNIFF_WINDOW`). The rest is N/A (dialog chains, several windows, coordinate clicks, Mozilla device UAs, awaited scroll). Real key typing is under Diverged `set`; the Ferrum 0.21 names under Adopted.

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
- Peer `Node#set` Array guard (#389) ↔ `node.rb#set`: an Array for a field without `multiple` raises Selenium's ArgumentError instead of typing its inspect string; `multiple?` is read only for an Array.
- Peer `Node#set(clear:)` (#378, Selenium's `set_text`) ↔ `node.rb#write_text`: `:none` appends, an Array of keys is typed before the value, `:backspace` writes like nil (same end value), any other value raises; `rapid:` is accepted silently (we never type), other options warn. Pinned by `selenium_contract.rb`.
- Ferrum 0.21 names (#716/#717, `5743cc85dc`, `4702d99a79`) as Cuprite 0.21's docs show them ↔ `browser/navigation.rb#go_to(referrer:)`/`#await_navigation(!)`/`#await_download(!)`, `network.rb#emulate`/`#wait_idle(!)`, `downloads.rb#await_download(!)`: a suite written for 0.21 runs unchanged; the 0.20 names stay. `await_download` returns a path, not Ferrum's hash; `emulate` resends the navigator defaults because Lightpanda keeps an empty userAgent literally; bang navigations and `wait_until` are not provided. Ferrum's go_to Referer-resend fix doesn't transfer: `RequestHeaders#set` already resets `@referrer`.

### Outstanding adoption candidates

- **[tiny]** Peer javascripts/index.js#setValue native HTMLInputElement setter ↔ node.rb#SET_VALUE_JS: bypass framework value interception only when a real-app regression motivates it.
- **[medium]** Peer driver.rb `url_blocklist`/`url_allowlist` options (#361, legacy `url_blacklist`/`url_whitelist`) ↔ options.rb/browser.rb: the gem has neither, and `register_cuprite_driver` rejects them before launch. Lightpanda's `Network.setBlockedURLs` takes only `urlPatterns: [{urlPattern, block}]` and sets browser-wide state that context disposal keeps, so a blocklist must be cleared in `reset!`; an allowlist needs Fetch interception. Cuprite 0.21: string patterns raise ArgumentError (Regexp only, #375), both lists together raise ArgumentError, and an empty blocklist unblocks the current page (#393).
- **[tiny]** Peer `page/modals.rb#find_modal` on a `Thread::Queue` (#394) ↔ `browser/modals.rb#find_modal`: ours polls `@modal_messages` every 50 ms; a ConditionVariable signalled from the `Page.javascriptDialogOpening` handler claims the dialog on arrival. Keep the text-mismatch skip and `disarm_modal` on timeout.

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
