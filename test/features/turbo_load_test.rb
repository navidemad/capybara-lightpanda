# frozen_string_literal: true

require_relative "../test_helper"

# End-to-end regression for the readystatechange → turbo:load chain
# (historically wishlist A36: Lightpanda never fired readystatechange →
# Turbo's PageObserver never reached pageLoaded → no turbo:load; fixed
# upstream by lightpanda-io/browser#2708, in the nightly ≥6736 floor).
# Unlike the /lightpanda/turbo_* fixtures, this loads the REAL
# @hotwired/turbo bundle (vendored in test/fixtures) and mirrors the
# beta-tester pattern that exposed the bug: the server renders
# html[data-turbo-not-loaded] and only a turbo:load listener removes it.
describe "Turbo turbo:load end-to-end" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "fires turbo:load on initial page load so Turbo-gated wait helpers settle" do
    session.visit("/lightpanda/probe/turbo_load")

    session.assert_no_selector "html[data-turbo-not-loaded]", visible: :all
    assert_equal true, session.evaluate_script("window.__turbo_load_fired"),
                 "real Turbo booted but turbo:load never fired — readystatechange regression?"
  end

  it "boots the real Turbo bundle without JS errors" do
    session.visit("/lightpanda/probe/turbo_load")

    assert_equal "object", session.evaluate_script("typeof window.Turbo"),
                 "vendored Turbo bundle failed to evaluate"
  end
end
