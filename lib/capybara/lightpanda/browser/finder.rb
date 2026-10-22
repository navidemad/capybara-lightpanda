# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # Element finding in the three dispatch contexts (document, node-
      # scoped, iframe) plus the shared XPath/CSS find fragments and
      # InvalidSelector translation.
      module Finder
        # Find elements in the current context (top frame or active frame).
        # Returns an array of remote object ID strings.
        def find(method, selector)
          find_hinted(method, selector).map(&:first)
        end

        # Like #find, but with Capybara's finder hints answered in the same
        # round-trip (see `_lightpanda.findHints`). Returns `[objectId, cache]`
        # pairs; `cache` is {} when `spec` is nil or the page couldn't answer.
        def find_hinted(method, selector, spec = nil)
          if @frame_stack.empty?
            find_in_document(method, selector, spec)
          else
            find_in_frame(method, selector, spec)
          end
        end

        # Find child elements within a specific node.
        # Returns an array of remote object ID strings.
        #
        # Wrapped in `with_default_context_wait` so a click that triggered a
        # navigation immediately before the find (e.g. a fill_in following a
        # link that mutated the DOM) doesn't race against
        # `Runtime.executionContextCreated` and surface as
        # `NoExecutionContextError`. `find_in_document` and `find_in_frame`
        # already use the same wrapper; `find_within` was the odd one out.
        def find_within(remote_object_id, method, selector)
          find_within_hinted(remote_object_id, method, selector).map(&:first)
        end

        def find_within_hinted(remote_object_id, method, selector, spec = nil)
          with_default_context_wait do
            result = call_function_on(remote_object_id, FIND_WITHIN_JS, method, selector, spec,
                                      return_by_value: false)
            extract_hinted_nodes(result)
          end
        rescue JavaScriptError => e
          raise_invalid_selector(e, method, selector)
        end

        # Ancestor chain of `remote_object_id` from parentNode up to (but
        # excluding) `document`, returned as an array of remote object IDs.
        # Same `with_default_context_wait` wrapping as `find_within` — same
        # race window applies.
        def parents_of(remote_object_id)
          with_default_context_wait do
            result = call_function_on(remote_object_id, PARENTS_JS, return_by_value: false)
            extract_hinted_nodes(result).map(&:first)
          end
        end

        private

        # Sentinel string thrown from FIND_*_JS when querySelectorAll rejects a
        # malformed selector, so the Ruby side can convert JavaScriptError into
        # Capybara::Lightpanda::InvalidSelector. A plain prefixed string keeps
        # our inline JS simple.
        INVALID_SELECTOR_MARKER = "LIGHTPANDA_INVALID_SELECTOR:"

        # The find algorithms exist in three dispatch contexts — element-scoped
        # (FIND_WITHIN_JS), iframe-scoped (FIND_IN_FRAME_JS), and document-scoped
        # (find_in_document's Runtime.evaluate fast path) — that differ only in
        # how the document/root/selector expressions are derived. Each algorithm
        # is defined ONCE here and instantiated per context via format(), so a
        # fix (e.g. a new XPath error case) can't silently miss a copy.
        #
        # XPath routes through native `Document.evaluate` + `XPathResult`
        # (Lightpanda PR #2305, in nightly >=6109); on parse error we return
        # [] silently to match Capybara's internal XPath generator, which
        # sometimes produces selectors with empty trailing predicates like
        # `(...)[]` that native rejects but `has_element?` expects to behave
        # as "not found" rather than raise InvalidSelector.
        # `XPathResult.ORDERED_NODE_SNAPSHOT_TYPE` is `7` in the spec — inlined
        # so the JS doesn't depend on the enum being defined as a constant.
        XPATH_FIND_FRAGMENT = <<~JS
          try {
            var r = %<doc>s.evaluate(%<selector>s, %<root>s, null, 7, null);
            var nodes = [];
            for (var i = 0; i < r.snapshotLength; i++) nodes.push(r.snapshotItem(i));
            return nodes;
          } catch(e) { return []; }
        JS

        # For CSS, any throw from querySelectorAll means the selector is
        # malformed — re-throw with the marker prefix so Ruby converts to
        # InvalidSelector.
        CSS_FIND_FRAGMENT = <<~JS.freeze
          try { return Array.from(%<target>s.querySelectorAll(%<selector>s)); }
          catch(e) { throw new Error('#{INVALID_SELECTOR_MARKER}' + %<selector>s); }
        JS
        private_constant :XPATH_FIND_FRAGMENT, :CSS_FIND_FRAGMENT

        # JS function for finding elements within a node.
        # Works in any execution context (top frame or iframe).
        FIND_WITHIN_JS = <<~JS.freeze
          function(method, selector, spec) {
            var self = this;
            var nodes = (function() {
              if (method === 'xpath') {
                #{format(XPATH_FIND_FRAGMENT, doc: 'self.ownerDocument', root: 'self', selector: 'selector')}
              }
              #{format(CSS_FIND_FRAGMENT, target: 'self', selector: 'selector')}
            })();
            return spec ? _lightpanda.findHints(nodes, spec) : nodes;
          }
        JS
        private_constant :FIND_WITHIN_JS

        # JS function for finding elements in an iframe's contentDocument.
        FIND_IN_FRAME_JS = <<~JS.freeze
          function(method, selector, spec) {
            var doc;
            try { doc = this.contentDocument || (this.contentWindow && this.contentWindow.document); } catch(e) {}
            if (!doc) return [];
            var nodes = (function() {
              if (method === 'xpath') {
                #{format(XPATH_FIND_FRAGMENT, doc: 'doc', root: 'doc', selector: 'selector')}
              }
              #{format(CSS_FIND_FRAGMENT, target: 'doc', selector: 'selector')}
            })();
            return spec ? _lightpanda.findHints(nodes, spec) : nodes;
          }
        JS
        private_constant :FIND_IN_FRAME_JS

        # Walks `parentNode` from `this` up to (but excluding) `document`,
        # returning the chain as a JS array. Each entry is an element node so
        # `extract_hinted_nodes` can wrap them as Lightpanda::Nodes.
        PARENTS_JS = <<~JS
          function() {
            var nodes = [];
            var p = this.parentNode;
            while (p && p !== this.ownerDocument) {
              nodes.push(p);
              p = p.parentNode;
            }
            return nodes;
          }
        JS
        private_constant :PARENTS_JS

        def find_in_document(method, selector, spec)
          with_default_context_wait do
            # Coerce Symbol selectors (e.g. Capybara warning path lets `have_css(:p)`
            # through) to a string before quoting. Symbol#inspect returns `:p`,
            # which would inject a bare token into the JS source.
            selector_literal = selector.to_s.inspect
            # Same fragments as FIND_WITHIN_JS/FIND_IN_FRAME_JS, instantiated
            # with the selector embedded as a literal: this hot path keeps its
            # single Runtime.evaluate round-trip (no document-handle resolution).
            fragment = if method == "xpath"
                         format(XPATH_FIND_FRAGMENT, doc: "document", root: "document", selector: selector_literal)
                       else
                         format(CSS_FIND_FRAGMENT, target: "document", selector: selector_literal)
                       end
            nodes = "(function() { #{fragment} })()"
            nodes = "_lightpanda.findHints(#{nodes}, #{JSON.generate(spec)})" if spec
            result = evaluate_with_ref(nodes)
            extract_hinted_nodes(result)
          end
        rescue JavaScriptError => e
          raise_invalid_selector(e, method, selector)
        end

        def find_in_frame(method, selector, spec)
          with_default_context_wait do
            frame_node = @frame_stack.last
            result = call_function_on(frame_node.remote_object_id, FIND_IN_FRAME_JS, method, selector, spec,
                                      return_by_value: false)
            extract_hinted_nodes(result)
          end
        rescue JavaScriptError => e
          raise_invalid_selector(e, method, selector)
        end

        def raise_invalid_selector(js_error, method, selector)
          if js_error.message.include?(INVALID_SELECTOR_MARKER)
            raise InvalidSelector.new("Invalid #{method} selector: #{selector.inspect}", method, selector)
          end

          raise js_error
        end

        # Extract `[objectId, cache]` pairs from a remote array reference. The
        # hints, when findHints ran, are a JSON string on the array's own
        # `__lightpandaHints` property, read from the same getProperties call.
        # `ensure release_object` so the outer array handle is freed even when
        # property walking raises — without this, a transient CDP error during
        # property enumeration leaks one V8 handle per failed find call.
        def extract_hinted_nodes(result)
          return [] unless result && result["objectId"]

          outer_id = result["objectId"]
          begin
            props = get_object_properties(outer_id)
            properties = props["result"] || []
            ids = properties
                  .select { |p| p["name"] =~ /\A\d+\z/ }
                  .sort_by { |p| p["name"].to_i }
                  .filter_map { |p| p.dig("value", "objectId") }
            ids.zip(parse_hints(properties, ids.size))
          rescue Error
            []
          ensure
            release_object(outer_id)
          end
        end

        # One cache per node, keyed the way Capybara reads #initial_cache. A
        # missing, malformed or mis-sized payload yields empty caches, so
        # Capybara asks each node itself — never a wrong answer.
        def parse_hints(properties, count)
          raw = properties.find { |p| p["name"] == "__lightpandaHints" }&.dig("value", "value")
          hints = decode_hints(raw)
          return Array.new(count) { {} } unless hints&.size == count

          hints.map { |h| symbolize_hint(h) }
        end

        # Capybara may consume these after a DOM mutation during lazy Result
        # enumeration. Accept only well-typed immutable answers, never mutable
        # visibility/style/position or a payload from an incompatible helper.
        def symbolize_hint(hint)
          return {} unless hint.is_a?(Hash) && hint.keys == ["tag_name"] && hint["tag_name"].is_a?(String)

          { tag_name: hint["tag_name"] }
        end

        def decode_hints(raw)
          hints = raw.is_a?(String) ? JSON.parse(raw) : nil
          hints.is_a?(Array) ? hints : nil
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
