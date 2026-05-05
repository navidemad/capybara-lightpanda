# frozen_string_literal: true

require_relative "../test_helper"

# Tests d'intégration ciblés sur les bugs upstream du binaire Lightpanda
# documentés dans UPSTREAM_BUGS.md. Chaque exemple exerce le scénario qui
# crashe nativement, puis vérifie que le workaround côté gem (CLICK_JS,
# polyfills.js) le fait passer.
#
# Si une PR upstream supprime un workaround, ces tests doivent rester verts
# sur le binaire patché — ils décrivent le contrat fonctionnel attendu, pas
# l'implémentation du contournement.
describe "Upstream Lightpanda bug repros & workarounds" do
  let(:session) { TestSessions::Lightpanda }
  let(:driver) { session.driver }
  let(:browser) { driver.browser }

  after { session.reset_session! }

  # ───────────────────────────────────────────────
  # Bug #3 — Element.dispatchEvent crashes during the bubble phase.
  # Workaround: polyfills.js monkey-patches dispatchEvent to fall back to
  # manual ancestor propagation when the native bubble throws.
  # ───────────────────────────────────────────────

  describe "Bug #3 — synthetic clicks must bubble to document" do
    it "delivers a bubbling click to a document-level delegated handler" do
      session.visit("/lightpanda/upstream/event_delegation")
      session.find(:css, "#leaf-btn").click

      hits = session.evaluate_script("window.__hits")
      phases = hits.map { |h| h["phase"] }
      msg = "expected click to bubble through body+document, got: #{hits.inspect}"
      assert_includes phases, "body", msg
      assert_includes phases, "doc", msg
    end

    it "preserves event.target as the original element on each ancestor" do
      session.visit("/lightpanda/upstream/event_delegation")
      session.find(:css, "#leaf-btn").click

      hits = session.evaluate_script("window.__hits")
      targets = hits.map { |h| h["target"] }.uniq
      assert_equal ["leaf-btn"], targets, "delegated handlers must receive the original target"
    end

    it "invokes the document handler even when the local handler throws" do
      session.visit("/lightpanda/upstream/event_delegation")
      session.execute_script(<<~JS)
        document.getElementById('leaf-btn').addEventListener('click', function() {
          throw new Error('local handler boom');
        });
      JS

      session.find(:css, "#leaf-btn").click
      hits = session.evaluate_script("window.__hits")
      assert_includes hits.map { |h| h["phase"] }, "doc"
    end
  end

  # ───────────────────────────────────────────────
  # Bug #4 — HTMLDialogElement.{showModal, show, close} unimplemented.
  # Workaround: polyfills.js adds prototype methods that toggle [open]
  # and dispatch the 'close' event.
  # ───────────────────────────────────────────────

  describe "Bug #4 — HTMLDialogElement polyfill" do
    it "opens the dialog via showModal() and exposes the [open] attribute" do
      session.visit("/lightpanda/upstream/dialog")

      session.assert_no_selector(:css, "dialog#d[open]")
      session.find(:css, "#open-modal").click
      session.assert_selector(:css, "dialog#d[open]")
    end

    it "opens the dialog via show() (non-modal)" do
      session.visit("/lightpanda/upstream/dialog")
      session.find(:css, "#open-show").click
      session.assert_selector(:css, "dialog#d[open]")
    end

    it "close() removes [open] and dispatches a 'close' event with returnValue" do
      session.visit("/lightpanda/upstream/dialog")
      session.find(:css, "#open-modal").click
      session.find(:css, "#dialog-close").click

      session.assert_no_selector(:css, "dialog#d[open]")
      events = session.evaluate_script("window.__closeEvents")
      assert_equal ["done"], events, "expected the polyfilled close() to dispatch a 'close' event"
    end

    it "showModal on an already-open dialog throws InvalidStateError per spec" do
      session.visit("/lightpanda/upstream/dialog")
      session.find(:css, "#open-modal").click
      threw = session.evaluate_script(<<~JS)
        (function() {
          try { document.getElementById('d').showModal(); return null; }
          catch (e) { return String(e); }
        })();
      JS
      assert_match(/InvalidStateError|already.+open/i, threw)
    end
  end

  # ───────────────────────────────────────────────
  # Bug #1 — Element.click() throws via Runtime.callFunctionOn.
  # Workaround: CLICK_JS dispatches a synthetic Event('click') and falls
  # back to form.submit() / location.href for the default action.
  # ───────────────────────────────────────────────

  describe "Bug #1 — click() workaround" do
    it "fires a local click handler on a plain <button type=button>" do
      session.visit("/lightpanda/upstream/click_target")

      session.find(:css, "#counter-btn").click
      session.find(:css, "#counter-btn").click
      session.find(:css, "#counter-btn").click

      assert_equal "3", session.find(:css, "#counter").text
    end

    it "submits the form when clicking a <button type=submit>" do
      session.visit("/lightpanda/upstream/click_target")
      session.find(:css, "#submit-btn").click

      session.assert_selector(:css, "h1#ok", text: "Got payload=from-button")
    end

    it "navigates when clicking an <a href> link" do
      session.visit("/lightpanda/upstream/click_target")
      session.find(:css, "#nav-link").click

      session.assert_selector(:css, "h1", text: "Other Page")
    end

    it "respects defaultPrevented — does NOT double-submit when a handler intercepts" do
      session.visit("/lightpanda/upstream/click_target")
      session.execute_script(<<~JS)
        document.getElementById('submit-form').addEventListener('submit', function(e) {
          e.preventDefault();
          document.body.setAttribute('data-intercepted', 'yes');
        });
      JS

      session.find(:css, "#submit-btn").click

      assert_equal "yes", session.evaluate_script("document.body.getAttribute('data-intercepted')")
      assert_equal "/lightpanda/upstream/click_target", session.current_path,
                   "form.submit() should NOT run when defaultPrevented was called"
    end
  end
end
