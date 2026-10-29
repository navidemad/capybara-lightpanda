# Ruby CDP Peer Gems

Current design comparisons maintained by sync-upstream. Paths on the gem side are relative to `lib/capybara/lightpanda/`; peer paths are relative to `lib/`. Use symbol names rather than drifting line numbers.

## Ferrum

https://github.com/rubycdp/ferrum — reviewed 2026-10-29; release v0.20.0, main `3bae1680`. Open #674 (click wait), #685 (out-of-process iframe idle tracking).

### Adopted

- `ferrum/client.rb` ↔ `client.rb#start_message_thread`, `client/web_socket.rb#start_reader_thread`: connection death releases pending commands; transport exceptions must not abort the host process.
- `ferrum/node.rb#exists?` ↔ `node.rb#exists?`: attached-guard probe returns false only for obsolete/missing nodes or missing context; unrelated errors escape.
- `ferrum/utils/event.rb` ↔ `utils/event.rb`: reset iteration counters expose waits raced by a reset.
- `ferrum/cookies/{cookie.rb,../cookies.rb}` ↔ `cookies.rb`: typed/Enumerable cookies and YAML persistence; ours returns an Array rather than a name-keyed Hash.
- `ferrum/node.rb#wait_for_stop_moving` ↔ `node.rb`: consecutive rect samples; our timeout behavior deliberately differs below.
- `ferrum/network.rb` ↔ `network.rb`: traffic, idle and headers; close redirectResponse hops and loadingFailed entries to avoid stranded pending requests. Only wait_for_idle! raises.
- `ferrum/contexts.rb#reset` ↔ `browser.rb#reset`, `driver.rb#reset!`: context disposal isolates sessions; Network#reset must forget the disposed domain's enabled state. Failed reset discards the browser.
- `ferrum/utils/attempt.rb` ↔ `utils/attempt.rb`: bounded retry reused by with_default_context_wait; six attempts at 0.1 s, matching the peer defaults.
- `ferrum/errors.rb` ↔ `errors.rb`: CDP error hierarchy, response/code/data and JavaScript stack formatting; compat-only classes remain valid rescue constants.
- Ferrum callback dispatch ↔ `client/subscriber.rb#dispatch`: per-callback rescue prevents one handler from blocking others.
- `ferrum/frame/runtime.rb` ↔ `browser/runtime.rb`: evaluate awaits promises, execute discards values, evaluate_async supplies Capybara's callback. Ferrum's named-argument API differs; keep Capybara positional arguments here.
- `ferrum/downloads.rb` ↔ `downloads.rb`: browser-level events and blocking wait; ours needs begin-grace because click may return before downloadWillBegin is processed.
- Ferrum Process::Output ↔ `process.rb#output`, `browser/navigation.rb#crash_output`: retain bounded startup/runtime output for crash diagnosis.
- Ferrum WebSocket#force_close ↔ `client/web_socket.rb#close_socket`: release the socket even when the connection is already dead.
- Ferrum bounded write ↔ `client/web_socket.rb#write`: nonblocking send with a no-progress timeout; a stalled browser must not freeze caller and close under the driver mutex.
- `ferrum/cookies.rb#set` ↔ `cookies.rb#set`: preserve the browser's success verdict rather than claiming every cookie was accepted.
- Ferrum CyclicObject ↔ `browser/runtime.rb#serialize_remote_object`: ours replaces the whole refused value; Ferrum's deep serializer can preserve everything but the back-reference.
- Ferrum lone-surrogate recovery ↔ `client/web_socket.rb#parse_message`: replace unpaired UTF-16 escapes with U+FFFD only after JSON parse failure, so the response is delivered rather than lost.
- Ferrum cross-world error mapping ↔ `client.rb#handle_error`: stale argument handles map to NodeNotFoundError, allowing Capybara reload.

### Transport constraints

