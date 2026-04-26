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
        result = Utils.with_retry(errors: [NoExecutionContextError], max: 3, wait: 0.1) do
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
          else
            call(SET_VALUE_JS, value.to_s)
          end
        elsif tag == "textarea"
          call(SET_VALUE_JS, value.to_s)
        elsif self["contenteditable"]
          call("function(v) { this.innerHTML = v }", value.to_s)
        end
      end

      def select_option
        call(SELECT_OPTION_JS)
      end

      def unselect_option
        call(UNSELECT_OPTION_JS)
      end

      def send_keys(*)
        call("function() { this.focus() }")
        driver.browser.keyboard.type(*)
      end

      def tag_name
        call("function() { return this.tagName.toLowerCase() }")
      end

      def visible?
        call(VISIBLE_JS)
      end

      def checked?
        call("function() { return this.checked }")
      end

      def selected?
        call("function() { return this.selected }")
      end

      def disabled?
        call("function() { return this.disabled }")
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

      # Equality must compare the underlying DOM node, not the (transient) remote_object_id.
      # The same DOM element receives a new objectId on each Runtime call, so a fast path
      # on string equality is just a shortcut — falls back to backendNodeId resolution
      # (stable per page) when the strings differ.
      def ==(other)
        return false unless other.is_a?(self.class)
        return true if remote_object_id == other.remote_object_id

        backend_node_id == other.backend_node_id
      end

      alias eql? ==

      def hash
        backend_node_id.hash
      end

      def backend_node_id
        @backend_node_id ||= driver.browser.backend_node_id(@remote_object_id)
      end

      private

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
        Utils.with_retry(errors: [NoExecutionContextError], max: 3, wait: 0.1) do
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
          var isSubmitBtn = ((tag === 'input' || tag === 'button') && type === 'submit') ||
                            (tag === 'input' && type === 'image');
          var form = isSubmitBtn ? this.form : null;
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
          var formData = new FormData(form);
          var submitterName = this.getAttribute('name');
          if (submitterName) formData.append(submitterName, this.getAttribute('value') || '');

          var action = this.getAttribute('formaction') || form.getAttribute('action') || window.location.href;
          try { action = new URL(action, window.location.href).href; } catch (e) {}
          var method = (this.getAttribute('formmethod') || form.getAttribute('method') || 'GET').toUpperCase();

          var opts = { method: method, credentials: 'same-origin', redirect: 'follow' };
          if (method === 'GET') {
            var sep = action.indexOf('?') >= 0 ? '&' : '?';
            action = action + sep + new URLSearchParams(formData).toString();
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
          this.focus();
          this.value = value;
          this.dispatchEvent(new Event('input', {bubbles: true}));
          this.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      SELECT_OPTION_JS = <<~JS
        function() {
          this.selected = true;
          if (this.parentElement) {
            this.parentElement.dispatchEvent(new Event('change', {bubbles: true}));
          }
        }
      JS

      UNSELECT_OPTION_JS = <<~JS
        function() {
          this.selected = false;
          if (this.parentElement) {
            this.parentElement.dispatchEvent(new Event('change', {bubbles: true}));
          }
        }
      JS

      SET_CHECKBOX_JS = <<~JS
        function(value) {
          this.checked = value;
          this.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      APPEND_KEYS_JS = <<~JS
        function(key) {
          this.focus();
          this.value += key;
          this.dispatchEvent(new Event('input', {bubbles: true}));
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
