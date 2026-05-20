# frozen_string_literal: true

# Shared Rails app for the dropdown repro example.
#
# Reproduces the structure of a Stimulus + Floating UI dropdown that a beta
# tester hit on Lightpanda:
#   * trigger button with aria-label="Modifier"
#   * menu div toggled via the `hidden` HTML attribute
#   * action buttons wrapped in <form class="contents"> (Tailwind utility)
#
# The Stimulus controller is rewritten in vanilla JS so we don't pull
# Stimulus / Floating UI from a CDN — the bug surface is the open/close
# cycle and the DOM shape, not the libraries.
#
# Two variants:
#   /safe   — open() registers a `click-outside` document listener; the click
#             that opened the menu does NOT fire it (DOM spec: listeners added
#             during dispatch don't run for the current event), so the menu
#             stays open.
#   /buggy  — same plus a permanent `window` click listener that always closes
#             the menu (mirrors `data-action="click@window->…#close"` on the
#             wrapper element). The bubble of the opening click reaches it and
#             closes the menu immediately.

require "action_controller/railtie"
require "action_view/railtie"
require "capybara-lightpanda"

class TestApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.root = __dir__
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "secret_key_base"
  config.logger = Logger.new($stdout)
  config.log_level = :warn
end
Rails.application.initialize!

Rails.application.routes.draw do
  root to: "dropdowns#safe"
  get  "safe",  to: "dropdowns#safe"
  get  "buggy", to: "dropdowns#buggy"
  get  "buggy_with_flex_css", to: "dropdowns#buggy_with_flex_css"
  get  "buggy_with_important_flex_css", to: "dropdowns#buggy_with_important_flex_css"
  match "archive/:id", to: "dropdowns#archive", as: :archive, via: %i[get post patch]
end

class DropdownsController < ActionController::Base
  include Rails.application.routes.url_helpers

  skip_forgery_protection

  def safe
    render inline: dropdown_html(window_close: false)
  end

  def buggy
    render inline: dropdown_html(window_close: true)
  end

  # Same as /buggy, but with an inline `<style>` that mimics what Tailwind's
  # `.flex` utility does once an external stylesheet actually loads. CSS
  # specificity tie between `.flex` (utilities layer) and `[hidden]` (preflight
  # / UA) is broken by source order — utilities come last → `.flex` wins, the
  # `hidden` attribute becomes a no-op. Lightpanda parses inline `<style>` so
  # this lets us exercise the "what if external Tailwind were loaded?" path
  # without #2487's `--enable-external-stylesheets` flag.
  def buggy_with_flex_css
    render inline: dropdown_html(window_close: true, extra_head: <<~CSS)
      <style>
        .flex { display: flex; }
        .flex-col { flex-direction: column; }
      </style>
    CSS
  end

  # Same as /buggy_with_flex_css but with `!important` on `.flex` — what
  # Tailwind generates when the user has `important: true` in their config,
  # or when they use the `!flex` utility prefix. In Chrome this would force
  # `.flex` to beat ANY `[hidden] { display: none }` rule regardless of
  # source order.
  def buggy_with_important_flex_css
    render inline: dropdown_html(window_close: true, extra_head: <<~CSS)
      <style>
        .flex { display: flex !important; }
        .flex-col { flex-direction: column !important; }
      </style>
    CSS
  end

  def archive
    render inline: <<~HTML
      <h1 id="page-title">Archived</h1>
      <p id="status">Quotation #{ERB::Util.html_escape(params[:id])} archived</p>
    HTML
  end

  private

  def dropdown_html(window_close:, extra_head: "")
    window_close_js = window_close ? "window.addEventListener('click', closeMenu);" : ""

    <<~HTML
      <!DOCTYPE html>
      <html>
        <head><title>Dropdown repro</title>#{extra_head}</head>
        <body>
          <h1 id="page-title">Quotations</h1>
          <div id="wrapper" class="relative w-fit">
            <button type="button" id="open-btn" aria-label="Modifier"
                    class="cursor-pointer inline-flex">Edit</button>
            <div id="menu" role="menu" hidden
                 class="flex flex-col whitespace-nowrap rounded-md bg-white shadow-lg">
              <form class="contents" action="#{archive_path(id: 'q1')}" method="post">
                <input type="hidden" name="_method" value="patch">
                <button type="submit"
                        class="cursor-pointer inline-flex font-medium items-center">
                  Archiver
                </button>
              </form>
            </div>
          </div>
          <script>
            (function() {
              var wrapper = document.getElementById('wrapper');
              var openBtn = document.getElementById('open-btn');
              var menu    = document.getElementById('menu');
              var isOpen  = false;

              function handleClickOutside(event) {
                if (!wrapper.contains(event.target)) closeMenu();
              }

              function openMenu() {
                isOpen = true;
                menu.removeAttribute('hidden');
                // Mimic Floating UI: positioning is applied in a microtask
                // after computePosition() resolves.
                Promise.resolve().then(function() {
                  Object.assign(menu.style, {
                    position: 'absolute',
                    top: '42px',
                    left: '-190px',
                    zIndex: '99999'
                  });
                });
                document.addEventListener('click', handleClickOutside);
              }

              function closeMenu() {
                isOpen = false;
                menu.setAttribute('hidden', '');
                document.removeEventListener('click', handleClickOutside);
              }

              openBtn.addEventListener('click', function() {
                if (isOpen) closeMenu(); else openMenu();
              });

              #{window_close_js}
            })();
          </script>
        </body>
      </html>
    HTML
  end
end

Capybara.app = Rails.application
Capybara.default_driver = :lightpanda
Capybara.default_max_wait_time = 5
Capybara.server = :puma, { Silent: true }
