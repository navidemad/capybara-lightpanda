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
        call("function() { return this.textContent }")
      end

      def all_text
        filter_text(call("function() { return this.textContent }"))
      end

      # Lightpanda's innerText returns textContent verbatim (no rendering, so no
      # hidden-descendant filtering). Walk descendants ourselves, skipping nodes
      # that fail VISIBLE_JS, and emit newlines around block-display elements
      # (the part of innerText behavior we still need).
      def visible_text
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
        driver.browser.wait_for_turbo
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
        tag = tag_name
        if tag == "input"
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
            call(SET_VALUE_JS, truncate_to_maxlength(value.to_s))
          end
        elsif tag == "textarea"
          call(SET_VALUE_JS, truncate_to_maxlength(value.to_s))
        elsif call(EDITABLE_HOST_JS)
          # `contenteditable` cascades through descendants. Check
          # `isContentEditable`, then fall back to walking ancestors for
          # `contenteditable` since Lightpanda doesn't expose the
          # property on every element.
          call("function(v) { this.innerHTML = v }", value.to_s)
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
        call("function() {
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
      # All JS function declarations are self-contained (no _lightpanda dependency)
      # so they work in any execution context including iframes.
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
          var opts = { method: method, credentials: 'same-origin', redirect: 'follow' };
          if (method === 'GET') {
            var sep = action.indexOf('?') >= 0 ? '&' : '?';
            action = action + sep + new URLSearchParams(formData).toString();
          } else if (enctype === 'multipart/form-data') {
            // Pass FormData directly — fetch sets Content-Type with the correct boundary.
            opts.body = formData;
          } else {
            opts.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
            opts.body = new URLSearchParams(formData);
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

      VISIBLE_JS = <<~JS
        function() {
          var TAG = (this.tagName || '').toUpperCase();
          // Elements that are never rendered, regardless of CSS.
          if (TAG === 'HEAD' || TAG === 'TEMPLATE' || TAG === 'NOSCRIPT' ||
              TAG === 'SCRIPT' || TAG === 'STYLE' || TAG === 'TITLE') return false;
          if (TAG === 'INPUT' && (this.type || '').toLowerCase() === 'hidden') return false;

          // Walk ancestors for cascade-based hiding that getComputedStyle alone misses
          // (Lightpanda-specific: class-rule resolution + special-element rules,
          // plus the HTML `hidden` attribute which checkVisibility does not honor).
          var node = this;
          while (node && node.nodeType === 1) {
            if (node.hasAttribute && node.hasAttribute('hidden')) return false;
            var parent = node.parentNode;
            if (parent && parent.nodeType === 1) {
              var ptag = (parent.tagName || '').toUpperCase();
              if (ptag === 'HEAD' || ptag === 'TEMPLATE' || ptag === 'NOSCRIPT') return false;
              // <details> hides everything but the first <summary> when closed.
              if (ptag === 'DETAILS' && !parent.open) {
                var ntag = (node.tagName || '').toUpperCase();
                if (ntag !== 'SUMMARY') return false;
              }
            }
            node = parent;
          }

          // Lightpanda's checkVisibility() catches display:none from inline styles
          // and class rules (CSSOM PR #1797), but does not honor visibility:hidden
          // — so we always check that explicitly via getComputedStyle.
          var win = this.ownerDocument.defaultView || window;
          var style = win.getComputedStyle(this);
          if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
          if (typeof this.checkVisibility === 'function') {
            return this.checkVisibility();
          }
          if (style.display === 'none') return false;
          if (this.offsetParent === null && style.position !== 'fixed' &&
              TAG !== 'BODY' && TAG !== 'HTML') return false;
          return true;
        }
      JS

      # Walk children and accumulate text from visible nodes only. Inserts
      # newlines around block-display containers so paragraphs/lists render with
      # natural breaks (Capybara expects this from Chrome's innerText).
      VISIBLE_TEXT_JS = <<~JS
        function() {
          var BLOCK = { BLOCK:1, FLEX:1, GRID:1, 'LIST-ITEM':1, TABLE:1, 'TABLE-ROW':1,
                        'TABLE-CAPTION':1, 'TABLE-CELL':1 };
          var BLOCK_TAG = { ADDRESS:1, ARTICLE:1, ASIDE:1, BLOCKQUOTE:1, DETAILS:1, DIALOG:1,
                            DIV:1, DL:1, DT:1, DD:1, FIELDSET:1, FIGCAPTION:1, FIGURE:1,
                            FOOTER:1, FORM:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1, HEADER:1,
                            HGROUP:1, HR:1, LI:1, MAIN:1, NAV:1, OL:1, P:1, PRE:1, SECTION:1,
                            TABLE:1, TR:1, UL:1 };

          function visible(el) {
            var tag = (el.tagName || '').toUpperCase();
            if (tag === 'HEAD' || tag === 'TEMPLATE' || tag === 'NOSCRIPT' ||
                tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TITLE') return false;
            if (tag === 'INPUT' && (el.type || '').toLowerCase() === 'hidden') return false;
            var n = el;
            while (n && n.nodeType === 1) {
              if (n.hasAttribute && n.hasAttribute('hidden')) return false;
              var p = n.parentNode;
              if (p && p.nodeType === 1) {
                var pt = (p.tagName || '').toUpperCase();
                if (pt === 'HEAD' || pt === 'TEMPLATE' || pt === 'NOSCRIPT') return false;
                if (pt === 'DETAILS' && !p.open) {
                  var nt = (n.tagName || '').toUpperCase();
                  if (nt !== 'SUMMARY') return false;
                }
              }
              n = p;
            }
            var win = el.ownerDocument.defaultView || window;
            var style = win.getComputedStyle(el);
            if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
            if (typeof el.checkVisibility === 'function') return el.checkVisibility();
            if (style.display === 'none') return false;
            return true;
          }

          // Collapse runs of ASCII whitespace (preserving NBSP) to a single space —
          // matches Chrome's innerText whitespace handling for text nodes.
          function normText(s) {
            return s.replace(/[\\t\\n\\r\\f\\v ]+/g, ' ');
          }

          function walk(node) {
            if (node.nodeType === 3) return normText(node.nodeValue);
            // DocumentFragment / ShadowRoot — no element of its own to test
            // for visibility, just walk children.
            if (node.nodeType === 11) {
              var fout = '';
              for (var k = 0; k < node.childNodes.length; k++) fout += walk(node.childNodes[k]);
              return fout;
            }
            if (node.nodeType !== 1) return '';
            if (!visible(node)) return '';
            var tag = (node.tagName || '').toUpperCase();
            if (tag === 'TEXTAREA') return node.value || '';
            if (tag === 'BR') return '\\n';
            var win = node.ownerDocument.defaultView || window;
            var style = win.getComputedStyle(node);
            var disp = (style.display || '').toUpperCase();
            var isBlock = BLOCK[disp] || BLOCK_TAG[tag];
            var out = '';
            for (var i = 0; i < node.childNodes.length; i++) {
              out += walk(node.childNodes[i]);
            }
            if (isBlock) out = '\\n' + out + '\\n';
            return out;
          }

          return walk(this);
        }
      JS

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

      EDITABLE_HOST_JS = <<~JS
        function() {
          if (this.isContentEditable) return true;
          var n = this;
          while (n && n.nodeType === 1) {
            if (n.hasAttribute && n.hasAttribute('contenteditable')) {
              var v = (n.getAttribute('contenteditable') || '').toLowerCase();
              return v !== 'false';
            }
            n = n.parentElement;
          }
          return false;
        }
      JS

      # HTML defines a disabled form control as one whose own `disabled`
      # attribute is set OR whose ancestor select/optgroup/fieldset is disabled
      # (with a fieldset-disabled exception for descendants of its first legend).
      # `this.disabled` only reflects the element's own attribute, so we walk
      # up the tree to honor the inherited cases.
      DISABLED_JS = <<~JS
        function() {
          if (this.disabled) return true;
          var tag = (this.tagName || '').toUpperCase();
          if (tag === 'OPTION') {
            var p = this.parentElement;
            while (p && (p.tagName || '').toUpperCase() === 'OPTGROUP') {
              if (p.disabled) return true;
              p = p.parentElement;
            }
            if (p && (p.tagName || '').toUpperCase() === 'SELECT' && p.disabled) return true;
          }
          var FORM = { INPUT:1, BUTTON:1, SELECT:1, TEXTAREA:1, OPTION:1 };
          if (FORM[tag]) {
            var node = this.parentElement;
            while (node) {
              if ((node.tagName || '').toUpperCase() === 'FIELDSET' && node.disabled) {
                var firstLegend = null;
                for (var c = node.firstElementChild; c; c = c.nextElementSibling) {
                  if ((c.tagName || '').toUpperCase() === 'LEGEND') { firstLegend = c; break; }
                }
                if (firstLegend && firstLegend.contains(this)) return false;
                return true;
              }
              node = node.parentElement;
            }
          }
          return false;
        }
      JS

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

      OBSCURED_JS = <<~JS
        function() {
          var doc = this.ownerDocument;
          var win = doc.defaultView || window;
          // An element with display:none, visibility:hidden, or the `hidden`
          // attribute can never be the topmost element at any point —
          // semantically it's obscured. (Lightpanda returns a fake non-zero
          // bounding rect for display:none, so this short-circuit is required.)
          var style = win.getComputedStyle(this);
          if (style.display === 'none') return true;
          if (style.visibility === 'hidden' || style.visibility === 'collapse') return true;
          // `hidden` attribute on self or any ancestor cascades to invisible.
          var anc = this;
          while (anc && anc.nodeType === 1) {
            if (anc.hasAttribute && anc.hasAttribute('hidden')) return true;
            anc = anc.parentNode;
          }
          var r = this.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) return true;
          var cx = r.left + (r.width / 2);
          var cy = r.top + (r.height / 2);
          var w = win.innerWidth || doc.documentElement.clientWidth;
          var h = win.innerHeight || doc.documentElement.clientHeight;
          if (cx < 0 || cy < 0 || cx > w || cy > h) return true;
          var hit = doc.elementFromPoint(cx, cy);
          if (!hit) return true;
          if (hit === this) return false;
          return !this.contains(hit);
        }
      JS

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
