# frozen_string_literal: true

module Capybara
  module Lightpanda
    class Browser
      # JS evaluation and RemoteObject plumbing: Runtime.evaluate /
      # callFunctionOn dispatch, result serialization (Ferrum's
      # Frame::Runtime is the peer-gem equivalent).
      module Runtime
        # Evaluate JS and return a serialized value.
        # No-args fast path uses Runtime.evaluate; with args we wrap as a function
        # and dispatch via Runtime.callFunctionOn so `arguments[i]` is bound.
        # Both paths use `returnByValue: false` and unwrap so DOM-node returns
        # come back as `{ "__lightpanda_node__" => ... }` for the Driver to wrap.
        #
        # The no-args path sends the user's text verbatim with `replMode: true`
        # (V8's DevTools-console REPL mode — Lightpanda forwards Runtime.evaluate
        # to the V8 inspector, which handles the flag natively). Without it,
        # top-level `const`/`let` persist in the global lexical environment
        # across classic scripts — per spec, and Chrome behaves identically —
        # so a second `const sel = ...` raises `SyntaxError: Identifier 'sel'
        # has already been declared`. REPL mode keeps the bindings (visible to
        # later calls, like the DevTools console) but allows redeclaration.
        # Completion-value semantics cover a bare expression (`'foo'`), a
        # `throw` statement, and multi-statement scripts alike.
        def evaluate(expression, *args)
          if args.empty?
            response = page_command("Runtime.evaluate", expression: expression, returnByValue: false,
                                                        awaitPromise: true, replMode: true)
            raise_on_js_error!("evaluate", expression, response)

            return unwrap_call_result(response["result"])
          end

          wrapped = "function() { return #{expression} }"
          call_with_args(wrapped, args)
        end

        # Execute JS without returning a value.
        #
        # Like `evaluate`, the no-args path uses `replMode: true` so top-level
        # `const`/`let` redeclarations across calls don't raise. Also raises
        # on JS exceptions so silent failures don't mask test bugs (the
        # previous fast path swallowed them because `awaitPromise: false` was
        # checked but `exceptionDetails` was not).
        def execute(expression, *args)
          if args.empty?
            response = page_command("Runtime.evaluate", expression: expression, returnByValue: false,
                                                        awaitPromise: false, replMode: true)
            raise_on_js_error!("execute", expression, response)
            return nil
          end

          wrapped = "function() { #{expression} }"
          call_with_args(wrapped, args, return_by_value: false)
          nil
        end

        # Single home for the exceptionDetails check on Runtime responses:
        # optional LIGHTPANDA_DEBUG dump, then JavaScriptError.
        def raise_on_js_error!(site, expression, response)
          return unless response["exceptionDetails"]

          debug_js_failure(site, expression, response)
          raise JavaScriptError, response
        end

        # When LIGHTPANDA_DEBUG=1 is set, log the JS expression and full CDP
        # response for every JsException to STDERR. Invaluable for isolating
        # which exact JS triggers an upstream Lightpanda bug.
        def debug_js_failure(site, expression, response)
          return unless ENV["LIGHTPANDA_DEBUG"]

          warn "[lightpanda:#{site}] expression:\n#{expression}\n[lightpanda:#{site}] response:\n#{response.inspect}\n"
        end

        # Evaluate async JS with a callback. The user's script receives
        # the callback as its last argument (`arguments[arguments.length - 1]`),
        # matching Capybara's evaluate_async_script contract.
        def evaluate_async(expression, *args, wait: @options.timeout)
          timeout_ms = (wait * 1000).to_i
          wrapped = <<~JS
            function() {
              var __args = Array.prototype.slice.call(arguments);
              return new Promise(function(__resolve, __reject) {
                var __timer = setTimeout(function() {
                  __reject(new Error('Async script timeout after #{timeout_ms}ms'));
                }, #{timeout_ms});
                var __done = function(val) { clearTimeout(__timer); __resolve(val); };
                __args.push(__done);
                (function() { #{expression} }).apply(null, __args);
              });
            }
          JS
          call_with_args(wrapped, args)
        end

        # Evaluate JS and return a RemoteObject reference (for DOM nodes, arrays).
        def evaluate_with_ref(expression)
          response = page_command("Runtime.evaluate", expression: expression, returnByValue: false, awaitPromise: true)
          raise_on_js_error!("evaluate_with_ref", expression, response)

          result = response["result"]
          return nil if result["type"] == "undefined"

          result
        end

        # Call a function on a remote object via Runtime.callFunctionOn.
        # Binds `this` to the DOM element referenced by remote_object_id.
        def call_function_on(remote_object_id, function_declaration, *args, return_by_value: true)
          params = {
            objectId: remote_object_id,
            functionDeclaration: function_declaration,
            returnByValue: return_by_value,
            awaitPromise: true,
          }
          params[:arguments] = args.map { |a| serialize_argument(a) } unless args.empty?

          response = page_command("Runtime.callFunctionOn", **params)
          raise_on_js_error!("call_function_on", function_declaration, response)

          result = response["result"]
          return nil if result["type"] == "undefined"

          return_by_value ? result["value"] : result
        end

        # Get properties of a remote object (used to extract array elements).
        def get_object_properties(remote_object_id)
          page_command("Runtime.getProperties", objectId: remote_object_id, ownProperties: true)
        end

        # Release a remote object reference to free V8 memory. Cleanup is
        # best-effort: callers wrap their work in `ensure release_object(...)`,
        # so a TimeoutError or transport hiccup here must not propagate out of
        # the ensure block and bury the original failure.
        def release_object(remote_object_id)
          page_command("Runtime.releaseObject", objectId: remote_object_id)
        rescue Error
          # Object may already be released, context destroyed, or the CDP call
          # itself timed out / failed in transport.
        end

        private

        def serialize_argument(arg)
          if arg.respond_to?(:remote_object_id)
            { objectId: arg.remote_object_id }
          else
            { value: arg }
          end
        end

        # Extract the by-value result of an already-issued Runtime call.
        def handle_evaluate_response(response, expression)
          raise_on_js_error!("handle_evaluate_response", expression, response)

          result = response["result"]
          return nil if result["type"] == "undefined"

          result["value"]
        end

        # Run a wrapped function via Runtime.callFunctionOn with `arguments` bound.
        # `args` is converted via `serialize_argument` (Nodes → objectId, scalars → value).
        # When `return_by_value: false` (the default) the return value is unwrapped via
        # `unwrap_call_result` so that DOM nodes come back as `{ "__lightpanda_node__" => ... }`
        # hashes the Driver can wrap as Capybara nodes.
        def call_with_args(function_declaration, args, return_by_value: false)
          # document_object_id returns a fresh RemoteObject handle every call.
          # Release it on the way out so long-running shared-spec sessions don't
          # accumulate orphaned V8 handles between resets.
          doc_oid = document_object_id
          params = {
            objectId: doc_oid,
            functionDeclaration: function_declaration,
            returnByValue: return_by_value,
            awaitPromise: true,
            arguments: args.map { |a| serialize_argument(a) },
          }
          response = page_command("Runtime.callFunctionOn", **params)
          raise_on_js_error!("call_with_args", function_declaration, response)

          return unwrap_call_result(response["result"]) unless return_by_value

          handle_evaluate_response(response, function_declaration)
        ensure
          release_object(doc_oid) if doc_oid
        end

        # Translate a non-by-value Runtime result into a plain Ruby value, surfacing
        # DOM nodes as `{ "__lightpanda_node__" => "..." }` so the Driver can wrap
        # them. The sentinel key (rather than a plain "objectId") prevents
        # misclassifying user JS that legitimately returns `{ objectId: "x" }`.
        #
        # When the result carries an objectId we can't unwrap (function, regexp,
        # date, …), release the handle before falling back to `result["value"]`
        # so V8 doesn't accumulate orphaned references across long sessions.
        def unwrap_call_result(result)
          return nil if result["type"] == "undefined"
          return nil if result["subtype"] == "null"

          object_id = result["objectId"]
          if object_id
            return { NODE_MARKER => object_id } if result["subtype"] == "node"
            return serialize_remote_array(object_id) if result["subtype"] == "array"
            return serialize_remote_object(object_id) if result["type"] == "object"

            release_object(object_id)
          end

          result["value"]
        end

        # Re-fetch a remote object as JSON-serializable value for plain objects/arrays.
        # Cheaper than walking properties and good enough for shared specs. Releases
        # the original handle so long-lived sessions don't accumulate leaked objectIds.
        def serialize_remote_object(object_id)
          json = page_command(
            "Runtime.callFunctionOn",
            objectId: object_id,
            functionDeclaration: "function() { return this }",
            returnByValue: true
          )
          handle_evaluate_response(json, "function() { return this }")
        ensure
          release_object(object_id)
        end

        # Walk an array's own indexed properties via `Runtime.getProperties`,
        # unwrapping each element through the regular result pipeline so that
        # DOM-node entries surface as `{ "__lightpanda_node__" => ... }` instead
        # of being flattened to `{}` by `returnByValue: true`. Releases the
        # outer array's objectId once we've harvested its elements.
        def serialize_remote_array(object_id)
          properties = get_object_properties(object_id).fetch("result", [])
          properties
            .select { |p| p["enumerable"] && p["name"] =~ /\A\d+\z/ }
            .sort_by { |p| p["name"].to_i }
            .map { |p| unwrap_call_result(p["value"] || {}) }
        ensure
          release_object(object_id)
        end

        # objectId of `document`, used as the `this` context for callFunctionOn when
        # we need `arguments` binding but don't care about `this`. Re-resolved per
        # call because the document objectId is invalidated by navigation.
        def document_object_id
          result = page_command("Runtime.evaluate", expression: "document", returnByValue: false)
          result.dig("result", "objectId")
        end

        private :raise_on_js_error!, :debug_js_failure, :get_object_properties
      end
    end
  end
end
