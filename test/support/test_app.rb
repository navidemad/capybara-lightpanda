# frozen_string_literal: true

require "capybara/spec/test_app"

class TestApp
  configure do
    set :protection, except: :frame_options
  end

  # -- Simple navigation pages --

  get "/lightpanda/simple" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Simple Page</title></head>
        <body>
          <h1>Simple Page</h1>
          <p id="content">Hello from Lightpanda</p>
          <a href="/lightpanda/other">Go to other page</a>
        </body>
      </html>
    HTML
  end

  get "/lightpanda/other" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Other Page</title></head>
        <body>
          <h1>Other Page</h1>
          <p id="content">This is the other page</p>
          <a href="/lightpanda/simple">Back to simple</a>
        </body>
      </html>
    HTML
  end

  # -- Event trigger test page --
  # Attaches focus / blur / change / submit / custom listeners that mark the
  # DOM so Node#trigger dispatch can be observed.

  get "/lightpanda/trigger_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Trigger Test</title></head>
        <body>
          <input id="focusable" type="text">
          <form id="submittable" action="javascript:void(0)"><button type="submit">go</button></form>
          <div id="custom-target"></div>
          <div id="result"></div>
          <script>
            document.getElementById('focusable').addEventListener('focus', function() {
              document.getElementById('result').textContent = 'focus-fired';
            });
            document.getElementById('submittable').addEventListener('submit', function(e) {
              var marker = (typeof SubmitEvent !== 'undefined' && e instanceof SubmitEvent)
                ? 'submit-fired:SubmitEvent'
                : 'submit-fired:Event';
              document.getElementById('result').textContent = marker;
            });
            document.getElementById('custom-target').addEventListener('lp:custom', function() {
              document.getElementById('result').textContent = 'custom-fired';
            });
          </script>
        </body>
      </html>
    HTML
  end

  # -- JavaScript test page --

  get "/lightpanda/js_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>JS Test</title></head>
        <body>
          <div id="result"></div>
          <button id="click-me" onclick="document.getElementById('result').textContent = 'clicked'">Click Me</button>
          <button id="dbl-click" ondblclick="document.getElementById('result').textContent = 'double-clicked'">Double Click</button>
          <button id="ctx-menu" oncontextmenu="document.getElementById('result').textContent = 'context-menu'; return false;">Right Click</button>
          <div id="hoverable" onmouseover="document.getElementById('result').textContent = 'hovered'">Hover me</div>
          <!-- select2-style: a helper clicks the outer wrapper, but the handler
               lives on an inner node; an offscreen-but-not-display:none sibling
               (like select2's .select2-focusser) sits next to the trigger. -->
          <div id="s2-wrapper">
            <a id="s2-trigger" href="javascript:void(0)"><span>Picked</span><span>v</span></a>
            <input id="s2-focusser" style="position:absolute;width:1px;height:1px;clip:rect(0 0 0 0)">
            <div id="s2-drop" style="display:none">drop</div>
          </div>
          <!-- a wrapper that carries its OWN click handler (role=button): the
               click must land here, not descend into the inner span. -->
          <div id="rb-wrapper" role="button"><span id="rb-inner">Press</span></div>
          <script>
            document.getElementById('s2-trigger').addEventListener('mousedown', function(e) {
              document.getElementById('result').textContent = 'inner:' + e.target.closest('a').id;
            });
            document.getElementById('rb-wrapper').addEventListener('click', function(e) {
              document.getElementById('result').textContent = 'rb:' + e.currentTarget.id + ':' + e.target.id;
            });
            window.testValue = 42;
            window.asyncValue = function() {
              return new Promise(function(resolve) {
                setTimeout(function() { resolve('async result'); }, 50);
              });
            };
          </script>
        </body>
      </html>
    HTML
  end

  # -- Form test page --

  get "/lightpanda/form_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Form Test</title></head>
        <body>
          <form id="test-form" action="/lightpanda/form_result" method="post">
            <label for="name">Name</label>
            <input type="text" id="name" name="name" placeholder="Enter name">

            <label for="email">Email</label>
            <input type="email" id="email" name="email">

            <label for="password">Password</label>
            <input type="password" id="password" name="password">

            <label for="bio">Bio</label>
            <textarea id="bio" name="bio"></textarea>

            <label for="agree">I agree</label>
            <input type="checkbox" id="agree" name="agree" value="yes">

            <label for="newsletter">Newsletter</label>
            <input type="checkbox" id="newsletter" name="newsletter" value="yes" checked>

            <fieldset>
              <legend>Gender</legend>
              <label><input type="radio" name="gender" value="male" id="gender-male"> Male</label>
              <label><input type="radio" name="gender" value="female" id="gender-female"> Female</label>
              <label><input type="radio" name="gender" value="other" id="gender-other"> Other</label>
            </fieldset>

            <label for="color">Favorite Color</label>
            <select id="color" name="color">
              <option value="">Choose...</option>
              <option value="red">Red</option>
              <option value="blue">Blue</option>
              <option value="green">Green</option>
            </select>

            <label for="hobbies">Hobbies</label>
            <select id="hobbies" name="hobbies[]" multiple>
              <option value="reading">Reading</option>
              <option value="coding">Coding</option>
              <option value="gaming">Gaming</option>
            </select>

            <label for="disabled-input">Disabled</label>
            <input type="text" id="disabled-input" name="disabled" disabled value="can't touch this">

            <label for="readonly-input">Read Only</label>
            <input type="text" id="readonly-input" name="readonly" readonly value="read only value">

            <div id="editable" contenteditable="true">Edit me</div>

            <input type="hidden" id="secret" name="secret" value="hidden_value">

            <input type="submit" id="submit-btn" value="Submit">
          </form>
        </body>
      </html>
    HTML
  end

  post "/lightpanda/form_result" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Form Result</title></head>
        <body>
          <h1>Form Submitted</h1>
          <pre id="results">#{Rack::Utils.escape_html(params.inspect)}</pre>
        </body>
      </html>
    HTML
  end

  # -- Visibility test page --

  get "/lightpanda/visibility" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Visibility Test</title>
          <style>
            #hidden-display-class { display: none; }
            #hidden-visibility-class { visibility: hidden; }
            #hidden-collapse-class { visibility: collapse; }
            #visible { display: block; }
          </style>
        </head>
        <body>
          <div id="visible">I am visible</div>
          <div id="hidden-display-inline" style="display: none">inline display none</div>
          <div id="hidden-display-upper" style="display: NONE">upper display none</div>
          <div id="hidden-visibility-upper" style="visibility: HIDDEN">upper visibility hidden</div>
          <div id="hidden-visibility-inline" style="visibility: hidden">inline visibility hidden</div>
          <div id="hidden-collapse-inline" style="visibility: collapse">inline visibility collapse</div>
          <div id="hidden-display-class">class display none</div>
          <div id="hidden-visibility-class">class visibility hidden</div>
          <div id="hidden-collapse-class">class visibility collapse</div>
          <div id="hidden-attr" hidden="hidden">hidden attribute</div>
          <div id="hidden-ancestor" hidden="hidden">
            <span id="hidden-via-ancestor">descendant of hidden ancestor</span>
          </div>
          <input type="hidden" id="hidden-input" value="secret">
          <details id="closed-details">
            <summary id="closed-summary">Click to open</summary>
            <p id="details-body">details body content</p>
          </details>
          <details id="open-details" open>
            <summary id="open-summary">Already open</summary>
            <p id="open-body">open body content</p>
          </details>
          <div id="text-with-hidden">
            Visible part
            <em style="display: none" id="hidden-em">SECRET</em>
            and more
          </div>
        </body>
      </html>
    HTML
  end

  # -- Page with nested elements for scoped finding --

  get "/lightpanda/nested" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Nested Elements</title></head>
        <body>
          <div id="parent">
            <span class="child">First child</span>
            <span class="child">Second child</span>
            <div class="nested">
              <span class="child">Nested child</span>
            </div>
          </div>
          <div id="sibling">
            <span class="child">Sibling child</span>
          </div>
        </body>
      </html>
    HTML
  end

  # -- Frame pages --

  get "/lightpanda/with_frame" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Page with Frame</title></head>
        <body>
          <h1 id="main-heading">Main Page</h1>
          <iframe id="test-frame" src="/lightpanda/frame_content"></iframe>
        </body>
      </html>
    HTML
  end

  get "/lightpanda/frame_content" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Frame Content</title></head>
        <body>
          <p id="frame-text">Inside the frame</p>
          <a id="frame-link" href="#">Frame link</a>
        </body>
      </html>
    HTML
  end

  # -- Cookie test pages --

  get "/lightpanda/set_test_cookie" do
    response.set_cookie("lightpanda_test", value: "cookie_value", path: "/")
    "Cookie set"
  end

  get "/lightpanda/get_test_cookie" do
    request.cookies["lightpanda_test"] || "No cookie"
  end

  # -- Cookie round-trip through redirect (tests PR #1889 HttpClient rework) --

  get "/lightpanda/set_cookie_and_redirect" do
    response.set_cookie("redirect_test", value: "survived_redirect", path: "/")
    redirect "/lightpanda/echo_redirect_cookie"
  end

  get "/lightpanda/echo_redirect_cookie" do
    request.cookies["redirect_test"] || "No cookie"
  end

  get "/lightpanda/set_samesite_cookie" do
    response["Set-Cookie"] = "ss_strict=strict_val; Path=/; SameSite=Strict"
    "SameSite cookie set"
  end

  get "/lightpanda/check_cookies" do
    cookies = request.cookies.map { |k, v| "#{k}=#{v}" }.sort.join("; ")
    cookies.empty? ? "No cookies" : cookies
  end

  # -- Dynamic content page --

  get "/lightpanda/dynamic" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Dynamic Page</title></head>
        <body>
          <div id="container"></div>
          <button id="add-element" onclick="
            var el = document.createElement('p');
            el.id = 'dynamic-element';
            el.textContent = 'I was added dynamically';
            document.getElementById('container').appendChild(el);
          ">Add Element</button>
          <button id="remove-element" onclick="
            var el = document.getElementById('dynamic-element');
            if (el) el.remove();
          ">Remove Element</button>
        </body>
      </html>
    HTML
  end

  # -- Page with various link types --

  get "/lightpanda/links" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Links Page</title></head>
        <body>
          <a id="absolute-link" href="/lightpanda/simple">Absolute link</a>
          <a id="anchor-link" href="#section">Anchor link</a>
          <a id="external-link" href="https://example.com">External link</a>
          <img id="test-image" src="/lightpanda/image.png" alt="Test image">
          <div id="section">Target section</div>
        </body>
      </html>
    HTML
  end

  # 1x1 transparent PNG referenced by /lightpanda/links. Lightpanda only
  # requests it when spawned with `--load-resources image` (the gem's
  # `load_images: true`), which image_loading_test.rb asserts both ways.
  get "/lightpanda/image.png" do
    content_type "image/png"
    Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
  end

  # -- Turbo-compatible form submission test --
  # Simulates Turbo intercepting a form submit event (prevents default, updates DOM).
  # Verifies that clicking a submit button fires the submit event with correct submitter.

  get "/lightpanda/turbo_form" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Turbo Form Test</title></head>
        <body>
          <form id="turbo-form" action="/lightpanda/form_result" method="post">
            <input type="text" id="turbo-name" name="name" value="test">
            <button type="submit" id="btn-save">Save</button>
            <button type="submit" id="btn-publish" formaction="/lightpanda/publish">Publish</button>
            <input type="submit" id="input-submit" value="Submit">
          </form>
          <div id="submit-result"></div>
          <script>
            document.getElementById('turbo-form').addEventListener('submit', function(e) {
              e.preventDefault();
              var submitterId = e.submitter ? e.submitter.id : 'none';
              document.getElementById('submit-result').textContent = 'intercepted:' + submitterId;
            });
          </script>
        </body>
      </html>
    HTML
  end

  # -- Turbo compatibility test pages --
  # Uses a mock Turbo global to test the gem's Turbo workarounds without a CDN dependency.

  get "/lightpanda/turbo_drive" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Turbo Drive Test</title></head>
        <body>
          <h1 id="page-title">Drive Page</h1>
          <a href="/lightpanda/other" id="drive-link">Go to Other</a>
          <script>
            window.Turbo = { session: { drive: true } };
          </script>
        </body>
      </html>
    HTML
  end

  get "/lightpanda/turbo_form_submit" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Turbo Form Test</title></head>
        <body>
          <h1>Turbo Form</h1>
          <form id="turbo-test-form" action="/lightpanda/turbo_form_result" method="post">
            <input type="text" id="turbo-name" name="name" value="">
            <button type="submit" id="turbo-submit">Submit</button>
            <button type="submit" id="turbo-save" name="action" value="save">Save</button>
            <button type="submit" id="turbo-alt" formaction="/lightpanda/turbo_form_alt_result">Alt Submit</button>
          </form>
          <script>
            window.Turbo = { session: { drive: false } };
          </script>
        </body>
      </html>
    HTML
  end

  post "/lightpanda/turbo_form_result" do
    name = Rack::Utils.escape_html(params["name"] || "")
    action = Rack::Utils.escape_html(params["action"] || "")
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Form Result</title></head>
        <body>
          <h1>Result</h1>
          <p id="result-name">#{name}</p>
          <p id="result-action">#{action}</p>
        </body>
      </html>
    HTML
  end

  post "/lightpanda/turbo_form_alt_result" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Alt Result</title></head>
        <body>
          <h1 id="alt-result">Alt action reached</h1>
        </body>
      </html>
    HTML
  end

  # -- Page with multiple element types for tag_name testing --

  # ─────────────────────────────────────────────────────────────────────
  # Upstream-bug fixtures.
  # Each page exposes a minimal scenario where a real browser succeeds and
  # Lightpanda failed natively without the gem-side workaround. The bugs
  # exercised here (#1, #3, #4) are now fixed or retracted upstream; the
  # fixtures stay to back the regression tests in upstream_bugs_test.rb.
  # ─────────────────────────────────────────────────────────────────────

  # Bug #3 — synthetic clicks must bubble to document so delegated handlers
  # (Stimulus, Turbo) see the event. The test inspects window.__hits which
  # records every click that reached document.
  get "/lightpanda/upstream/event_delegation" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Event delegation</title></head>
        <body>
          <button id="leaf-btn" type="button">Leaf</button>
          <script>
            window.__hits = [];
            document.addEventListener('click', function(e) {
              window.__hits.push({ phase: 'doc', target: e.target && e.target.id });
            });
            document.body.addEventListener('click', function(e) {
              window.__hits.push({ phase: 'body', target: e.target && e.target.id });
            });
          </script>
        </body>
      </html>
    HTML
  end

  # Bug #4 — native <dialog>. Page exposes a button that calls showModal()
  # and another that calls close(). Tests assert the [open] attribute.
  get "/lightpanda/upstream/dialog" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Dialog</title></head>
        <body>
          <dialog id="d">
            <p>I am modal</p>
            <button id="dialog-close" type="button" onclick="document.getElementById('d').close('done')">Close</button>
          </dialog>
          <button id="open-modal" type="button" onclick="document.getElementById('d').showModal()">Open modal</button>
          <button id="open-show" type="button" onclick="document.getElementById('d').show()">Open non-modal</button>
          <script>
            window.__closeEvents = [];
            document.getElementById('d').addEventListener('close', function() {
              window.__closeEvents.push(document.getElementById('d').returnValue);
            });
          </script>
        </body>
      </html>
    HTML
  end

  # Bug #1 — Element.click() via callFunctionOn. Local handler must run for
  # plain buttons; submit-button click must POST the form.
  get "/lightpanda/upstream/click_target" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Click target</title></head>
        <body>
          <button id="counter-btn" type="button">Count</button>
          <p id="counter">0</p>
          <form id="submit-form" action="/lightpanda/upstream/click_submitted" method="post">
            <input type="hidden" name="payload" value="from-button">
            <button id="submit-btn" type="submit">Submit</button>
          </form>
          <a id="nav-link" href="/lightpanda/other">Go elsewhere</a>
          <script>
            (function() {
              var n = 0;
              document.getElementById('counter-btn').addEventListener('click', function() {
                n += 1;
                document.getElementById('counter').textContent = String(n);
              });
            })();
          </script>
        </body>
      </html>
    HTML
  end

  post "/lightpanda/upstream/click_submitted" do
    "<!DOCTYPE html><html><body><h1 id='ok'>Got payload=#{Rack::Utils.escape_html(params['payload'].to_s)}</h1></body></html>"
  end

  # ─────────────────────────────────────────────────────────────────────
  # Hotwire-zone probe fixtures (separate from upstream/* — these check
  # whole-API surfaces required by Turbo Drive / Stimulus, not specific bugs).
  # ─────────────────────────────────────────────────────────────────────

  get "/lightpanda/probe/page" do
    "<!DOCTYPE html><html><head><title>Probe</title></head><body><h1 id='hello'>hi</h1></body></html>"
  end

  # Echoes back the request so the probe can verify fetch + FormData round-trip.
  post "/lightpanda/probe/echo" do
    content_type :json
    {
      method: request.request_method,
      content_type: request.content_type,
      params: params.to_h,
      raw_body_len: request.body.tap(&:rewind).read.bytesize,
    }.to_json
  end

  # Pure side-channel : every POST here increments a settings-stored counter.
  # Lets the probe distinguish "fetch never sent the HTTP request" vs
  # "request landed but Promise.then() never fired".
  set :hit_count, 0

  post "/lightpanda/probe/hit" do
    settings.hit_count += 1
    content_type :json
    { hits: settings.hit_count }.to_json
  end

  get "/lightpanda/probe/hit_count" do
    content_type :json
    { hits: settings.hit_count }.to_json
  end

  post "/lightpanda/probe/reset_hits" do
    settings.hit_count = 0
    "ok"
  end

  # Records every document lifecycle signal from a head script, so the probe
  # can assert which events actually reached page listeners (readystatechange
  # is fired natively since nightly 6736, lightpanda-io/browser#2708).
  # Emits one console call per level so Browser#console_logs capture can be
  # asserted: types, multi-arg text joining, falsy values, and the exclusion
  # of the Turbo activity-tracker sentinels.
  get "/lightpanda/console_logs" do
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><title>console logs</title></head>
      <body>
        <p>console fixture</p>
        <script>
          console.log("hello", 42, false);
          console.error("boom");
          console.warn("careful");
          // Same prefix the gem's Turbo tracker uses — must NOT be captured.
          // "idle" is safe to emit here: the turbo event is set (idle) by default.
          console.debug("__lightpanda_turbo_idle");
        </script>
      </body>
      </html>
    HTML
  end

  # Uncaught page errors, for Browser#page_errors. The whole point is that none
  # of these go through console.* — they're thrown, not logged, which is exactly
  # what console_logs cannot see (Lightpanda emits no Runtime.exceptionThrown).
  # A click triggers the throw so the test can assert the buffer was empty
  # beforehand, mirroring how a real handler dies mid-interaction.
  get "/lightpanda/page_errors" do
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><title>page errors</title></head>
      <body>
        <button id="thrower">throw</button>
        <button id="rejecter">reject</button>
        <p id="marker">page errors fixture</p>
        <script>
          document.getElementById('thrower').addEventListener('click', function() {
            var absent;
            // Same shape as the solidus taxon-tree failure: a handler reading a
            // property off undefined, with nothing logged anywhere.
            absent.id.toString();
          });
          document.getElementById('rejecter').addEventListener('click', function() {
            Promise.reject(new Error("rejected on purpose"));
          });
        </script>
      </body>
      </html>
    HTML
  end

  get "/lightpanda/probe/lifecycle" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Lifecycle Probe</title>
          <script>
            window.__lifecycle_log = ["script-eval:" + document.readyState];
            document.addEventListener("readystatechange", function() { window.__lifecycle_log.push("readystatechange:" + document.readyState); });
            document.addEventListener("DOMContentLoaded", function() { window.__lifecycle_log.push("DOMContentLoaded:" + document.readyState); });
            window.addEventListener("load", function() { window.__lifecycle_log.push("window.load:" + document.readyState); });
          </script>
        </head>
        <body><h1>lifecycle probe</h1></body>
      </html>
    HTML
  end

  # Real @hotwired/turbo bundle (vendored UMD build) — NOT the mock Turbo
  # global used by the /lightpanda/turbo_* fixtures above. Serves the
  # end-to-end turbo:load regression in test/features/turbo_load_test.rb.
  get "/lightpanda/probe/turbo_dist.js" do
    content_type "text/javascript"
    File.read(File.expand_path("../fixtures/turbo-8.0.23.umd.js", __dir__))
  end

  # Mirrors the beta-tester pattern that exposed A36: the server renders
  # html[data-turbo-not-loaded] and only Turbo's own turbo:load callback
  # removes it. If Turbo's PageObserver never completes, the attribute sticks.
  get "/lightpanda/probe/turbo_load" do
    <<~HTML
      <!DOCTYPE html>
      <html data-turbo-not-loaded="1">
        <head>
          <title>Turbo Load Probe</title>
          <script>
            window.__turbo_load_fired = false;
            document.addEventListener("turbo:load", function() {
              window.__turbo_load_fired = true;
              document.documentElement.removeAttribute("data-turbo-not-loaded");
            });
          </script>
          <script src="/lightpanda/probe/turbo_dist.js"></script>
        </head>
        <body><h1>Turbo load probe</h1></body>
      </html>
    HTML
  end

  get "/lightpanda/elements" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Elements Page</title></head>
        <body>
          <h1 id="heading">Heading</h1>
          <p id="paragraph">Paragraph text</p>
          <span id="inline">Inline text</span>
          <div id="block">Block text</div>
          <ul id="list">
            <li class="item">Item 1</li>
            <li class="item">Item 2</li>
            <li class="item">Item 3</li>
          </ul>
          <table id="data-table">
            <thead><tr><th>Name</th><th>Value</th></tr></thead>
            <tbody>
              <tr class="row"><td>A</td><td>1</td></tr>
              <tr class="row"><td>B</td><td>2</td></tr>
            </tbody>
          </table>
        </body>
      </html>
    HTML
  end

  # -- HTML5 drag-and-drop dropzone --
  # A vanilla-JS dropzone that reports what a real upload widget reads off the
  # dropped DataTransfer: each item's kind/getAsFile/getAsString/type, plus the
  # files count and types list. Node#drop fires dragenter -> dragover -> drop
  # carrying a DataTransfer, so this records the payload for assertions.

  get "/lightpanda/drop_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Drop Test</title></head>
        <body>
          <div id="dropzone">Drop here</div>
          <ul id="result"></ul>
          <div id="summary"></div>
          <script>
            var dz = document.getElementById('dropzone');
            var result = document.getElementById('result');
            var summary = document.getElementById('summary');
            function add(text) {
              var li = document.createElement('li');
              li.textContent = text;
              result.appendChild(li);
            }
            ['dragenter', 'dragover'].forEach(function(name) {
              dz.addEventListener(name, function(e) { e.preventDefault(); });
            });
            dz.addEventListener('drop', function(e) {
              e.preventDefault();
              var dt = e.dataTransfer;
              for (var i = 0; i < dt.items.length; i++) {
                var item = dt.items[i];
                if (item.kind === 'file') {
                  add('file: ' + item.getAsFile().name);
                } else {
                  (function(type) {
                    item.getAsString(function(s) { add('string: ' + type + ' ' + s); });
                  })(item.type);
                }
              }
              summary.textContent = 'files=' + dt.files.length + ' types=' + dt.types.join(',');
            });
          </script>
        </body>
      </html>
    HTML
  end

  # -- HTML5 drag_to source/target --
  # A draggable source whose dragstart handler stashes a payload, and a
  # dropzone that accepts (preventDefault on dragover) and logs what arrived.
  # Node#drag_to's HTML5 simulation must carry ONE DataTransfer across the
  # whole event sequence for the payload to survive dragstart -> drop.
  # `#not_draggable` exercises the legacy-path detection.
  get "/lightpanda/drag_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Drag Test</title></head>
        <body>
          <div id="drag_source" draggable="true">Drag me</div>
          <div id="not_draggable">Plain text</div>
          <div id="dropzone">Drop here</div>
          <div id="log"></div>
          <script>
            document.getElementById('drag_source').addEventListener('dragstart', function(e) {
              e.dataTransfer.setData('text/plain', 'from-source');
            });
            var dz = document.getElementById('dropzone');
            dz.addEventListener('dragover', function(e) { e.preventDefault(); });
            dz.addEventListener('drop', function(e) {
              e.preventDefault();
              document.getElementById('log').textContent =
                'dropped: ' + e.dataTransfer.getData('text/plain');
            });
          </script>
        </body>
      </html>
    HTML
  end

  # Hover target. `.reveal` is hidden and CSS-revealed only on `.box:hover`
  # (which Lightpanda can't satisfy — no pointer state), while a JS `mouseover`
  # listener records into `#log` (which Node#hover's event dispatch DOES drive).
  get "/lightpanda/hover_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Hover Test</title>
          <style>
            .reveal { display: none; }
            .box:hover .reveal { display: block; }
          </style>
        </head>
        <body>
          <div id="box" class="box"><span id="reveal" class="reveal">revealed</span></div>
          <div id="log"></div>
          <div id="enter_log"></div>
          <script>
            document.getElementById('box').addEventListener('mouseover', function() {
              document.getElementById('log').textContent = 'mouseover-fired';
            });
            // The `mouseenter->controller#open` idiom: a non-bubbling listener
            // on the hovered element itself, which mouseover alone never reaches.
            document.getElementById('box').addEventListener('mouseenter', function() {
              document.getElementById('enter_log').textContent = 'mouseenter-fired';
            });
          </script>
        </body>
      </html>
    HTML
  end

  # Click event sequence. `#seq` records every pointer event on the button so
  # tests can assert the mousedown -> mouseup -> click order, and `#widget`
  # mimics select2: the panel opens from a `mousedown` listener (select2 v3
  # binds "mousedown touchstart", never "click").
  get "/lightpanda/click_events_test" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Click Events Test</title></head>
        <body>
          <button id="btn">Click me</button>
          <div id="seq"></div>
          <div id="widget">choose…</div>
          <div id="panel" style="display: none"><span id="option">Option A</span></div>
          <script>
            ['mousedown', 'mouseup', 'click'].forEach(function(name) {
              document.getElementById('btn').addEventListener(name, function() {
                var seq = document.getElementById('seq');
                seq.textContent += (seq.textContent ? ' ' : '') + name;
              });
            });
            document.getElementById('widget').addEventListener('mousedown', function() {
              document.getElementById('panel').style.display = 'block';
            });
          </script>
        </body>
      </html>
    HTML
  end

  # Modal type leniency. The delete button fires `confirm()` (the jquery-ujs /
  # data-confirm idiom), letting tests drive it through `accept_alert` the way
  # real suites (solidus admin) do.
  get "/lightpanda/modal_type_leniency" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Modal Type Leniency</title></head>
        <body>
          <button id="delete">Delete</button>
          <div id="outcome"></div>
          <script>
            document.getElementById('delete').addEventListener('click', function() {
              var ok = confirm('Are you sure?');
              document.getElementById('outcome').textContent = ok ? 'deleted' : 'kept';
            });
          </script>
        </body>
      </html>
    HTML
  end

  # -- Download page --
  # A link to an attachment response. Unlike Capybara's own /download.csv
  # (text/csv with NO Content-Disposition, which Lightpanda renders rather than
  # downloads), /lightpanda/report.csv sends `Content-Disposition: attachment`,
  # which is what Lightpanda's Browser.setDownloadBehavior keys off (PR #2722).
  get "/lightpanda/download_page" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Download Page</title></head>
        <body>
          <a id="dl" href="/lightpanda/report.csv" download>Download report</a>
        </body>
      </html>
    HTML
  end

  get "/lightpanda/report.csv" do
    content_type "text/csv"
    attachment "report.csv"
    "name,score\nlightpanda,100\n"
  end

  # -- Viewport / responsive page --
  # Two mutually exclusive CTAs gated by a `@media` width breakpoint, which is
  # the shape `window_size` -> Emulation.setDeviceMetricsOverride has to get
  # right: at a desktop viewport only #desktop-cta is visible, at a narrow one
  # only #mobile-cta. Both carry the same text so a driver that ignores the
  # media query surfaces as Capybara::Ambiguous rather than a silent pass.
  get "/lightpanda/viewport" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>Viewport Page</title>
          <style>
            #mobile-cta { display: none; }
            @media (max-width: 500px) {
              #desktop-cta { display: none; }
              #mobile-cta { display: block; }
            }
          </style>
        </head>
        <body>
          <a id="desktop-cta" href="/lightpanda/other">Get started</a>
          <a id="mobile-cta" href="/lightpanda/other">Get started</a>
        </body>
      </html>
    HTML
  end
  # -- Keyboard activation (upstream #3264, build >= 8842) --
  # Every control here is driven through CDP Input.dispatchKeyEvent, which
  # builds a *trusted* KeyboardEvent — the precondition for the browser's
  # keypress/activation synthesis. The handlers only log, so the assertions
  # stay independent of #3179 (anchor default action), which is still open.
  get "/lightpanda/keyboard_activation" do
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Keyboard Activation</title></head>
        <body>
          <button type="button" id="btn">Press me</button>
          <a id="link" href="/lightpanda/other">A link</a>
          <input type="checkbox" id="cb">
          <form id="f" action="/lightpanda/other" method="get">
            <input type="text" id="field" name="q" value="hello">
            <input type="submit" id="submit-btn" value="Go">
          </form>
          <div id="log"></div>
          <div id="keypress-log"></div>
          <script>
            var log = document.getElementById('log');
            function record(name) { log.textContent = name; }
            document.getElementById('btn').addEventListener('click', function() {
              record('button-clicked');
            });
            document.getElementById('link').addEventListener('click', function(e) {
              // Cancel the default action: this example asserts that the
              // activation event reached the anchor, not that Lightpanda
              // navigates (see upstream #3179).
              e.preventDefault();
              record('link-clicked');
            });
            document.getElementById('field').addEventListener('keypress', function(e) {
              document.getElementById('keypress-log').textContent = 'keypress:' + e.key;
            });
          </script>
        </body>
      </html>
    HTML
  end
end
