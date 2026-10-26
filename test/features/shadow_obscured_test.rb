# frozen_string_literal: true

require_relative "../test_helper"

# Document hit testing retargets shadow content to its host. New browsers can
# inspect inside the root; older supported builds must retain the host fallback.
describe "Node#obscured? inside a shadow root" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/shadow_obscured") }
  after { session.reset_session! }

  # The "covered by a light-DOM element" half isn't pinned: neither 1.0.1 nor
  # nightly 10965 honors top/left or negative margins in getBoundingClientRect,
  # so no fixture can make one box overlap another (probed 2026-10-22).
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
