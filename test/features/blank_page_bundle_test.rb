# frozen_string_literal: true

require_relative "../test_helper"

# Page.addScriptToEvaluateOnNewDocument only reaches documents created after
# it, so the about:blank page a session starts on (and the one reset_session!
# leaves behind) had no `_lightpanda`. A suite that builds DOM with
# execute_script before its first visit then failed every visibility check and
# click with `ReferenceError: _lightpanda is not defined`.
describe "the page a session starts on, before any visit" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  def build_dom
    session.execute_script(<<~JS)
      var d = document;
      if (!d.documentElement) d.appendChild(d.createElement('html'));
      d.documentElement.innerHTML = '<head></head><body><p id="x">hi</p><button id="b" onclick="this.textContent = \\'clicked\\'">go</button></body>';
    JS
  end

  def assert_driver_works_without_a_visit
    build_dom
    assert_equal "hi", session.find(:css, "#x").text
    session.find(:css, "#b").click
    assert_equal "clicked", session.find(:css, "#b").text
  end

  it "finds and clicks after reset_session!" do
    session.visit("/lightpanda/js_test")
    session.reset_session!

    assert_driver_works_without_a_visit
  end
end
