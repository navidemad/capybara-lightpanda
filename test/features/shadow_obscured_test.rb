# frozen_string_literal: true

require_relative "../test_helper"

# Document hit testing retargets shadow content to its host, so isObscured
# looks inside the root with ShadowRoot.elementFromPoint (upstream #4184, in
# the floor). predicates.js still feature-detects it and accepts the host hit
# when it is missing.
describe "Node#obscured? inside a shadow root" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/shadow_obscured") }
  after { session.reset_session! }

  # The "covered by a light-DOM element" half isn't pinned here. When this file
  # was written, no build honored top/left or negative margins in
  # getBoundingClientRect (probed 2026-10-22 on 1.0.1 and nightly 10965).
  # Geometry overlap works on the floor now — Capybara's "should see
  # overlapped elements as obscured" passes on 1.0.4 (spec/spec_helper.rb) —
  # but the test below still supplies its covering hit directly.
  it "is not obscured when the hit lands on its own host" do
    button = session.find(:css, "#host").shadow_root.find(:css, "button")

    refute_predicate button, :obscured?
  end

  it "reports an overlay inside the root instead of accepting the host hit" do
    # Supply a covering hit without relying on Lightpanda's synthetic overlap
    # geometry. The browser-backed bundle must not hide this from Capybara.
    session.execute_script(<<~JS)
      var root = document.getElementById('host').shadowRoot;
      var cover = document.createElement('div');
      root.appendChild(cover);
      root.elementFromPoint = function() { return cover; };
    JS
    button = session.find(:css, "#host").shadow_root.find(:css, "button")

    assert_predicate button, :obscured?
  end
end
