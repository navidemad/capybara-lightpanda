# frozen_string_literal: true

module Capybara
  module Lightpanda
    # Assembles the `_lightpanda` bundle injected once per session via
    # Page.addScriptToEvaluateOnNewDocument (Browser#create_page).
    #
    # The bundle is split across plain-declaration source files in
    # javascripts/ — none of which contain an IIFE or module syntax — so each
    # file is readable in isolation and parses identically as a classic
    # browser script and as a `new Function(...)` body (how the Bun harness in
    # test/js/ loads predicates.js without a build step). This module is the
    # "linker": it concatenates the parts in order and wraps them in the IIFE
    # plus the idempotency guard.
    module AutoScripts
      JS_DIR = File.expand_path("javascripts", __dir__).freeze

      # Order matters: declarations (turbo, predicates) before the wiring
      # (attach) that reads their names. banner is a leading comment block.
      # turbo.js and errors.js register their listeners at top level and expose
      # nothing through attach.js, so they only need to run inside the IIFE.
      PARTS = %w[banner.js turbo.js errors.js predicates.js attach.js].freeze

      # The guard short-circuits a repeat run before turbo.js can register its
      # listeners a second time (double-registration would double-count
      # _pendingTurboOps and desync the busy/idle sentinels console.rb reads).
      # window._lightpanda is only set by attach.js (last), so the guard
      # reflects "a previous full run completed".
      JS = begin
        body = PARTS.map { |name| File.read(File.join(JS_DIR, name)) }.join("\n")
        "(function() {\n" \
        "if (window._lightpanda) return;\n" \
        "#{body}\n" \
        "})();\n"
      end.freeze
    end
  end
end
