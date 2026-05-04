# frozen_string_literal: true

require "spec_helper"

# Tests d'intégration ciblés sur les bugs upstream du binaire Lightpanda
# documentés dans UPSTREAM_BUGS.md. Chaque exemple exerce le scénario qui
# crashe nativement, puis vérifie que le workaround côté gem (CLICK_JS,
# polyfills.js) le fait passer.
#
# Si une PR upstream supprime un workaround, ces tests doivent rester verts
# sur le binaire patché — ils décrivent le contrat fonctionnel attendu, pas
# l'implémentation du contournement.
RSpec.describe "Upstream Lightpanda bug repros & workarounds" do
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
      expect(phases).to include("body", "doc"), "expected click to bubble through body+document, got: #{hits.inspect}"
    end

    it "preserves event.target as the original element on each ancestor" do
      session.visit("/lightpanda/upstream/event_delegation")
      session.find(:css, "#leaf-btn").click

      hits = session.evaluate_script("window.__hits")
      targets = hits.map { |h| h["target"] }.uniq
      expect(targets).to eq(["leaf-btn"]), "delegated handlers must receive the original target"
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
      expect(hits.map { |h| h["phase"] }).to include("doc")
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

      expect(session).to have_no_css("dialog#d[open]")
      session.find(:css, "#open-modal").click
      expect(session).to have_css("dialog#d[open]")
    end

    it "opens the dialog via show() (non-modal)" do
      session.visit("/lightpanda/upstream/dialog")
      session.find(:css, "#open-show").click
      expect(session).to have_css("dialog#d[open]")
    end

    it "close() removes [open] and dispatches a 'close' event with returnValue" do
      session.visit("/lightpanda/upstream/dialog")
      session.find(:css, "#open-modal").click
      session.find(:css, "#dialog-close").click

      expect(session).to have_no_css("dialog#d[open]")
      events = session.evaluate_script("window.__closeEvents")
      expect(events).to eq(["done"]), "expected the polyfilled close() to dispatch a 'close' event"
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
      expect(threw).to match(/InvalidStateError|already.+open/i)
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

      expect(session.find(:css, "#counter").text).to eq("3")
    end

    it "submits the form when clicking a <button type=submit>" do
      session.visit("/lightpanda/upstream/click_target")
      session.find(:css, "#submit-btn").click

      expect(session).to have_css("h1#ok", text: "Got payload=from-button")
    end

    it "navigates when clicking an <a href> link" do
      session.visit("/lightpanda/upstream/click_target")
      session.find(:css, "#nav-link").click

      expect(session).to have_css("h1", text: "Other Page")
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

      expect(session.evaluate_script("document.body.getAttribute('data-intercepted')")).to eq("yes")
      expect(session.current_path).to eq("/lightpanda/upstream/click_target"),
                                      "form.submit() should NOT run when defaultPrevented was called"
    end
  end
end
