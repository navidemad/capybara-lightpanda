# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Node < ::Capybara::Driver::Node
      attr_reader :remote_object_id

      def initialize(driver, remote_object_id)
        super
        @remote_object_id = remote_object_id
      end

      def text
        ensure_connected
        call("function() { return this.textContent }")
      end

      def all_text
        ensure_connected
        filter_text(call("function() { return this.textContent }"))
      end

      # Lightpanda's innerText returns textContent verbatim (no rendering, so no
      # hidden-descendant filtering). Walk descendants ourselves, skipping nodes
      # that fail VISIBLE_JS, and emit newlines around block-display elements
      # (the part of innerText behavior we still need).
      def visible_text
        ensure_connected
        call(VISIBLE_TEXT_JS).to_s
                             .gsub(/\A[[:space:]&&[^\u00A0]]+/, "")
                             .gsub(/[[:space:]&&[^\u00A0]]+\z/, "")
                             .gsub(/[ \t\f\v]+/, " ")
                             .gsub(/[ \t\f\v]*\n[ \t\f\v\n]*/, "\n")
                             .tr("\u00A0", " ")
      end

      def rect
        call(GET_RECT_JS)
      end

      def obscured?
        call(OBSCURED_JS)
      end

      def shadow_root
        result = driver.browser.with_default_context_wait do
          driver.browser.call_function_on(
            @remote_object_id,
            "function() { return this.shadowRoot }",
            return_by_value: false
          )
        end
        return nil unless result.is_a?(Hash) && result["objectId"]

        self.class.new(driver, result["objectId"])
      end

      # Smart property/attribute getter (Cuprite pattern).
      # Returns resolved URLs for src/href, raw attributes otherwise.
      def [](name)
        call(PROPERTY_OR_ATTRIBUTE_JS, name.to_s)
      end

      def value
        call(GET_VALUE_JS)
      end

      def style(styles)
        styles.to_h { |style| [style, call(GET_STYLE_JS, style)] }
      end

      def click(_keys = [], **_options)
        call(CLICK_JS)
        driver.browser.wait_for_idle
      end

      def right_click(_keys = [], **_options)
        call("function() { this.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true})) }")
      end

      def double_click(_keys = [], **_options)
        call("function() { this.dispatchEvent(new MouseEvent('dblclick', {bubbles: true, cancelable: true})) }")
      end

      def hover
        call("function() { this.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, cancelable: true})) }")
      end

      def set(value, **_options)
        case tag_name
        when "input"
          fill_input(value)
        when "textarea"
          call(SET_VALUE_JS, truncate_to_maxlength(value.to_s))
        else
          # `contenteditable` cascades through descendants. Check
          # `isContentEditable`, then fall back to walking ancestors for
          # `contenteditable` since Lightpanda doesn't expose the property on
          # every element. EDITABLE_HOST_JS encapsulates that check.
          call("function(v) { this.innerHTML = v }", value.to_s) if call(EDITABLE_HOST_JS)
        end
      end

      def select_option
        call(SELECT_OPTION_JS)
      end

      def unselect_option
        unless call("function() {
          var s = this.parentElement;
          while (s && (s.tagName || '').toUpperCase() !== 'SELECT') s = s.parentElement;
          return !!(s && s.multiple);
        }")
          raise Capybara::UnselectNotAllowed, "Cannot unselect option from single select box."
        end

        call(UNSELECT_OPTION_JS)
      end

      def send_keys(*)
        call("function() { this.focus() }")
        driver.browser.keyboard.type(*)
      end

      def tag_name
        # ShadowRoot/DocumentFragment have no tagName; report a stable label so
        # Capybara's failure messages can render `tag="ShadowRoot"`.
        # Memoized: an objectId points to a single DOM node whose tagName is
        # immutable for that node's lifetime.
        @tag_name ||= call("function() {
          if (this.nodeType === 11) return 'ShadowRoot';
          return this.tagName ? this.tagName.toLowerCase() : '';
        }")
      end

      def visible?
        call(VISIBLE_JS)
      end

      def checked?
        call("function() { return this.checked }")
      end

      def selected?
        call("function() { return !!this.selected }")
      end

      def disabled?
        call(DISABLED_JS)
      end

      def readonly?
        call("function() { return this.readOnly }")
      end

      def multiple?
        call("function() { return this.multiple }")
      end

      def path
        call(GET_PATH_JS)
      end

      def find_xpath(selector)
        object_ids = driver.browser.find_within(@remote_object_id, "xpath", selector)
        object_ids.map { |oid| self.class.new(driver, oid) }
      end

      def find_css(selector)
        object_ids = driver.browser.find_within(@remote_object_id, "css", selector)
        object_ids.map { |oid| self.class.new(driver, oid) }
      end

      # Equality compares the underlying DOM node via backendNodeId, the only
      # identity that's stable across CDP calls. NO fast path on remote_object_id:
      # two wrappers with the same remote_object_id can resolve to different
      # backendNodeIds (one cached at 42, the other still nil from a transient
      # describeNode failure), and a remote-id fast path there would return `true`
      # while `#hash` returned different values, violating the hash contract.
      # When either side fails to resolve, the nodes are treated as not equal so
      # stale wrappers don't collapse onto each other.
      def ==(other)
        return false unless other.is_a?(self.class)

        left = backend_node_id
        right = other.backend_node_id
        !left.nil? && left == right
      end

      alias eql? ==

      # Hash on backendNodeId so equal nodes always hash the same. When
      # describeNode fails (returns nil) the bucket collapses to `nil.hash`;
      # combined with `==` returning false for nil-resolved nodes, Set/Hash
      # membership stays consistent (collisions are allowed for unequal objects).
      def hash
        backend_node_id.hash
      end

      def backend_node_id
        @backend_node_id ||= driver.browser.backend_node_id(@remote_object_id)
      end

      private

      # Capybara's `automatic_reload` re-runs the original query when an element
      # access raises one of the driver's `invalid_element_errors`. After a DOM
      # mutation like `replaceWith`, our cached objectId still resolves to the
      # detached node, so reads succeed (with stale data) and the auto-reload
      # never fires. Detect detachment via `isConnected` and raise so the
      # synchronize-loop notices and triggers a re-find.
      def ensure_connected
        connected = call("function() { return this.isConnected }")
        return if connected

        raise ObsoleteNode.new(self, "Node is no longer attached to the document")
      end

      # Trigger implicit form submission via the IMPLICIT_SUBMIT_JS pipeline
      # (same fetch+swap as CLICK_JS, but without a submitter).
      def implicit_submit
        call(IMPLICIT_SUBMIT_JS)
        driver.browser.wait_for_idle
      end

      TEXT_LIKE_INPUT_TYPES = %w[text email password url tel search number].freeze
      private_constant :TEXT_LIKE_INPUT_TYPES

      def fill_input(value)
        type = self["type"]
        case type
        when "checkbox", "radio"
          call(SET_CHECKBOX_JS, value ? true : false)
        when "file"
          raise NotImplementedError, "File uploads not yet supported by Lightpanda"
        when "date"
          call(SET_VALUE_JS, format_date_value(value))
        when "time"
          call(SET_VALUE_JS, format_time_value(value))
        when "datetime-local"
          call(SET_VALUE_JS, format_datetime_value(value))
        else
          fill_text_input(type, value.to_s)
        end
      end

      # HTML implicit-submission: a trailing \n in a text-like input is like the
      # user pressing Enter — submits the form when there's a default submit
      # button OR exactly one text control. Strip the \n, set the value, then
      # route through IMPLICIT_SUBMIT_JS so CLICK_JS's fetch+swap runs.
      def fill_text_input(type, str)
        if str.end_with?("\n") && TEXT_LIKE_INPUT_TYPES.include?(type)
          call(SET_VALUE_JS, truncate_to_maxlength(str.chomp))
          implicit_submit
        else
          call(SET_VALUE_JS, truncate_to_maxlength(str))
        end
      end

      # Format helpers for Date/Time/DateTime values passed to date/time/datetime-local
      # inputs. Mirror Capybara::Selenium's SettableValue so a Ruby Time fills the
      # field with the same string the user would type.
      def format_date_value(value)
        return value.to_s if value.is_a?(String) || !value.respond_to?(:to_date)

        value.to_date.iso8601
      end

      def format_time_value(value)
        return value.to_s if value.is_a?(String) || !value.respond_to?(:to_time)

        value.to_time.strftime("%H:%M")
      end

      def format_datetime_value(value)
        return value.to_s if value.is_a?(String) || !value.respond_to?(:to_time)

        value.to_time.strftime("%Y-%m-%dT%H:%M")
      end

      # `maxlength` only constrains user typing, not direct value assignment, but
      # Selenium-style drivers truncate to match what a user would have ended up
      # with. Honor it explicitly so Capybara-shared specs behave the same.
      def truncate_to_maxlength(str)
        max = self["maxlength"]
        return str unless max

        n = max.to_i
        n.positive? ? str[0, n] : str
      end

      # Whitespace-normalized text (Cuprite pattern). Capybara's text matchers compare
      # against this, and Lightpanda's textContent preserves source-template whitespace
      # differently than Chrome — without normalization, multi-line fixtures fail
      # `text: "Line\nLine"` matchers.
      def filter_text(text)
        text.to_s
            .gsub(/[\u200B\u200E\u200F]/, "")
            .gsub(/[ \n\f\t\v\u2028\u2029]+/, " ")
            .gsub(/\A[[:space:]&&[^\u00A0]]+/, "")
            .gsub(/[[:space:]&&[^\u00A0]]+\z/, "")
            .tr("\u00A0", " ")
      end

      # Centralized command dispatch via Runtime.callFunctionOn.
      # The function runs with `this` bound to the DOM element by CDP.
      # JS bodies may reference `_lightpanda.*` helpers — they're registered via
      # Page.addScriptToEvaluateOnNewDocument in every document (top frame and
      # iframes alike), so the namespace is available wherever `this` lives.
      def call(function_declaration, *args)
        driver.browser.with_default_context_wait do
          driver.browser.call_function_on(@remote_object_id, function_declaration, *args)
        end
      rescue BrowserError => e
        case e.message
        when /MouseEventFailed/i
          raise MouseEventFailed.new(self, e.response&.dig("message"))
        else
          raise
        end
      rescue JavaScriptError => e
        case e.class_name
        when "InvalidSelector"
          raise InvalidSelector.new(e.message, nil, args.first)
        else
          raise
        end
      end

      # Form-submit click bypass for Lightpanda.
      #
      # Lightpanda's `form.submit()` does NOT navigate — it parses, validates, but
      # never issues an HTTP request. And `document.write()` is a no-op (verified
      # 2026-04-26: body length unchanged after open/write/close). So both the
      # native submit path and the previous `fetch+document.write` workaround leave
      # the page on the original URL with the form still rendered.
      #
      # For submit-button clicks we instead `fetch` the form action ourselves,
      # parse the response with `DOMParser`, swap `document.body.innerHTML`, and
      # `history.replaceState` the response URL. `_lightpanda` and the XPath
      # polyfill survive the swap because we don't reload the document.
      #
      # For non-submit elements (links, regular buttons, anchors) we fall through
      # to native `this.click()`. Turbo Drive's click handler — when Turbo is
      # loaded — intercepts that natively, runs its own fetch+replaceWith, and
      # works fine on Lightpanda after the `#id` rewriter polyfill in index.js.
      CLICK_JS = <<~JS
        function() {
          var tag = this.tagName.toLowerCase();
          var type = (this.type || '').toLowerCase();
          // <button> with no `type` attribute defaults to submit per HTML.
          var isSubmitBtn = (tag === 'button' && (type === '' || type === 'submit')) ||
                            (tag === 'input' && (type === 'submit' || type === 'image'));
          var form = isSubmitBtn ? this.form : null;
          // Lightpanda doesn't propagate label clicks to their associated
          // form control the way browsers do, so when Capybara clicks a
          // <label> for a hidden checkbox/radio (automatic_label_click)
          // we explicitly forward the click.
          if (tag === 'label') {
            this.click();
            var ctrl = null;
            var forId = this.getAttribute('for');
            if (forId) ctrl = this.ownerDocument.getElementById(forId);
            if (!ctrl) ctrl = this.querySelector('input, select, textarea');
            if (ctrl) {
              var ctype = (ctrl.type || '').toLowerCase();
              if (ctype === 'checkbox' || ctype === 'radio') ctrl.click();
            }
            return;
          }
          if (!form) {
            this.click();
            // Lightpanda doesn't toggle <details> when its <summary> is clicked.
            // Walk up to the nearest <details> (only if click hit a summary
            // and we haven't been preventDefault'd by user JS) and flip `open`.
            if (tag === 'summary') {
              var d = this.parentNode;
              while (d && d.nodeType === 1 && d.tagName.toLowerCase() !== 'details') {
                d = d.parentNode;
              }
              if (d && d.tagName && d.tagName.toLowerCase() === 'details') {
                d.open = !d.open;
              }
            }
            return;
          }

          // Fire the submit event first so user JS handlers can intercept and
          // preventDefault — but skip this when Turbo is loaded, because Turbo's
          // submit pipeline throws on Lightpanda (and the gem already handles the
          // navigation below). Turbo's link-click pipeline still works fine.
          if (typeof Turbo === 'undefined') {
            var ev;
            if (typeof SubmitEvent === 'function') {
              ev = new SubmitEvent('submit', { bubbles: true, cancelable: true, submitter: this });
            } else {
              ev = new Event('submit', { bubbles: true, cancelable: true });
              ev.submitter = this;
            }
            var allowed = form.dispatchEvent(ev);
            if (!allowed) return;
          }

          // No handler intercepted — fetch + swap ourselves because Lightpanda's
          // native form.submit() does not navigate.
          // Pass the submitter so the button is serialized at its document
          // position alongside the form's other named controls.
          var formData;
          try { formData = new FormData(form, this); }
          catch (e) { formData = new FormData(form); }
          var submitterName = this.getAttribute('name');
          if (submitterName && !formData.has(submitterName)) {
            // Lightpanda's FormData(form, submitter) may omit a <button> with no
            // explicit value attribute; HTML says the value falls back to
            // textContent, so feed that in ourselves when the entry is missing.
            var submitterValue = this.getAttribute('value');
            if (submitterValue === null) {
              submitterValue = (tag === 'button') ? (this.textContent || '') : '';
            }
            formData.append(submitterName, submitterValue);
          }

          var action = this.getAttribute('formaction') || form.getAttribute('action') || window.location.href;
          try { action = new URL(action, window.location.href).href; } catch (e) {}
          var method = (this.getAttribute('formmethod') || form.getAttribute('method') || 'GET').toUpperCase();

          var enctype = (this.getAttribute('formenctype') ||
                         form.getAttribute('enctype') ||
                         'application/x-www-form-urlencoded').toLowerCase();
          // Lightpanda's URLSearchParams.toString() drops the `=` when the value
          // is an empty string (`{key: ""}` serializes as `key`, not `key=`),
          // which makes the server parse the field as nil instead of "". Lightpanda
          // also doesn't perform the HTML-spec LF→CRLF normalization for textarea
          // values during form submission. Build the query string by hand so both
          // round-trip correctly.
          var formEncode = function(fd) {
            var pairs = [];
            for (var entry of fd.entries()) {
              var value = entry[1];
              if (typeof value === 'string') {
                // Normalize line endings to CRLF per HTML form-data set spec.
                value = value.replace(/\\r\\n|\\r|\\n/g, '\\r\\n');
              }
              pairs.push(encodeURIComponent(entry[0]).replace(/%20/g, '+') +
                         '=' +
                         encodeURIComponent(value).replace(/%20/g, '+'));
            }
            return pairs.join('&');
          };
          var opts = { method: method, credentials: 'same-origin', redirect: 'follow' };
          if (method === 'GET') {
            var sep = action.indexOf('?') >= 0 ? '&' : '?';
            action = action + sep + formEncode(formData);
          } else if (enctype === 'multipart/form-data') {
            // Pass FormData directly — fetch sets Content-Type with the correct boundary.
            opts.body = formData;
          } else {
            opts.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
            opts.body = formEncode(formData);
          }

          return fetch(action, opts).then(function(r) {
            return r.text().then(function(html) { return { url: r.url, html: html }; });
          }).then(function(o) {
            var doc = new DOMParser().parseFromString(o.html, 'text/html');
            document.title = (doc.title || '');
            document.body.innerHTML = doc.body.innerHTML;
            try { history.replaceState(null, '', o.url); } catch (e) {}
          });
        }
      JS

      VISIBLE_JS = "function() { return _lightpanda.isVisible(this); }"

      VISIBLE_TEXT_JS = "function() { return _lightpanda.visibleText(this); }"

      PROPERTY_OR_ATTRIBUTE_JS = <<~JS
        function(name) {
          var tag = this.tagName.toLowerCase();
          if ((tag === 'img' && name === 'src') ||
              (tag === 'a' && name === 'href') ||
              (tag === 'link' && name === 'href') ||
              (tag === 'script' && name === 'src') ||
              (tag === 'form' && name === 'action')) {
            if (this.hasAttribute(name)) return this[name];
            return null;
          }
          // Boolean attributes: the static `checked`/`selected`/etc.
          // attribute reflects only the default (form-reset) state.
          // The live property tracks the current state, which is what
          // Capybara's `node['checked']` etc. semantics need.
          var BOOL_PROP = { checked: 'checked', selected: 'selected',
                            disabled: 'disabled', multiple: 'multiple',
                            readonly: 'readOnly', hidden: 'hidden',
                            autofocus: 'autofocus', required: 'required' };
          var prop = BOOL_PROP[name.toLowerCase()];
          if (prop && this[prop] !== undefined) return this[prop];
          return this.getAttribute(name);
        }
      JS

      GET_VALUE_JS = <<~JS
        function() {
          if (this.tagName === 'SELECT' && this.multiple) {
            return Array.from(this.selectedOptions).map(function(o) { return o.value });
          }
          return this.value;
        }
      JS

      SET_VALUE_JS = <<~JS
        function(value) {
          if (this.readOnly || this.hasAttribute('readonly')) return;
          this.focus();
          this.value = value;
          this.dispatchEvent(new Event('input', {bubbles: true}));
          this.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      # HTML implicit-submission: when the user presses Enter in a text-like
      # field, the form is submitted if either (a) there's a default submit
      # button, or (b) the form has exactly one submittable text control.
      # `this` is the input. Mirror CLICK_JS's submit pipeline so the gem's
      # fetch+swap path runs (Lightpanda's form.submit() doesn't navigate).
      IMPLICIT_SUBMIT_JS = <<~JS
        function() {
          var form = this.form;
          if (!form) return;
          var hasDefault = !!form.querySelector(
            'button[type=submit], button:not([type]), input[type=submit], input[type=image]'
          );
          if (!hasDefault) {
            var textInputs = form.querySelectorAll(
              'input[type=text], input[type=email], input[type=password], ' +
              'input[type=url], input[type=tel], input[type=search], ' +
              'input[type=number], input:not([type])'
            );
            if (textInputs.length !== 1) return;
          }

          if (typeof Turbo === 'undefined') {
            var ev;
            if (typeof SubmitEvent === 'function') {
              ev = new SubmitEvent('submit', { bubbles: true, cancelable: true });
            } else {
              ev = new Event('submit', { bubbles: true, cancelable: true });
            }
            var allowed = form.dispatchEvent(ev);
            if (!allowed) return;
          }

          var formData = new FormData(form);
          var action = form.getAttribute('action') || window.location.href;
          try { action = new URL(action, window.location.href).href; } catch (e) {}
          var method = (form.getAttribute('method') || 'GET').toUpperCase();
          var enctype = (form.getAttribute('enctype') || 'application/x-www-form-urlencoded').toLowerCase();

          var formEncode = function(fd) {
            var pairs = [];
            for (var entry of fd.entries()) {
              var value = entry[1];
              if (typeof value === 'string') {
                value = value.replace(/\\r\\n|\\r|\\n/g, '\\r\\n');
              }
              pairs.push(encodeURIComponent(entry[0]).replace(/%20/g, '+') +
                         '=' +
                         encodeURIComponent(value).replace(/%20/g, '+'));
            }
            return pairs.join('&');
          };

          var opts = { method: method, credentials: 'same-origin', redirect: 'follow' };
          if (method === 'GET') {
            var sep = action.indexOf('?') >= 0 ? '&' : '?';
            action = action + sep + formEncode(formData);
          } else if (enctype === 'multipart/form-data') {
            opts.body = formData;
          } else {
            opts.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
            opts.body = formEncode(formData);
          }

          return fetch(action, opts).then(function(r) {
            return r.text().then(function(html) { return { url: r.url, html: html }; });
          }).then(function(o) {
            var doc = new DOMParser().parseFromString(o.html, 'text/html');
            document.title = (doc.title || '');
            document.body.innerHTML = doc.body.innerHTML;
            try { history.replaceState(null, '', o.url); } catch (e) {}
          });
        }
      JS

      SELECT_OPTION_JS = <<~JS
        function() {
          var sel = this.parentElement;
          while (sel && (sel.tagName || '').toUpperCase() !== 'SELECT') sel = sel.parentElement;
          if (!sel) {
            // Datalist options don't live inside a <select>; toggling
            // `selected` is meaningless. The matching <input list=...>
            // is what should receive the value, but Capybara handles
            // that path itself; just no-op here.
            return;
          }
          if (sel.multiple) {
            this.selected = true;
          } else {
            // Lightpanda doesn't auto-deselect siblings when we set
            // `option.selected`, so mirror what a real browser does and
            // route the change through the parent's `value`.
            sel.value = this.value;
          }
          sel.dispatchEvent(new Event('input', {bubbles: true}));
          sel.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      UNSELECT_OPTION_JS = <<~JS
        function() {
          var sel = this.parentElement;
          while (sel && (sel.tagName || '').toUpperCase() !== 'SELECT') sel = sel.parentElement;
          if (!sel || !sel.multiple) return;
          this.selected = false;
          sel.dispatchEvent(new Event('input', {bubbles: true}));
          sel.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      SET_CHECKBOX_JS = <<~JS
        function(value) {
          // Use `click()` so user-installed click/change handlers fire and
          // observe a real toggle. No-op if already in the requested state.
          if (this.checked !== value) this.click();
        }
      JS

      APPEND_KEYS_JS = <<~JS
        function(key) {
          this.focus();
          this.value += key;
          this.dispatchEvent(new Event('input', {bubbles: true}));
        }
      JS

      EDITABLE_HOST_JS = "function() { return _lightpanda.isContentEditable(this); }"

      DISABLED_JS = "function() { return _lightpanda.isDisabled(this); }"

      GET_STYLE_JS = <<~JS
        function(prop) {
          var win = this.ownerDocument.defaultView || window;
          return win.getComputedStyle(this)[prop];
        }
      JS

      GET_RECT_JS = <<~JS
        function() {
          var r = this.getBoundingClientRect();
          return {
            x: r.x, y: r.y,
            top: r.top, bottom: r.bottom, left: r.left, right: r.right,
            width: r.width, height: r.height
          };
        }
      JS

      OBSCURED_JS = "function() { return _lightpanda.isObscured(this); }"

      GET_PATH_JS = <<~JS
        function() {
          var el = this;
          var path = [];
          while (el && el.nodeType === Node.ELEMENT_NODE) {
            var selector = el.nodeName.toLowerCase();
            if (el.id) {
              selector += '#' + el.id;
              path.unshift(selector);
              break;
            } else {
              var sibling = el;
              var nth = 1;
              while (sibling = sibling.previousElementSibling) {
                if (sibling.nodeName.toLowerCase() === el.nodeName.toLowerCase()) nth++;
              }
              if (nth > 1) selector += ':nth-of-type(' + nth + ')';
            }
            path.unshift(selector);
            el = el.parentNode;
          }
          return path.join(' > ');
        }
      JS
    end
  end
end
