# frozen_string_literal: true

require_relative "../test_helper"

# A script result that references itself can't be returned by value. Ferrum
# (so Cuprite) returns a CyclicObject placeholder; suites migrating from them
# compare against it rather than rescuing. Before this, `window` raised
# "Object reference chain is too long" from nightly 10255 (upstream #3831) and
# came back as a dead Element below it; a self-referencing object raised on
# every build.
describe "evaluate_script with a cyclic result" do
  let(:session) { TestSessions::Lightpanda }
  let(:cyclic) { Capybara::Lightpanda::CyclicObject.instance }

  before { session.visit("/lightpanda/js_test") }
  after { session.reset_session! }

  it "returns CyclicObject for a self-referencing object" do
    assert_same cyclic, session.evaluate_script("(function() { var a = { x: 1 }; a.self = a; return a; })()")
  end

  it "returns CyclicObject for the window" do
    build = session.driver.browser.nightly_build
    unless build && build >= Gem::Version.new("10255")
      skip "window serializes as a node below nightly 10255 (upstream #3831)"
    end

    assert_same cyclic, session.evaluate_script("window")
  end

  # The rescue must stay narrow: ordinary objects and real script errors
  # still behave as before.
  it "still serializes plain objects and raises script errors" do
    assert_equal({ "a" => 1 }, session.evaluate_script("({ a: 1 })"))
    assert_raises(Capybara::Lightpanda::JavaScriptError) { session.evaluate_script("null.boom") }
  end
end
