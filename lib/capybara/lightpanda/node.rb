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

      def visible_text
        call("function() { return this.innerText }")
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

      def ==(other)
        other.is_a?(self.class) && remote_object_id == other.remote_object_id
      end

      private

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

      # Turbo-compatible click. When Turbo is loaded and a submit button is clicked,
      # bypasses Turbo's fetch-based form submission (which fails in Lightpanda) by
      # using fetch() + document.write() to POST the form and render the response.
      # When Turbo is not loaded, uses requestSubmit() to fire the submit event.
      # For non-submit elements, falls back to standard HTMLElement.click().
      CLICK_JS = <<~JS
        function() {
          var tag = this.tagName.toLowerCase();
          var type = (this.type || '').toLowerCase();
          var isSubmitBtn = ((tag === 'input' || tag === 'button') && type === 'submit') ||
                            (tag === 'input' && type === 'image');

          if (isSubmitBtn) {
            var form = this.form;
            if (!form) { this.click(); return; }

            if (typeof Turbo !== 'undefined') {
              var formData = new FormData(form);
              var submitterName = this.getAttribute('name');
              if (submitterName) formData.append(submitterName, this.getAttribute('value') || '');

              var action = this.getAttribute('formaction') || form.getAttribute('action') || window.location.href;
              try { action = new URL(action, window.location.href).href; } catch(e) {}
              var method = (this.getAttribute('formmethod') || form.getAttribute('method') || 'GET').toUpperCase();

              var opts = { method: method, credentials: 'same-origin', redirect: 'follow' };
              if (method === 'GET') {
                var sep = action.indexOf('?') >= 0 ? '&' : '?';
                action = action + sep + new URLSearchParams(formData).toString();
              } else {
                opts.headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
                opts.body = new URLSearchParams(formData);
              }

              return fetch(action, opts).then(function(r) { return r.text(); }).then(function(html) {
                document.open(); document.write(html); document.close();
              });
            }

            if (typeof form.requestSubmit === 'function') {
              form.requestSubmit(this);
              return;
            }
          }

          this.click();
        }
      JS

      VISIBLE_JS = <<~JS
        function() {
          var tag = this.tagName;
          if (tag === 'HEAD' || tag === 'head') return false;
          var win = this.ownerDocument.defaultView || window;
          var style = win.getComputedStyle(this);
          if (style.display === 'none') return false;
          if (style.visibility === 'hidden' || style.visibility === 'collapse') return false;
          if (this.offsetParent === null && style.position !== 'fixed' &&
              tag !== 'BODY' && tag !== 'HTML' && tag !== 'body' && tag !== 'html') return false;
          return true;
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
