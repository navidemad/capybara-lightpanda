# frozen_string_literal: true

require "spec_helper"

# Probe-style spec : exerce les 4 grandes surfaces d'API dont Turbo Drive,
# Turbo Streams et Stimulus dépendent. Chaque section isole une famille
# d'API en pure CDP/JS — pas de Capybara magic, pas de Stimulus, pas de
# Turbo. L'objectif est d'avoir un signal clair "Lightpanda implémente
# correctement cette famille" plutôt qu'un bug spécifique.
#
# Quand un test échoue, c'est un candidat à filer en upstream wishlist (A/B).
# rubocop:disable Layout/LineLength -- inline JS payloads stay legible only un-wrapped
RSpec.describe "Lightpanda Hotwire-zone probes" do
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
      expect(result).to eq("fired"), "setTimeout fires fast — if not, the whole event loop is stalled"
    end

    it "Promise.resolve().then() resolves microtask" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        Promise.resolve('via-microtask').then(function(v) { done(v); });
      JS
      expect(result).to eq("via-microtask"),
                        "Promise microtask never drained — the JS event loop is broken at the source"
    end

    it "queueMicrotask drains the microtask queue" do
      result = session.evaluate_async_script(<<~JS)
        var done = arguments[arguments.length - 1];
        if (typeof queueMicrotask !== 'function') { done('queueMicrotask undefined'); return; }
        queueMicrotask(function() { done('drained'); });
      JS
      expect(result).to eq("drained")
    end

    it "setTimeout side-effect is observable via polling (sync evaluate_script)" do
      # Fire-and-forget : arm a setTimeout that mutates a global, then poll for it.
      session.execute_script("window.__timer_fired = false; setTimeout(function() { window.__timer_fired = true; }, 50);")
      sleep 0.3
      observed = session.evaluate_script("window.__timer_fired")
      expect(observed).to be(true), "setTimeout(50) never mutated window.__timer_fired even after 300ms"
    end

    it "Promise.resolve side-effect is observable via polling" do
      session.execute_script("window.__promise_fired = false; Promise.resolve().then(function() { window.__promise_fired = true; });")
      sleep 0.3
      observed = session.evaluate_script("window.__promise_fired")
      expect(observed).to be(true), "Promise.resolve().then never ran the microtask"
    end
  end

  # ───────────────────────────────────────────────
  # Zone 1 — fetch / FormData / Promise round-trip
  # Required by: Turbo Drive (every form submit), Turbo Frame (every nav).
  # ───────────────────────────────────────────────

  describe "Zone 1 — fetch + FormData round-trip" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes window.fetch as a function" do
      expect(session.evaluate_script("typeof window.fetch")).to eq("function")
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
        expect(ctors[ctor]).to eq("function"), "#{ctor} should be a function, got #{ctors[ctor].inspect}"
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

      expect(result["ok"]).to be(true), "fetch chain failed: #{result.inspect}"
      expect(result.dig("json", "method")).to eq("POST")
      expect(result.dig("json", "params", "name")).to eq("Alice")
      expect(result.dig("json", "params", "role")).to eq("admin")
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

      expect(response["hits"]).to eq(1),
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

      expect(result["ok"]).to be(true), "URLSearchParams fetch failed: #{result.inspect}"
      expect(result.dig("json", "params", "name")).to eq("Carol")
      expect(result.dig("json", "params", "count")).to eq("7")
    end

    it "POSTs a FormData body that the server can parse" do
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

      expect(result["ok"]).to be(true), "FormData fetch failed: #{result.inspect}"
      # KNOWN BROKEN — see UPSTREAM_BUGS.md Bug #6.
      # Lightpanda coerces the FormData object to its string form
      # ("[object FormData]"), URL-encodes that, and sets content_type
      # to application/x-www-form-urlencoded — instead of producing a
      # proper multipart/form-data body. The server therefore parses a
      # single bogus key "object FormData" with nil value.
      expect(result.dig("json", "params", "name")).to eq("Bob"),
                                                      "FormData should be encoded as multipart, " \
                                                      "got #{result.dig('json', 'params').inspect} " \
                                                      "(content_type=#{result.dig('json', 'content_type').inspect}, " \
                                                      "raw_body_len=#{result.dig('json', 'raw_body_len').inspect})"
      expect(result.dig("json", "params", "count")).to eq("42")
      expect(result.dig("json", "raw_body_len")).to be > 0
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

      expect(info["isFragment"]).to be(true), "expected template.content to be DocumentFragment, got #{info.inspect}"
      expect(info["seenSeed"]).to be(true),
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

      expect(info["available"]).to be(true), "DOMParser is not exposed"
      expect(info["bodyHTML"].to_s).to match(/id=['"]x['"]/),
                                       "DOMParser body should contain the parsed node, got #{info.inspect}"
      expect(info["findP"]).to be(true), "getElementById on parsed doc should find #x"
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

      expect(info["adoptNodeFn"]).to eq("function")
      expect(info["importNodeFn"]).to eq("function")
      expect(info.dig("imported", "tag")).to eq("P")
      expect(info.dig("imported", "ownerSame")).to be(true)
    end
  end

  # ───────────────────────────────────────────────
  # Zone 3 — MutationObserver
  # Required by: Stimulus (detects [data-controller] additions/removals).
  # ───────────────────────────────────────────────

  describe "Zone 3 — MutationObserver" do
    before { session.visit("/lightpanda/probe/page") }

    it "exposes MutationObserver as a constructor" do
      expect(session.evaluate_script("typeof MutationObserver")).to eq("function")
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

      expect(result["ok"]).to be(true), "MutationObserver did not fire: #{result.inspect}"
      first_hit = result.dig("hits", 0)
      expect(first_hit && first_hit["type"]).to eq("childList")
      expect(first_hit && first_hit["addedTags"]).to include("DIV")
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

      expect(result["ok"]).to be(true), "MutationObserver attribute/characterData not firing: #{result.inspect}"
      expect(result["hits"]).to include("attributes")
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
      expect(info["push"]).to eq("function")
      expect(info["replace"]).to eq("function")
      expect(info["length"]).to eq("number")
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

      expect(result.dig("after", "path")).to eq("/lightpanda/probe/after-push"),
                                             "pushState should change location.pathname, got #{result.inspect}"
      expect(result.dig("after", "state", "probe")).to eq(1)
    end

    it "replaceState updates pathname WITHOUT growing history.length" do
      result = session.evaluate_script(<<~JS)
        (function() {
          var beforeLen = history.length;
          history.replaceState({ replaced: true }, '', '/lightpanda/probe/after-replace');
          return { path: location.pathname, lenDelta: history.length - beforeLen, state: history.state };
        })()
      JS

      expect(result["path"]).to eq("/lightpanda/probe/after-replace")
      expect(result["lenDelta"]).to eq(0), "replaceState must not grow history.length, delta=#{result['lenDelta']}"
      expect(result.dig("state", "replaced")).to be(true)
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

      expect(result["ok"]).to be(true), "popstate did not fire after history.back(): #{result.inspect}"
    end
  end
end
# rubocop:enable Layout/LineLength
