# frozen_string_literal: true

require_relative "../test_helper"

# Probe-style spec : exerce les 4 grandes surfaces d'API dont Turbo Drive,
# Turbo Streams et Stimulus dépendent. Chaque test isole une famille
# d'API en pure CDP/JS — pas de Capybara magic, pas de Stimulus, pas de
# Turbo. L'objectif est d'avoir un signal clair "Lightpanda implémente
# correctement cette famille" plutôt qu'un bug spécifique.
#
# Quand un test échoue, c'est un candidat à filer en upstream wishlist (A/B).
# rubocop:disable Layout/LineLength -- inline JS payloads stay legible only un-wrapped
describe "Lightpanda Hotwire-zone probes" do
  let(:session) { TestSessions::Lightpanda }
  let(:driver) { session.driver }

  after { session.reset_session! }

  # ───────────────────────────────────────────────
  # Zone 0 — Async event-loop sanity check.
  # If THIS fails, every other "X callback never fires" failure is a
  # symptom of a broken task scheduling, not a bug in X.
  # ───────────────────────────────────────────────

  describe "Zone 0 — async event-loop sanity" do
    before { session.visit("/lightpanda/probe/page") }

    it "setTimeout(fn, 50) fires inside evaluate_async_script" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        setTimeout(function() { done('fired'); }, 50);
      JS
      assert_equal "fired", result, "setTimeout fires fast — if not, the whole event loop is stalled"
    end

    it "Promise.resolve().then() resolves microtask" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        Promise.resolve('via-microtask').then(function(v) { done(v); });
      JS
      assert_equal "via-microtask", result,
                   "Promise microtask never drained — the JS event loop is broken at the source"
    end

    it "queueMicrotask drains the microtask queue" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        if (typeof queueMicrotask !== 'function') { done('queueMicrotask undefined'); return; }
        queueMicrotask(function() { done('drained'); });
      JS
      assert_equal "drained", result
    end

    it "setTimeout side-effect is observable via polling (sync evaluate_script)" do
      # Fire-and-forget : arm a setTimeout that mutates a global, then poll for it.
      session.execute_script("window.__timer_fired = false; setTimeout(function() { window.__timer_fired = true; }, 50);")
      sleep 0.3
      observed = session.evaluate_script("window.__timer_fired")
      assert_equal true, observed, "setTimeout(50) never mutated window.__timer_fired even after 300ms"
    end

    it "Promise.resolve side-effect is observable via polling" do
      session.execute_script("window.__promise_fired = false; Promise.resolve().then(function() { window.__promise_fired = true; });")
      sleep 0.3
      observed = session.evaluate_script("window.__promise_fired")
      assert_equal true, observed, "Promise.resolve().then never ran the microtask"
    end
  end

  # ───────────────────────────────────────────────
  # Zone 1 — fetch / FormData / Promise round-trip
  # Required by: Turbo Drive (every form submit), Turbo Frame (every nav).
  # ───────────────────────────────────────────────

  describe "Zone 1 — fetch + FormData round-trip" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes window.fetch as a function" do
      assert_equal "function", session.evaluate_script("typeof window.fetch")
    end

    it "exposes FormData / Headers / Request / Response constructors" do
      ctors = session.evaluate_script(<<~JS)
        ({
          FormData: typeof FormData,
          Headers:  typeof Headers,
          Request:  typeof Request,
          Response: typeof Response,
          URLSearchParams: typeof URLSearchParams,
        })
      JS
      %w[FormData Headers Request Response URLSearchParams].each do |ctor|
        assert_equal "function", ctors[ctor], "#{ctor} should be a function, got #{ctors[ctor].inspect}"
      end
    end

    it "performs a JSON-body POST and resolves response.json()" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        fetch('/lightpanda/probe/echo', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'name=Alice&role=admin',
        })
          .then(function(r) { return r.json(); })
          .then(function(j) { done({ ok: true, json: j }); })
          .catch(function(e) { done({ ok: false, err: String(e) }); });
      JS

      assert_equal true, result["ok"], "fetch chain failed: #{result.inspect}"
      assert_equal "POST", result.dig("json", "method")
      assert_equal "Alice", result.dig("json", "params", "name")
      assert_equal "admin", result.dig("json", "params", "role")
    end

    it "actually sends the HTTP request to the server (independent of Promise resolution)" do
      # Reset server counter
      session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var x = new XMLHttpRequest();
        x.onload = function() { done('reset'); };
        x.onerror = function() { done('error'); };
        x.open('POST', '/lightpanda/probe/reset_hits', true);
        x.send();
        setTimeout(function() { done('xhr_timeout'); }, 1500);
      JS

      # Fire fetch, ignore the result (Promise may never resolve).
      session.execute_script(<<~JS)
        fetch('/lightpanda/probe/hit', { method: 'POST', body: 'ping=1' });
      JS

      # Poll the side-channel.
      sleep 0.5
      response = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var x = new XMLHttpRequest();
        x.onload = function() { done(JSON.parse(x.responseText)); };
        x.onerror = function() { done({ error: 'xhr_failed' }); };
        x.open('GET', '/lightpanda/probe/hit_count', true);
        x.send();
        setTimeout(function() { done({ error: 'xhr_timeout' }); }, 1500);
      JS

      assert_equal 1, response["hits"],
                   "fetch() should land at server even if Promise never resolves; got #{response.inspect} " \
                   "— if hits=0 the fetch HTTP request was never sent"
    end

    it "POSTs a URLSearchParams body that the server can parse" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var qs = new URLSearchParams();
        qs.append('name', 'Carol');
        qs.append('count', '7');
        fetch('/lightpanda/probe/echo', { method: 'POST', body: qs })
          .then(function(r) { return r.json(); })
          .then(function(j) { done({ ok: true, json: j }); })
          .catch(function(e) { done({ ok: false, err: String(e) }); });
      JS

      assert_equal true, result["ok"], "URLSearchParams fetch failed: #{result.inspect}"
      assert_equal "Carol", result.dig("json", "params", "name")
      assert_equal "7", result.dig("json", "params", "count")
    end

    # All 4 tests below assert different facets of Bug #6
    # (`fetch` / XHR coerce FormData via `String()` instead of multipart-encoding).
    # Skipped in CI until upstream lands the multipart encoder; remove the
    # `skip` calls once `MINIMUM_NIGHTLY_BUILD` floor catches the fix.
    # Keep them grouped: passing one but not the others would point at a
    # different (sub-)bug than the one we want fixed.

    it "POSTs a FormData body that the server can parse (Bug #6)" do
      skip "Bug #6 — fetch coerces FormData via String() instead of multipart-encoding"
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var fd = new FormData();
        fd.append('name', 'Bob');
        fd.append('count', '42');
        fetch('/lightpanda/probe/echo', { method: 'POST', body: fd })
          .then(function(r) { return r.json(); })
          .then(function(j) { done({ ok: true, json: j }); })
          .catch(function(e) { done({ ok: false, err: String(e) }); });
      JS

      assert_equal true, result["ok"], "FormData fetch failed: #{result.inspect}"
      assert_equal "Bob", result.dig("json", "params", "name"),
                   "FormData entries should be parseable, got #{result.dig('json', 'params').inspect}"
      assert_equal "42", result.dig("json", "params", "count")
    end

    it "POSTs FormData with the multipart Content-Type (Bug #6 — symptom marker)" do
      skip "Bug #6 — fetch coerces FormData via String() instead of multipart-encoding"
      # Key signature of Bug #6: when fetch sends a FormData body, the
      # Content-Type MUST be `multipart/form-data; boundary=<random>`,
      # not `application/x-www-form-urlencoded`. The wrong content-type
      # is the most lisible "the body coercion fell through to String()"
      # marker — even before checking the body content.
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var fd = new FormData();
        fd.append('k', 'v');
        fetch('/lightpanda/probe/echo', { method: 'POST', body: fd })
          .then(function(r) { return r.json(); })
          .then(function(j) { done({ ok: true, json: j }); })
          .catch(function(e) { done({ ok: false, err: String(e) }); });
      JS

      content_type = result.dig("json", "content_type").to_s
      assert content_type.start_with?("multipart/form-data"),
             "expected multipart/form-data Content-Type, got #{result.dig('json', 'content_type').inspect}"
    end

    it "POSTs FormData built from an existing <form> via `new FormData(form)` (Bug #6 — Turbo path)" do
      skip "Bug #6 — fetch coerces FormData via String() instead of multipart-encoding"
      # This is THE shape Turbo Drive uses on every form submit:
      # `new FormData(form)` extracts the form's inputs into a FormData,
      # then fetches with that body. Identical bug surface to the
      # constructor-then-append case, but worth covering explicitly so
      # that a partial upstream fix that handles only one constructor
      # variant doesn't fool the suite.
      session.execute_script(<<~JS)
        var f = document.createElement('form');
        f.id = 'probe-form';
        f.innerHTML =
          '<input name="name" value="Bob">' +
          '<input name="count" value="42">';
        document.body.appendChild(f);
      JS

      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var fd = new FormData(document.getElementById('probe-form'));
        fetch('/lightpanda/probe/echo', { method: 'POST', body: fd })
          .then(function(r) { return r.json(); })
          .then(function(j) { done({ ok: true, json: j }); })
          .catch(function(e) { done({ ok: false, err: String(e) }); });
      JS

      assert_equal true, result["ok"], "FormData(form) fetch failed: #{result.inspect}"
      assert_equal "Bob", result.dig("json", "params", "name")
      assert_equal "42", result.dig("json", "params", "count")
    end

    it "XHR + FormData also fails the same way (Bug #6 — single root cause)" do
      skip "Bug #6 — XHR coerces FormData via String() instead of multipart-encoding"
      # XHR uses a different code path from fetch for body init. If both
      # fail with the same `[object FormData]` symptom, the upstream fix
      # likely lives at a shared body-coercion site and a single PR
      # covers both. If only fetch fails, the bugs are split and need
      # separate PRs.
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var fd = new FormData();
        fd.append('via', 'xhr');
        var x = new XMLHttpRequest();
        x.open('POST', '/lightpanda/probe/echo', true);
        x.onload = function() {
          try { done({ ok: true, json: JSON.parse(x.responseText) }); }
          catch (e) { done({ ok: false, parseErr: String(e), raw: x.responseText }); }
        };
        x.onerror = function() { done({ ok: false, err: 'xhr-onerror' }); };
        x.send(fd);
      JS

      assert_equal true, result["ok"], "XHR + FormData failed entirely: #{result.inspect}"
      assert_equal "xhr", result.dig("json", "params", "via"),
                   "XHR + FormData entries should be parseable; " \
                   "if this fails the same way as fetch+FormData, " \
                   "the upstream fix is shared between the two paths " \
                   "(common body-init coercion). got=#{result.dig('json', 'params').inspect}"
    end
  end

  # ───────────────────────────────────────────────
  # Zone 2 — <template>.content + DOMParser
  # Required by: Turbo Stream (parses <turbo-stream> with <template> body).
  # ───────────────────────────────────────────────

  describe "Zone 2 — <template> + DOMParser" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes template.content as a DocumentFragment" do
      info = session.evaluate_script(<<~JS)
        (function() {
          var t = document.createElement('template');
          t.innerHTML = '<div id="seed">x</div>';
          return {
            contentType: t.content && t.content.constructor && t.content.constructor.name,
            isFragment:  t.content instanceof DocumentFragment,
            childCount:  t.content && t.content.childNodes ? t.content.childNodes.length : null,
            seenSeed:    t.content && t.content.querySelector ? !!t.content.querySelector('#seed') : null,
          };
        })()
      JS

      assert_equal true, info["isFragment"], "expected template.content to be DocumentFragment, got #{info.inspect}"
      assert_equal true, info["seenSeed"],
                   "querySelector inside template.content should find #seed, got #{info.inspect}"
    end

    it "DOMParser exists and parses an HTML string into a Document with body" do
      info = session.evaluate_script(<<~JS)
        (function() {
          if (typeof DOMParser !== 'function') return { available: false };
          var doc = new DOMParser().parseFromString('<p id="x">hi</p>', 'text/html');
          return {
            available: true,
            docCtor:   doc && doc.constructor && doc.constructor.name,
            bodyHTML:  doc && doc.body && doc.body.innerHTML,
            findP:     doc && doc.getElementById ? !!doc.getElementById('x') : null,
          };
        })()
      JS

      assert_equal true, info["available"], "DOMParser is not exposed"
      assert_match(/id=['"]x['"]/, info["bodyHTML"].to_s,
                   "DOMParser body should contain the parsed node, got #{info.inspect}")
      assert_equal true, info["findP"], "getElementById on parsed doc should find #x"
    end

    it "supports document.adoptNode / importNode for cross-document moves" do
      info = session.evaluate_script(<<~JS)
        (function() {
          var doc = new DOMParser().parseFromString('<p id="seed">hi</p>', 'text/html');
          var seed = doc.getElementById('seed');
          if (!seed) return { error: 'no seed' };
          return {
            adoptNodeFn:  typeof document.adoptNode,
            importNodeFn: typeof document.importNode,
            // Try importNode (non-mutating)
            imported: (function() {
              try {
                var clone = document.importNode(seed, true);
                return { tag: clone && clone.tagName, ownerSame: clone && clone.ownerDocument === document };
              } catch (e) { return { err: String(e) }; }
            })(),
          };
        })()
      JS

      assert_equal "function", info["adoptNodeFn"]
      assert_equal "function", info["importNodeFn"]
      assert_equal "P", info.dig("imported", "tag")
      assert_equal true, info.dig("imported", "ownerSame")
    end
  end

  # ───────────────────────────────────────────────
  # Zone 3 — MutationObserver
  # Required by: Stimulus (detects [data-controller] additions/removals).
  # ───────────────────────────────────────────────

  describe "Zone 3 — MutationObserver" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes MutationObserver as a constructor" do
      assert_equal "function", session.evaluate_script("typeof MutationObserver")
    end

    it "fires childList mutations on subtree changes (async)" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var hits = [];
        var mo = new MutationObserver(function(records) {
          records.forEach(function(r) {
            hits.push({
              type: r.type,
              addedCount: r.addedNodes.length,
              addedTags: Array.prototype.map.call(r.addedNodes, function(n) { return n.tagName }),
            });
          });
          if (hits.length >= 1) {
            mo.disconnect();
            done({ ok: true, hits: hits });
          }
        });
        mo.observe(document.body, { childList: true, subtree: true });
        // Mutate after observer is wired.
        setTimeout(function() {
          var d = document.createElement('div');
          d.id = 'mo-target';
          d.textContent = 'made via MO probe';
          document.body.appendChild(d);
        }, 10);
        // Safety net — if MO never fires, bail out at 1s.
        setTimeout(function() { done({ ok: false, reason: 'MO never fired', hits: hits }); }, 1500);
      JS

      assert_equal true, result["ok"], "MutationObserver did not fire: #{result.inspect}"
      first_hit = result.dig("hits", 0)
      assert_equal "childList", first_hit && first_hit["type"]
      assert_includes (first_hit && first_hit["addedTags"]) || [], "DIV"
    end

    it "supports attributes + characterData filters" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var target = document.getElementById('hello');
        var hits = [];
        var mo = new MutationObserver(function(records) {
          records.forEach(function(r) { hits.push(r.type); });
          if (hits.length >= 2) { mo.disconnect(); done({ ok: true, hits: hits }); }
        });
        mo.observe(target, { attributes: true, characterData: true, subtree: true });
        setTimeout(function() {
          target.setAttribute('data-test', '1');
          target.firstChild.data = 'changed';
        }, 10);
        setTimeout(function() { done({ ok: false, hits: hits }); }, 1500);
      JS

      assert_equal true, result["ok"], "MutationObserver attribute/characterData not firing: #{result.inspect}"
      assert_includes result["hits"], "attributes"
    end
  end

  # ───────────────────────────────────────────────
  # Zone 4 — History API (pushState / replaceState / popstate)
  # Required by: Turbo Drive (SPA-style navigation).
  # ───────────────────────────────────────────────

  describe "Zone 4 — History API" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes history.pushState / replaceState / state" do
      info = session.evaluate_script(<<~JS)
        ({
          push:    typeof history.pushState,
          replace: typeof history.replaceState,
          state:   history.state,
          length:  typeof history.length,
        })
      JS
      assert_equal "function", info["push"]
      assert_equal "function", info["replace"]
      assert_equal "number", info["length"]
    end

    it "pushState updates location.pathname and history.length" do
      result = session.evaluate_script(<<~JS)
        (function() {
          var before = { path: location.pathname, len: history.length };
          history.pushState({ probe: 1 }, '', '/lightpanda/probe/after-push');
          var after = { path: location.pathname, len: history.length, state: history.state };
          return { before: before, after: after };
        })()
      JS

      assert_equal "/lightpanda/probe/after-push", result.dig("after", "path"),
                   "pushState should change location.pathname, got #{result.inspect}"
      assert_equal 1, result.dig("after", "state", "probe")
    end

    it "replaceState updates pathname WITHOUT growing history.length" do
      result = session.evaluate_script(<<~JS)
        (function() {
          var beforeLen = history.length;
          history.replaceState({ replaced: true }, '', '/lightpanda/probe/after-replace');
          return { path: location.pathname, lenDelta: history.length - beforeLen, state: history.state };
        })()
      JS

      assert_equal "/lightpanda/probe/after-replace", result["path"]
      assert_equal 0, result["lenDelta"], "replaceState must not grow history.length, delta=#{result['lenDelta']}"
      assert_equal true, result.dig("state", "replaced")
    end

    it "fires popstate on history.back() after a pushState (async)" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        var fired = null;
        window.addEventListener('popstate', function(e) {
          fired = { state: e.state, path: location.pathname };
          done({ ok: true, fired: fired });
        });
        history.pushState({ step: 'one' }, '', '/lightpanda/probe/step-one');
        setTimeout(function() { history.back(); }, 10);
        setTimeout(function() { if (!fired) done({ ok: false, reason: 'popstate never fired' }); }, 1500);
      JS

      assert_equal true, result["ok"], "popstate did not fire after history.back(): #{result.inspect}"
    end
  end

  # ───────────────────────────────────────────────
  # Zone 5 — document lifecycle events.
  # Turbo's PageObserver reaches pageLoaded() (→ turbo:load) ONLY through
  # `readystatechange`. Lightpanda never fires it natively (wishlist A36);
  # the gem's index.js shim re-dispatches it from DOMContentLoaded / load.
  # These assert the guarantee pages actually see — shim today, native once
  # upstream lands and the shim is dropped.
  # ───────────────────────────────────────────────

  describe "Zone 5 — document lifecycle events" do
    before { session.visit("/lightpanda/probe/lifecycle") }

    it "delivers readystatechange at interactive and complete to page listeners" do
      log = session.evaluate_script("window.__lifecycle_log")
      states = log.filter_map { |entry| entry[/\Areadystatechange:(.+)\z/, 1] }

      assert_includes states, "interactive",
                      "readystatechange(interactive) never reached the page — Turbo's PageObserver stalls at stage=loading: #{log.inspect}"
      assert_includes states, "complete",
                      "readystatechange(complete) never reached the page — turbo:load can't fire: #{log.inspect}"
    end

    it "fires DOMContentLoaded then window load with the matching readyState" do
      log = session.evaluate_script("window.__lifecycle_log")

      assert_includes log, "DOMContentLoaded:interactive", log.inspect
      assert_includes log, "window.load:complete", log.inspect
    end
  end
end
# rubocop:enable Layout/LineLength
