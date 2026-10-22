# frozen_string_literal: true

require_relative "../test_helper"

# document.elementFromPoint retargets a hit inside a shadow tree to its host,
# and Lightpanda has no ShadowRoot.elementFromPoint, so obscured? used to report
# every element inside a shadow root as covered — the host was "on top".
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
end