- `client.rb#next_command_id` locks ids; WebSocket text/close/parse share @driver_mutex. The handshake parse precedes the reader thread. This avoids the two races described by Ferrum #602.
- JRuby audit (2026-10-26): script/audit_websocket.rb passed an idle reader plus 100 messages from four senders with pings on MRI 4.0.9/JRuby 10.1.2.0 + websocket-driver 0.8.1. Removing the reader-readiness guard hung past 15 s. Ferrum #680's merged writer queue is not a reason to remove that guard; this is a bounded probe, not universal JRuby safety.
- `client.rb#command` starts response waiting after send; a controlled 100 ms send succeeded after 105 ms with timeout 0.01. Write timeout bounds no-progress, not total duration; mutex wait is outside it. An absolute deadline needs a policy for queued/partly written frames and connection health before implementation.

### Outstanding adoption candidates

- **[tiny]** `ferrum/network/exchange.rb` ↔ `network.rb#traffic`: typed request/response/finished predicates could replace loose hashes if callers need richer diagnostics; not currently adopted.
- **[medium]** Ferrum Frame lifecycle events ↔ Network idle/Turbo tracking: Lightpanda exposes lifecycle events, but adopt another signal only after a real-app failure demonstrates a gap.

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

https://github.com/rubycdp/cuprite — reviewed 2026-10-29; release v0.19, main `a9cc52c7`. Open #347 (finder hints); #350's new Ferrum JavaScript API is merged.

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
- Capybara finder hints ↔ `driver.rb`/`node.rb`: cache immutable tag names only, keep mutable hints live; text filtering stops at 512 candidates and retains Unicode conservatively. Contract: `.codex/rules/finder-hints.md`; peer #347 remains unmerged.
- Peer HTML5 drag script ↔ `node.rb#HTML5_DRAG_JS`: drop only when accepted, otherwise dragleave; never both. Coordinate fallback is unsupported. Keep the port's corrected rect/key variables.

### Outstanding adoption candidates

- **[tiny]** Peer javascripts/index.js#setValue native HTMLInputElement setter ↔ node.rb#SET_VALUE_JS: bypass framework value interception only when a real-app regression motivates it.
- **[medium]** Peer driver.rb#evaluate_async_script + Ferrum ScriptTimeoutError ↔ driver.rb/browser/runtime.rb: pass Capybara session wait and distinguish script timeout. Ours uses the driver timeout for both page timer and CDP wait, so a missing callback can surface as a command timeout (verified 2026-10-23).

### Diverged on purpose

- Peer set types characters ↔ `node.rb#SET_VALUE_JS`: direct value plus input/change is faster and more robust here; use send_keys for keystroke handlers.
- Peer coordinate clicks ↔ `node.rb#CLICK_JS`: same constraint as Ferrum; no real layout/mouse fallback.
- Peer iframe-offset obscuration ↔ `javascripts/predicates.js`: owning-document hit tests descend outer shadow roots first; feature-detect ShadowRoot.elementFromPoint and keep the older-browser host fallback.
- Peer visibility walker ↔ native checkVisibility: native handles stylesheet/UA cascade more accurately here. Opacity zero remains visible unless a real app requires an explicit check.
- Peer visibleText walker ↔ native innerText behind an isVisible gate: hidden innerText falls back to textContent, so keep the gate; fragments need visible-child concatenation.
- Peer JS bundle ↔ `javascripts/{turbo,predicates,attach}.js` + auto_scripts.rb: classic scripts linked into an idempotent IIFE, without module syntax/build tooling.
- Peer drop ↔ `node.rb#attach_drop_input`/DROP_JS: same disk-file transport, but ours attaches in the dropzone's document (iframe-safe) and fires dragenter/dragover/drop; preserve both differences.
- Peer XPath handling ↔ `browser/finder.rb#XPATH_FIND_FRAGMENT`: parse errors return [] so Capybara can retry without its empty exact-text hint; invalid XPath consequently matches nothing instead of raising InvalidSelector. capybara#2860 remains watched.
