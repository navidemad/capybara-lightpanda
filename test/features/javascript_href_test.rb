# frozen_string_literal: true

require_relative "../test_helper"

# `<a href="javascript:…">` is how select2, Bootstrap toggles and older jQuery
# code wire a link to a handler. The click's activation behavior runs the code
# and the page stays put. CLICK_JS used to also assign the href to
# location.href: Lightpanda requests `http://javascript:…`, and from build
# 10261 (upstream #3843) that failed navigation leaves the page with no
# execution context, so every later find raised NoExecutionContextError
# (lightpanda-io/browser#3898).
describe "Node#click on a javascript: link" do
  let(:session) { TestSessions::Lightpanda }

  before do
    session.visit("/lightpanda/js_test")
    session.execute_script(<<~JS)
      window.__jsHrefRuns = 0;
      var links = {
        'js-void': 'javascript:void(0)',
        'js-code': 'javascript:window.__jsHrefRuns++',
        'js-throw': 'javascript:throw new Error("js href boom")'
      };
      Object.keys(links).forEach(function(id) {
        var a = document.createElement('a');
        a.id = id; a.href = links[id]; a.textContent = id;
        document.body.appendChild(a);
      });
    JS
  end

  after { session.reset_session! }

  it "keeps the page usable after a javascript:void(0) link" do
    session.find(:css, "#js-void").click

    session.assert_current_path("/lightpanda/js_test", wait: 0)
    session.find(:css, "#click-me").click
    assert_equal "clicked", session.find(:css, "#result").text
  end

  # Exactly once: running the code from CLICK_JS as well as from the browser's
  # activation behavior would double every side effect (counters, toggles).
  it "runs the link's code exactly once" do
    session.find(:css, "#js-code").click

    assert_equal 1, session.evaluate_script("window.__jsHrefRuns")
  end

  it "does not surface the link code's exception to the caller" do
    session.find(:css, "#js-throw").click

    session.assert_current_path("/lightpanda/js_test", wait: 0)
    assert session.has_css?("#click-me")
  end
end
