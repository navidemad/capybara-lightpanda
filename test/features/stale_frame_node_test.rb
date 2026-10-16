# frozen_string_literal: true

require_relative "../test_helper"

# An element held across its iframe's navigation must go stale, not keep
# answering from the document the frame left.
#
# When a frame navigates, Chrome destroys the old document's execution context,
# so any call on a node from it fails and Capybara's automatic_reload re-runs
# the query against the new document. Lightpanda keeps that context alive: the
# node still answers, with `isConnected` true and `ownerDocument.defaultView`
# null, so reads return the discarded document's state (`visible?` false, text
# "") and no error ever tells Capybara to re-find. Matchers hide this (they
# reload on every retry), but a plain `text`, `visible?` or `click` on an
# element held across a frame's form submit or link silently hits the old page.
#
# `Node#call` treats a frame-scoped node whose document has lost its window as
# obsolete. Only frame-scoped nodes: a document built by script
# (`DOMParser`, `createHTMLDocument`) never had a window either, and a node
# from one is still usable.
describe "Capybara::Lightpanda nodes held across a frame navigation" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "re-finds an element after its frame navigates instead of reading the old document" do
    session.visit("/lightpanda/with_versioned_frame")

    session.within_frame("versioned-frame") do
      version = session.find(:css, "#version")
      assert_equal "v1", version.text

      session.click_link("Next")
      assert session.has_css?("#version", text: "v2")

      # A plain read, not a matcher: matchers reload on every retry anyway,
      # but `text` reloads only on an invalid-element error. Without one it
      # reads the discarded document, whose visible text is "".
      assert_equal "v2", version.text
    end
  end

  it "raises ObsoleteNode for a node of the frame's previous document" do
    session.visit("/lightpanda/with_versioned_frame")

    node = nil
    session.within_frame("versioned-frame") do
      node = session.find(:css, "#version").base
      session.click_link("Next")
      assert session.has_css?("#version", text: "v2")
    end

    assert_raises(Capybara::Lightpanda::ObsoleteNode) { node.visible_text }
    refute node.exists?
  end

  # Removing the <iframe> discards its document too (upstream #3939, 10544):
  # `defaultView` turns null, so the same guard catches a node held from a
  # frame the page took away. Before #3939 the removed frame lived on and the
  # node kept answering from it.
  it "raises ObsoleteNode for a node of a removed frame" do
    session.visit("/lightpanda/with_versioned_frame")

    node = nil
    session.within_frame("versioned-frame") { node = session.find(:css, "#version").base }
    session.execute_script("document.getElementById('versioned-frame').remove()")

    assert_raises(Capybara::Lightpanda::ObsoleteNode) { node.visible_text }
    refute node.exists?
  end

  it "keeps a node from a script-built document usable" do
    session.visit("/lightpanda/js_test")

    body = session.evaluate_script("new DOMParser().parseFromString('<p>parsed</p>', 'text/html').body")

    # text(:all): a windowless document is never rendered, so its visible text is "".
    assert_equal "parsed", body.text(:all)
  end
end
