# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Node < ::Capybara::Driver::Node
      MOVING_WAIT_DELAY = ENV.fetch("LIGHTPANDA_NODE_MOVING_WAIT", 0.01).to_f
      MOVING_WAIT_ATTEMPTS = ENV.fetch("LIGHTPANDA_NODE_MOVING_ATTEMPTS", 50).to_i

      attr_reader :remote_object_id

      def initialize(driver, remote_object_id)
        super
        @remote_object_id = remote_object_id
      end

      # Capybara::Driver::Node#native returns the constructor's second argument,
      # which here is the raw CDP objectId — a String. So the Selenium/Cuprite
      # idiom `element.native.send_keys(...)` (solidus's
      # return_authorizations_spec.rb does exactly that) died with
      # "undefined method 'send_keys' for an instance of String". This driver
      # has no lower-level node object behind the Capybara one — the CDP handle
      # IS this Node (see #remote_object_id) — so `native` is self.
      #
      # Safe against Capybara::Driver::Node#==, which compares `native ==
      # other.native` and would recurse forever on a self-returning `native`:
      # #== and #eql? below are full overrides that never call super and never
      # read #native.
      def native
        self
      end

      def text
        call("function() { return this.textContent }")
      end

      def all_text
        filter_text(call("function() { return this.textContent }"))
      end

      # Delegates to _lightpanda.visibleText, which gates on visibility (a
      # not-visible element reads as "" — WebDriver semantics) and otherwise
      # hands the rendered-text collection (block line breaks + display:none
      # descendant skipping) to native innerText (#2785/#2795). We normalize the
      # whitespace here to match Capybara's expected Chrome semantics.
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

      # Returns true when the element's bounding rect has changed between two
      # samples taken `delay` seconds apart. Lightpanda has no real animation
      # frame loop so most "movement" is JS-driven (style mutations); this
      # works because getBoundingClientRect reflects those mutations.
      def moving?(delay: MOVING_WAIT_DELAY)
        previous = rect
        sleep(delay)
        previous != rect
      end

      # Block until the element's rect stabilises across two consecutive
      # samples or `attempts` polls have elapsed (whichever first). Returns
      # the last rect read; never raises. Mirrors ferrum's wait_for_stop_moving
      # but no NodeMovingError because Lightpanda has no rendering loop, so a
      # caller silently proceeding with the last rect is the right default.
      def wait_for_stop_moving(delay: MOVING_WAIT_DELAY, attempts: MOVING_WAIT_ATTEMPTS)
        previous = rect
        attempts.times do
          sleep(delay)
          current = rect
          return current if current == previous

          previous = current
        end
        previous
      end

      # Quiet form of the `isConnected` guard every other operation carries:
      # true while the node is still attached to a live document, false once
      # it has been detached or its document navigated away (mirrors Ferrum's
      # `Node#exists?`, whose probe is `DOM.resolveNode`). Anything else that
      # goes wrong still raises — only "gone" is turned into false.
      def exists?
        call("function() { return true; }")
      rescue ObsoleteNode, NodeNotFoundError, NoExecutionContextError
        false
      end

      # Routed through #call (not a bare call_function_on) so a detached
      # host raises ObsoleteNode like every other node operation — Capybara's
      # automatic_reload then re-finds the host instead of silently reading
      # a stale shadowRoot.
      def shadow_root
        result = call(SHADOW_ROOT_JS, return_by_value: false)
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

      # A real pointer entering an element fires `mouseover` (bubbling) AND
      # `mouseenter` (non-bubbling), in that order. Dispatching only `mouseover`
      # silently no-ops the `mouseenter->menu#open` Stimulus idiom and the
      # Floating UI / tippy-style menus built on it — the dominant hover-menu
      # pattern in Rails apps — so fire both. CSS `:hover` still reveals nothing
      # (upstream tracks no pointer state); test/features/hover_test.rb pins
      # both halves.
      def hover
        call(HOVER_JS)
      end

      # Kept as a deliberate no-op despite upstream now tracking scroll position
      # (`window.scrollTo`/`scrollBy` update `window._scroll_pos`, `Element`
      # exposes `scrollTop`/`scrollLeft` — Window.zig/Element.zig). Wiring it
      # would still misbehave: Lightpanda never clamps to content height
      # (`scrollHeight`/`clientHeight` are a hardcoded 1e8), so `:bottom`/`:center`
      # are meaningless; element scroll is decoupled from window scroll; and with
      # no layout `getBoundingClientRect` isn't scroll-aware, so `scroll_to(el,
      # align:)` can't position anything. So there's nothing meaningful to scroll
      # to. Silently succeed so callers like `session.scroll_to(find('#thing'))`
      # don't crash with NotImplementedError. The `:scroll` capability stays in
      # `capybara_skip`. (Window-position scroll IS reachable for real via
      # `execute_script('window.scrollTo(...)')` if a caller truly needs it.)
      def scroll_to(*); end
      def scroll_by(*); end

      # Dispatch an arbitrary DOM event by name. Mirrors Cuprite's Node#trigger
      # — picks the right Event constructor for known mouse/focus/form names
      # and falls back to a generic Event for everything else (so callers can
      # fire custom events like `node.trigger('lp:custom')`).
      def trigger(event)
        call(TRIGGER_JS, event.to_s)
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

      # Capybara's drag-and-drop API (`Element#drop`). String/Pathname arguments
      # are file paths; Hash arguments are `{ mime_type => data }` string drops.
      # We assemble a `DataTransfer` and fire `dragenter` -> `dragover` -> `drop`
      # on this element, so HTML5 dropzones see the payload via
      # `event.dataTransfer`.
      #
      # Files reach the page the way Cuprite's #316 does it: a hidden
      # `<input type=file>` is attached to this element's document,
      # `DOM.setFileInputFiles` points it at the paths (the browser reads the
      # bytes off disk itself), and the drop JS moves `input.files` into the
      # DataTransfer and removes the input. Previously the bytes were base64'd
      # into the `Runtime.callFunctionOn` message, which capped a drop at
      # ~70 MB under `--cdp-max-message-size` and pinned every byte in Ruby;
      # now the size ceiling is Lightpanda's own file handling. Paths are read
      # on the machine running Lightpanda (local for the spawned process),
      # exactly like `attach_file`.
      #
      # DataTransfer/DataTransferItem/DragEvent landed upstream in PR #2671
      # (build ≥6699) and are guaranteed by the MINIMUM_NIGHTLY_BUILD floor;
      # without them the drop JS raises "DataTransfer is not defined".
      def drop(*args)
        paths, strings = partition_drop_args(args)
        input = paths.empty? ? nil : attach_drop_input(paths)
        call(DROP_JS, input, strings.to_json)
        nil
      end

      # Maps Capybara's documented drop_modifiers aliases onto the DragEvent
      # init keys (`ctrlKey`, `metaKey`, ...). Same table as Cuprite's #315.
      DRAG_MODIFIER_ALIASES = { control: :ctrl, command: :meta, cmd: :meta }.freeze

      # Capybara's `Element#drag_to` — HTML5 half only. HTML5_DRAG_JS replays
      # Capybara's own Selenium HTML5_DRAG_DROP_SCRIPT (the same source
      # Cuprite's drag.js ports): dragstart on the draggable ancestor, then
      # dragenter -> 2x dragover -> dragleave/drop -> dragend, setTimeout-paced,
      # sharing one DataTransfer so `setData` in the page's dragstart handler is
      # readable at drop. Runs through `evaluate_async` (the script signals
      # completion via the appended callback), so the drag has fully played out
      # before this method returns.
      #
      # The legacy path is coordinate-based mouse dragging, which Lightpanda
      # cannot express (no layout to produce coordinates from) — it raises
      # instead of silently no-oping. `html5: nil` auto-detects like Selenium
      # does, via LEGACY_DRAG_CHECK_JS: we dispatch a synthetic mousedown where
      # Selenium presses a real button, then apply the same
      # prevented-or-no-draggable-ancestor test.
      #
      # `steps:`/`scroll:` (Cuprite's legacy-path knobs) are accepted and
      # ignored so suites migrating from cuprite don't ArgumentError.
      def drag_to(other, html5: nil, delay: 0.05, drop_modifiers: [], **)
        keys = Array(drop_modifiers).map { |m| DRAG_MODIFIER_ALIASES.fetch(m.to_sym, m.to_sym).to_s }
        html5 = !call(LEGACY_DRAG_CHECK_JS) if html5.nil?
        unless html5
          raise NotImplementedError,
                "drag_to needs coordinate mouse dispatch for non-HTML5 (legacy) drags, which Lightpanda " \
                "cannot do (no layout). Pass `html5: true` to force HTML5 DragEvent simulation."
        end

        driver.browser.evaluate_async(HTML5_DRAG_JS, self, other, (delay * 1000).to_i, keys)
        nil
      end

      def select_option
        call(SELECT_OPTION_JS)
      end

      def unselect_option
        return unless call(UNSELECT_OPTION_JS) == "not_multiple"

        raise Capybara::UnselectNotAllowed, "Cannot unselect option from single select box."
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

      # Ancestor chain from `parentNode` up to (but not including) `document`,
      # returned as Lightpanda::Node wrappers. Mirrors Cuprite's `Node#parents`.
      def parents
        oids = driver.browser.parents_of(@remote_object_id)
        oids.map { |oid| self.class.new(driver, oid) }
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
      rescue BrowserError
        nil
      end

      private

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
          # DOM.setFileInputFiles (PR #2635, build ≥6625) sets input.files +
          # fires change; multipart form submission carries the bytes upstream
          # (PR #2654, build ≥6672, webapi/net/FormData.zig). Both halves are in
          # the floor, so attach_file uploads end-to-end. `value` is a path
          # String or Array<String> (multiple: true); cast each element so a
          # Pathname / non-string locator still serializes over CDP.
          driver.browser.set_file_input_files(@remote_object_id, Array(value).map(&:to_s))
        when "date"
          call(SET_VALUE_JS, format_date_value(value))
        when "time"
          call(SET_VALUE_JS, format_time_value(value))
        when "datetime-local"
          call(SET_VALUE_JS, format_datetime_value(value))
        when "month"
          call(SET_VALUE_JS, format_month_value(value))
        when "week"
          call(SET_VALUE_JS, format_week_value(value))
        else
          fill_text_input(type, value.to_s)
        end
      end

      # HTML implicit-submission: a trailing \n in a text-like input is like the
      # user pressing Enter — submits the form when there's a default submit
      # button OR exactly one text control. Strip the \n, set the value, then
      # trigger submission via IMPLICIT_SUBMIT_JS.
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

      def format_month_value(value)
        return value.to_s if value.is_a?(String) || !value.respond_to?(:to_date)

        value.to_date.strftime("%Y-%m")
      end

      # ISO 8601 week-of-year, "%G" giving the ISO week-numbering year so that
      # the last days of December that belong to week 1 of the next year are
      # rendered with the correct year. Matches Cuprite's `Node#set` for week
      # inputs and what the user would type into a `<input type=week>` field.
      def format_week_value(value)
        return value.to_s if value.is_a?(String) || !value.respond_to?(:to_date)

        value.to_date.strftime("%G-W%V")
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

      # Split `drop` arguments into file descriptors and string-data descriptors.
      # Strings/Pathnames (Capybara normalizes `#to_path`) are file paths, read
      # here and base64-encoded so binary content survives the JSON hop; Hashes
      # are `{ type => data }` string drops. Returns `[files, strings]`.
      def partition_drop_args(args)
        paths = []
        strings = []
        args.each do |arg|
          if arg.is_a?(Hash)
            arg.each { |type, data| strings << { type: type.to_s, data: data.to_s } }
          else
            paths << File.expand_path(arg.to_s)
          end
        end
        [paths, strings]
      end

      # Hidden `<input type=file multiple>` in this element's own document (so
      # drops inside an iframe stay in that frame's DOM), pre-loaded via
      # DOM.setFileInputFiles. Returned as a Node so it can be bound as a
      # callFunctionOn argument; DROP_JS removes it once the files are moved.
      def attach_drop_input(paths)
        oid = call(CREATE_DROP_INPUT_JS, return_by_value: false)["objectId"]
        driver.browser.set_file_input_files(oid, paths)
        self.class.new(driver, oid)
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
      #
      # The supplied declaration is wrapped with an `isConnected` guard so a
      # detached node raises ObsoleteNode (in Driver#invalid_element_errors)
      # instead of returning stale data from V8's still-live reference. After
      # a DOM mutation like `replaceWith`, the cached objectId still resolves
      # to the detached node, so reads succeed quietly and Capybara's
      # automatic_reload never re-runs the original query.
      def call(function_declaration, *args, return_by_value: true)
        guarded = wrap_with_attached_guard(function_declaration)
        driver.browser.with_default_context_wait do
          driver.browser.call_function_on(@remote_object_id, guarded, *args,
                                          return_by_value: return_by_value)
        end
      rescue JavaScriptError => e
        if e.message.include?(OBSOLETE_NODE_MARKER)
          raise ObsoleteNode.new(self, "Node is no longer attached to the document")
        end

        raise
      end

      OBSOLETE_NODE_MARKER = "LIGHTPANDA_OBSOLETE_NODE"
      private_constant :OBSOLETE_NODE_MARKER

      def wrap_with_attached_guard(function_declaration)
        <<~JS
          function() {
            if (!this.isConnected) throw new Error(#{OBSOLETE_NODE_MARKER.inspect});
            return (#{function_declaration}).apply(this, arguments);
          }
        JS
      end

      # `mouseenter` carries `bubbles: false` per spec — it is dispatched on the
      # target only, not walked up the ancestor chain the way a real pointer
      # would. That covers the handler-on-the-hovered-element case (every
      # Stimulus `mouseenter->` action) and stops short of emulating pointer
      # geometry we don't have.
      HOVER_JS = <<~JS
        function() {
          this.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, cancelable: true}));
          this.dispatchEvent(new MouseEvent('mouseenter', {bubbles: false, cancelable: true}));
        }
      JS

      # We dispatch a `MouseEvent` (not a generic `Event`) because Turbo's link
      # and form interceptors guard with `event instanceof MouseEvent` before
      # they consider intercepting — a synthetic `Event('click')` is silently
      # ignored by Turbo Frame / Drive, and CLICK_JS would then fall through to
      # the manual default action below, which does a full-page navigation
      # instead of a frame swap.
      #
      # Submit buttons (`<input type=submit>`, `<input type=image>`,
      # `<button type=submit>`): native click on the dispatched MouseEvent
      # already runs the form-submission default action via Frame.submitForm
      # in Lightpanda (extension of PR #2312 for image to all submit
      # variants). A manual `form.requestSubmit(this)` here would fire a
      # second SubmitEvent and double-submit the form — observed on nightly
      # 6167 as duplicate `turbo:submit-start` events; the first request
      # gets aborted by the second and Turbo never renders the response.
      CLICK_JS = <<~JS
        function() {
          var EventCtor = (typeof MouseEvent !== 'undefined') ? MouseEvent : Event;
          // Emulate coordinate hit-testing without a layout engine. In a real
          // browser a pointer click on a container lands on its frontmost
          // descendant: THAT element is the event target, and the sequence
          // bubbles UP from there (so the container's own handlers still fire).
          // Lightpanda has no geometry — every rect is a hardcoded ~5x5, so
          // document.elementFromPoint(center) just returns the container — so
          // when `this` is a plain non-interactive wrapper we walk DOWN to the
          // first visible child, repeatedly, stopping at the first element that
          // is itself interactive or carries a click handler (onclick /
          // role=button). That lands on the element a centered pointer would
          // hit, so widgets that bind their handlers on an inner node fire:
          // select2 v3 binds its open handler on the inner .select2-choice
          // (single, mousedown) / .select2-choices (multi, click), the FIRST
          // child of the .select2-container that Capybara helpers click. We
          // can't use "single visible child" as a guard — select2 keeps an
          // offscreen .select2-focusser <input> sibling that has no geometry to
          // distinguish, so it reads as a second visible child. The descent
          // never starts from an interactive element, so a normal
          // button/link/input click still lands exactly on `this`.
          var INTERACTIVE = { A: 1, BUTTON: 1, INPUT: 1, SELECT: 1, TEXTAREA: 1,
                              OPTION: 1, LABEL: 1, SUMMARY: 1 };
          var hit = this;
          while (!INTERACTIVE[hit.tagName] &&
                 !hit.hasAttribute('onclick') &&
                 hit.getAttribute('role') !== 'button') {
            var next = null, ch = hit.children;
            for (var i = 0; i < ch.length; i++) {
              if (!window._lightpanda || _lightpanda.isVisible(ch[i])) { next = ch[i]; break; }
            }
            if (!next) break;
            hit = next;
          }
          // Real pointer clicks are a mousedown -> mouseup -> click sequence,
          // and widgets like select2 open on `mousedown`, not `click`.
          // Cancelling mousedown suppresses focus/text-selection in a real
          // browser but never the click, so the click below is dispatched
          // unconditionally.
          hit.dispatchEvent(new EventCtor('mousedown', { bubbles: true, cancelable: true }));
          hit.dispatchEvent(new EventCtor('mouseup', { bubbles: true, cancelable: true }));
          var clickEvt = new EventCtor('click', { bubbles: true, cancelable: true });
          var notCancelled = hit.dispatchEvent(clickEvt);
          if (!notCancelled || clickEvt.defaultPrevented) return;
          var tag = hit.tagName;
          if (tag === 'A' && hit.href && hit.target !== '_blank') {
            // Same-document fragment-only navigation: just update hash (or do
            // nothing if identical). Mirrors Chrome — assigning location.href
            // to a same-document URL on Lightpanda triggers a real navigation
            // tick that cancels pending setTimeout callbacks and clears form
            // values, which breaks any test driving DOM updates from a click
            // handler on `<a href="#...">`.
            var dest = new URL(hit.href, document.baseURI);
            var here = new URL(window.location.href);
            if (dest.origin === here.origin && dest.pathname === here.pathname &&
                dest.search === here.search) {
              if (dest.hash !== here.hash) {
                window.location.hash = dest.hash;
              }
            } else {
              window.location.href = hit.href;
            }
          }
        }
      JS

      # Mirrors Cuprite's trigger map. Picks the right Event constructor based
      # on the event name so listeners that key on `event instanceof MouseEvent`
      # / `instanceof SubmitEvent` see what they expect; everything else goes
      # through a generic Event so custom names ("turbo:load", "lp:custom")
      # still dispatch. Each constructor is feature-detected (`typeof X !==
      # 'undefined'`) before use so a missing IDL on Lightpanda falls back
      # to plain Event rather than throwing.
      TRIGGER_JS = <<~JS
        function(name) {
          var MOUSE = ['click','dblclick','mousedown','mouseenter','mouseleave',
                       'mousemove','mouseover','mouseout','mouseup','contextmenu'];
          var FOCUS = ['blur','focus','focusin','focusout'];
          var init = { bubbles: true, cancelable: true };
          var event;
          if (MOUSE.indexOf(name) !== -1 && typeof MouseEvent !== 'undefined') {
            event = new MouseEvent(name, init);
          } else if (FOCUS.indexOf(name) !== -1 && typeof FocusEvent !== 'undefined') {
            event = new FocusEvent(name, init);
          } else if (name === 'submit' && typeof SubmitEvent !== 'undefined') {
            event = new SubmitEvent(name, init);
          } else {
            event = new Event(name, init);
          }
          this.dispatchEvent(event);
        }
      JS

      CREATE_DROP_INPUT_JS = <<~JS
        function() {
          var doc = this.ownerDocument || document;
          var input = doc.createElement('input');
          input.type = 'file';
          input.multiple = true;
          input.style.display = 'none';
          input.setAttribute('data-lightpanda-drop-input', '');
          (doc.body || doc.documentElement).appendChild(input);
          return input;
        }
      JS

      # Build a DataTransfer from the pre-loaded hidden input (files) and the
      # JSON string payloads (typed items), then replay the HTML5 drop sequence
      # on this element. The input is removed once its files are moved.
      DROP_JS = <<~JS
        function(input, stringsJson) {
          var el = this;
          var dt = new DataTransfer();
          if (input) {
            for (var i = 0; i < input.files.length; i++) dt.items.add(input.files[i]);
            input.remove();
          }
          JSON.parse(stringsJson).forEach(function(s) {
            dt.items.add(s.data, s.type);
          });
          ['dragenter', 'dragover', 'drop'].forEach(function(name) {
            el.dispatchEvent(new DragEvent(name, { bubbles: true, cancelable: true, dataTransfer: dt }));
          });
        }
      JS

      # Selenium's MOUSEDOWN_TRACKER + LEGACY_DRAG_CHECK folded into one round
      # trip. Selenium presses a real mouse button before checking; we dispatch
      # a synthetic mousedown so drag libraries that preventDefault on it
      # (mouse-based / fallback DnD) still steer the check toward the legacy
      # path. Returns true when the drag would need the legacy (coordinate)
      # path: mousedown prevented / never observed, or no draggable ancestor.
      LEGACY_DRAG_CHECK_JS = <<~JS
        function() {
          var doc = this.ownerDocument || document;
          var prevented = null;
          doc.addEventListener('mousedown', function(ev) { prevented = ev.defaultPrevented; }, { once: true });
          this.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
          if (prevented === true || prevented === null) return true;
          var el = this;
          do {
            if (_lightpanda.isDraggable(el)) return false;
          } while ((el = el.parentElement));
          return true;
        }
      JS

      # Ported near-verbatim from Capybara's Selenium driver
      # (capybara/selenium/extensions/html5_drag.rb, HTML5_DRAG_DROP_SCRIPT) —
      # the same source Cuprite's #315 drag.js ports — kept close to ease
      # future syncs. Upstream quirks preserved deliberately: `rectPt.top` in
      # pointOnRect (DOMPoint has no .top, that branch just falls through), the
      # undeclared `key` loop variable, and `callback.call(true)`. One
      # deliberate deviation: `source.draggable` reads go through
      # `_lightpanda.isDraggable` — Lightpanda doesn't implement the IDL
      # property (see predicates.js). Coordinates come from
      # getBoundingClientRect, which Lightpanda synthesizes without layout —
      # dropzones reading clientX/Y get plausible-but-synthetic numbers.
      HTML5_DRAG_JS = <<~JS
        function rectCenter(rect){
          return new DOMPoint(
            (rect.left + rect.right)/2,
            (rect.top + rect.bottom)/2
          );
        }

        function pointOnRect(pt, rect) {
          var rectPt = rectCenter(rect);
          var slope = (rectPt.y - pt.y) / (rectPt.x - pt.x);

          if (pt.x <= rectPt.x) { // left side
            var minXy = slope * (rect.left - pt.x) + pt.y;
            if (rect.top <= minXy && minXy <= rect.bottom)
              return new DOMPoint(rect.left, minXy);
          }

          if (pt.x >= rectPt.x) { // right side
            var maxXy = slope * (rect.right - pt.x) + pt.y;
            if (rect.top <= maxXy && maxXy <= rect.bottom)
              return new DOMPoint(rect.right, maxXy);
          }

          if (pt.y <= rectPt.y) { // top side
            var minYx = (rectPt.top - pt.y) / slope + pt.x;
            if (rect.left <= minYx && minYx <= rect.right)
              return new DOMPoint(minYx, rect.top);
          }

          if (pt.y >= rectPt.y) { // bottom side
            var maxYx = (rect.bottom - pt.y) / slope + pt.x;
            if (rect.left <= maxYx && maxYx <= rect.right)
              return new DOMPoint(maxYx, rect.bottom);
          }

          return new DOMPoint(pt.x,pt.y);
        }

        function dragEnterTarget() {
          target.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'});
          var targetRect = target.getBoundingClientRect();
          var sourceCenter = rectCenter(source.getBoundingClientRect());

          for (var i = 0; i < drop_modifier_keys.length; i++) {
            key = drop_modifier_keys[i];
            if (key == "control"){
              key = "ctrl"
            }
            opts[key + 'Key'] = true;
          }

          var dragEnterEvent = new DragEvent('dragenter', opts);
          target.dispatchEvent(dragEnterEvent);

          // fire 2 dragover events to simulate dragging with a direction
          var entryPoint = pointOnRect(sourceCenter, targetRect)
          var dragOverOpts = Object.assign({clientX: entryPoint.x, clientY: entryPoint.y}, opts);
          var dragOverEvent = new DragEvent('dragover', dragOverOpts);
          target.dispatchEvent(dragOverEvent);
          window.setTimeout(dragOnTarget, step_delay);
        }

        function dragOnTarget() {
          var targetCenter = rectCenter(target.getBoundingClientRect());
          var dragOverOpts = Object.assign({clientX: targetCenter.x, clientY: targetCenter.y}, opts);
          var dragOverEvent = new DragEvent('dragover', dragOverOpts);
          target.dispatchEvent(dragOverEvent);
          window.setTimeout(dragLeave, step_delay, dragOverEvent.defaultPrevented, dragOverOpts);
        }

        function dragLeave(drop, dragOverOpts) {
          var dragLeaveOptions = Object.assign({}, opts, dragOverOpts);
          var dragLeaveEvent = new DragEvent('dragleave', dragLeaveOptions);
          target.dispatchEvent(dragLeaveEvent);
          if (drop) {
            var dropEvent = new DragEvent('drop', dragLeaveOptions);
            target.dispatchEvent(dropEvent);
          }
          var dragEndEvent = new DragEvent('dragend', dragLeaveOptions);
          source.dispatchEvent(dragEndEvent);
          callback.call(true);
        }

        var source = arguments[0],
            target = arguments[1],
            step_delay = arguments[2],
            drop_modifier_keys = arguments[3],
            callback = arguments[4];

        var dt = new DataTransfer();
        var opts = { cancelable: true, bubbles: true, dataTransfer: dt };

        while (source && !_lightpanda.isDraggable(source)) {
          source = source.parentElement;
        }

        if (source.tagName == 'A'){
          dt.setData('text/uri-list', source.href);
          dt.setData('text', source.href);
        }
        if (source.tagName == 'IMG'){
          dt.setData('text/uri-list', source.src);
          dt.setData('text', source.src);
        }

        var dragEvent = new DragEvent('dragstart', opts);
        source.dispatchEvent(dragEvent);

        window.setTimeout(dragEnterTarget, step_delay);
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
          if (this.hasAttribute(name)) return this.getAttribute(name);
          // Property-only fallback: things like `validationMessage` have no
          // backing HTML attribute. Return primitives only — DOM-node properties
          // (form, options, etc.) shouldn't leak through.
          var live = this[name];
          if (live === null || live === undefined) return null;
          var t = typeof live;
          return (t === 'string' || t === 'number' || t === 'boolean') ? live : null;
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

      # HTML implicit-submission: a trailing \n in a text-like input acts like
      # pressing Enter — submits the form if it has a default submit button OR
      # exactly one submittable text control. Click the default button (so
      # click handlers fire) or fall back to `form.requestSubmit()` so the
      # `submit` event still dispatches.
      IMPLICIT_SUBMIT_JS = <<~JS
        function() {
          var form = this.form;
          if (!form) return;
          var btn = form.querySelector(
            'button[type=submit], button:not([type]), input[type=submit], input[type=image]'
          );
          if (btn) { btn.click(); return; }
          var textInputs = form.querySelectorAll(
            'input[type=text], input[type=email], input[type=password], ' +
            'input[type=url], input[type=tel], input[type=search], ' +
            'input[type=number], input:not([type])'
          );
          if (textInputs.length === 1) form.requestSubmit();
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

      # Returns 'not_multiple' (without mutating) when the owning <select>
      # isn't multiple — Ruby raises Capybara::UnselectNotAllowed. One CDP
      # round-trip instead of a separate ancestor-walk precheck.
      UNSELECT_OPTION_JS = <<~JS
        function() {
          var sel = this.parentElement;
          while (sel && (sel.tagName || '').toUpperCase() !== 'SELECT') sel = sel.parentElement;
          if (!sel || !sel.multiple) return 'not_multiple';
          this.selected = false;
          sel.dispatchEvent(new Event('input', {bubbles: true}));
          sel.dispatchEvent(new Event('change', {bubbles: true}));
        }
      JS

      SET_CHECKBOX_JS = <<~JS
        function(value) {
          if (this.checked !== value) this.click();
        }
      JS

      SHADOW_ROOT_JS = "function() { return this.shadowRoot }"

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

      # Capybara's contract for Element#path is an XPath that re-finds the very
      # same node (`node #path returns xpath which points to itself`), so this
      # emits `/HTML/BODY/DIV[2]/P[1]` rather than the CSS-ish
      # `html > body > div:nth-of-type(2) > p` it used to. Chrome exposes no
      # native equivalent either; Cuprite hand-rolls the same walk.
      #
      # Every step is indexed, including single children: `P[1]` and `P` select
      # the same node, but the explicit index keeps the output stable if a
      # sibling appears later, and it is what Chrome DevTools' "Copy XPath"
      # produces. Positions count same-tag preceding siblings, which is exactly
      # XPath's own positional semantics.
      #
      # No `id`-based shortcut: an `//*[@id="x"]` prefix is shorter but stops
      # pointing at *this* node the moment the document has a duplicate id,
      # which malformed real-world pages routinely do.
      #
      # An element inside a shadow root has no document-level XPath at all
      # (XPath doesn't cross shadow boundaries, and a `/SPAN[1]` computed from
      # the shadow tree would re-find some unrelated light-DOM node). Selenium's
      # driver returns the sentinel string below in that case and Capybara's
      # shared `node #path` spec pins it, so mirror it rather than emit a path
      # that lies.
      GET_PATH_JS = <<~JS
        function() {
          var el = this;
          if (el.getRootNode && typeof ShadowRoot !== 'undefined' && el.getRootNode() instanceof ShadowRoot) {
            return '(: Shadow DOM element - no XPath :)';
          }
          var steps = [];
          while (el && el.nodeType === Node.ELEMENT_NODE) {
            var name = el.nodeName.toUpperCase();
            var index = 1;
            var sibling = el;
            while (sibling = sibling.previousElementSibling) {
              if (sibling.nodeName.toUpperCase() === name) index++;
            }
            steps.unshift(name + '[' + index + ']');
            el = el.parentElement;
          }
          return '/' + steps.join('/');
        }
      JS

      # Internal wire format, not API — aligned with browser.rb's convention
      # of private_constant for its JS snippets.
      private_constant :CLICK_JS, :TRIGGER_JS, :DROP_JS, :CREATE_DROP_INPUT_JS, :SHADOW_ROOT_JS, :VISIBLE_JS,
                       :VISIBLE_TEXT_JS,
                       :PROPERTY_OR_ATTRIBUTE_JS, :GET_VALUE_JS, :SET_VALUE_JS,
                       :IMPLICIT_SUBMIT_JS, :SELECT_OPTION_JS, :UNSELECT_OPTION_JS,
                       :SET_CHECKBOX_JS, :EDITABLE_HOST_JS, :DISABLED_JS, :GET_STYLE_JS,
                       :GET_RECT_JS, :OBSCURED_JS, :GET_PATH_JS
    end
  end
end
