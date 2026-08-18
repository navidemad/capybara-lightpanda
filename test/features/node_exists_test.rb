# frozen_string_literal: true

require_relative "../test_helper"

# Node#exists? — the quiet form of the isConnected guard (Ferrum parity).
# Every other node operation raises ObsoleteNode for a gone node so Capybara
# can auto-reload; exists? is for callers that just want to know, without
# an exception round-trip: cleanup helpers, "is that toast still there?" polls.
describe "Capybara::Lightpanda::Node#exists?" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "is true for a node still attached to the live document" do
    session.visit("/lightpanda/dynamic")
    session.find(:css, "#add-element").click

    assert session.find(:css, "#dynamic-element").native.exists?
  end

  it "is false once the node is removed from the DOM — no ObsoleteNode raised" do
    session.visit("/lightpanda/dynamic")
    session.find(:css, "#add-element").click
    node = session.find(:css, "#dynamic-element").native
    session.find(:css, "#remove-element").click

    refute node.exists?
  end

  it "is false after the document navigates away — the objectId's context is gone" do
    session.visit("/lightpanda/simple")
    node = session.find(:css, "#content").native
    session.visit("/lightpanda/other")

    refute node.exists?
  end
end
