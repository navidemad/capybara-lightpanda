# frozen_string_literal: true

require_relative "../test_helper"

# Iframes have to keep loading across upstream's #3305 default flip.
#
# Build 8946 turned `Config.LoadResources` into a four-field struct with every
# sub-resource defaulting to false and dropped `Session.load_resources`'s own
# default, so `Frame.iframeAddedCallback` returns early unless `iframe` is set.
# The parser still puts the `<iframe>` in the DOM; no child frame is ever
# created. `switch_to_frame` and `within_frame` then find nothing.
#
# `Browser#configure_loading` sends `LP.configureLoading {subFrame: true,
# worker: true}` from `create_page` to hold the old behavior. This file is the
# end-to-end proof. Honest about what it can catch where: on a build below 8946
# it passes with or without the fix, because iframes defaulted on. It only
# discriminates from 8946 up — which is precisely the build range where a
# regression would otherwise reach users as "within_frame stopped working" with
# no error naming a cause.
describe "Capybara::Lightpanda iframe loading" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "loads child frames and can work inside them" do
    session.visit("/lightpanda/with_frame")

    assert session.has_css?("#main-heading", text: "Main Page")

    session.within_frame("test-frame") do
      assert session.has_css?("#frame-text", text: "Inside the frame")
    end

    # Back on the parent document: a frame stack that leaked would fail here.
    assert session.has_css?("#main-heading", text: "Main Page")
  end

  # reset_session! disposes the BrowserContext and builds a new one, and
  # LP.configureLoading is per-context — so a fix applied only at start would
  # work for exactly one example and then quietly stop. Every suite reuses one
  # session across many examples, which makes this the case that actually bites.
  it "still loads child frames after a session reset" do
    session.visit("/lightpanda/with_frame")
    session.reset_session!

    session.visit("/lightpanda/with_frame")
    session.within_frame("test-frame") do
      assert session.has_css?("#frame-text", text: "Inside the frame")
    end
  end
end
