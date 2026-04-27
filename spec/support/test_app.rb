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
          <script>
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
end
