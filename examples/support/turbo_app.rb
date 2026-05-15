# frozen_string_literal: true

# Shared Rails + Turbo app for Turbo examples.
# Required after bundler/inline resolves gems.

require "action_controller/railtie"
require "action_view/railtie"
require "turbo-rails"
require "capybara-lightpanda"

TURBO_CDN = "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"

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

# ── Helper ─────────────────────────────────────────────────────────

module LayoutHelper
  def render_with_layout(body)
    render inline: <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>App</title>
          <meta name="csrf-param" content="authenticity_token">
          <meta name="csrf-token" content="#{form_authenticity_token}">
          <script type="module" src="#{TURBO_CDN}"></script>
        </head>
        <body>
          <nav id="main-nav">
            <a href="/">Home</a>
            <a href="/posts">Posts</a>
            <a href="/about">About</a>
          </nav>
          #{body}
          <footer id="footer">© 2026</footer>
        </body>
      </html>
    HTML
  end
end

# ── Routes ─────────────────────────────────────────────────────────

Rails.application.routes.draw do
  root to: "pages#home"
  get "about", to: "pages#about"
  resources :posts, only: %i[index show new create edit update] do
    collection { get :created }
    member { get :updated }
  end
  get "notifications", to: "notifications#card"
end

# ── Controllers ────────────────────────────────────────────────────

class PagesController < ActionController::Base
  include Rails.application.routes.url_helpers
  include LayoutHelper

  skip_forgery_protection

  def home
    render_with_layout <<~HTML
      <h1 id="page-title">Home</h1>
      <turbo-frame id="notifications" src="#{notifications_path}">
        <span id="notif-loading">...</span>
      </turbo-frame>
      <turbo-frame id="new-post-frame">
        <a href="#{new_post_path}" id="new-post-link">Write a post</a>
      </turbo-frame>
      <div id="posts-list"><p>Recent posts appear here.</p></div>
    HTML
  end

  def about
    render_with_layout <<~HTML
      <h1 id="page-title">About</h1>
      <p id="about-text">Built with Rails + Turbo.</p>
    HTML
  end
end

class NotificationsController < ActionController::Base
  skip_forgery_protection

  def card
    render inline: '<turbo-frame id="notifications"><span id="notif-badge">3 unread</span></turbo-frame>'
  end
end

class PostsController < ActionController::Base
  include Rails.application.routes.url_helpers
  include LayoutHelper

  skip_forgery_protection

  def index
    render_with_layout <<~HTML
      <h1 id="page-title">Posts</h1>
      <div id="posts-list">
        <article class="post"><h2><a href="#{post_path(1)}">First Post</a></h2></article>
        <article class="post"><h2><a href="#{post_path(2)}">Second Post</a></h2></article>
      </div>
    HTML
  end

  def show
    render inline: <<~HTML
      <!DOCTYPE html>
      <html><head>
        <meta name="csrf-param" content="authenticity_token">
        <meta name="csrf-token" content="#{form_authenticity_token}">
        <script type="module" src="#{TURBO_CDN}"></script>
      </head><body>
        <nav id="main-nav"><a href="/">Home</a><a href="/posts">Posts</a></nav>
        <h1 id="page-title">Post ##{params[:id]}</h1>
        <article id="post-body"><p>Full content of post ##{params[:id]}.</p></article>
        <turbo-frame id="post-edit-frame">
          <a href="#{edit_post_path(params[:id])}" id="edit-link">Edit</a>
        </turbo-frame>
        <footer id="footer">© 2026</footer>
      </body></html>
    HTML
  end

  def new
    render inline: <<~HTML
      <turbo-frame id="new-post-frame">
        <h2>New Post</h2>
        <form action="#{posts_path}" method="post" id="new-post-form" data-turbo-frame="_top">
          <input type="text" name="title" id="post-title" placeholder="Title">
          <textarea name="body" id="post-body-input" placeholder="Write..."></textarea>
          <input type="submit" value="Publish">
        </form>
        <a href="#{posts_path}" id="cancel-new-post">Cancel</a>
      </turbo-frame>
    HTML
  end

  # Hotwire convention: respond with 303 See Other after a successful POST
  # so Turbo Drive follows the redirect via GET and renders the result page.
  # Returning 200 HTML directly here would (a) let Rails set the response
  # Content-Type from the request's preferred Accept format (turbo-stream
  # when Turbo's fetch wrapper is in play) and (b) leave Turbo treating the
  # body as a Stream message — no <turbo-stream> elements means no render.
  # The redirect-then-render-on-GET path is what real Rails+Turbo apps do.
  def create
    redirect_to created_posts_path(title: params[:title], body: params[:body]), status: :see_other
  end

  def created
    title = ERB::Util.html_escape(params[:title])
    body = ERB::Util.html_escape(params[:body])
    respond_to do |format|
      format.html do
        render_with_layout <<~HTML
          <h1 id="page-title">Post Created</h1>
          <p id="post-title-result">#{title}</p>
          <p id="post-body-result">#{body}</p>
        HTML
      end
    end
  end

  def edit
    render inline: <<~HTML
      <turbo-frame id="post-edit-frame">
        <form action="#{post_path(params[:id])}" method="post" id="edit-post-form" data-turbo-frame="_top">
          <input type="hidden" name="_method" value="patch">
          <input type="text" name="title" id="edit-title" value="Post ##{params[:id]}">
          <input type="submit" value="Save">
        </form>
      </turbo-frame>
    HTML
  end

  # Same Hotwire 303-redirect pattern as `create`. The `updated` action then
  # renders the success page with the same Accept-aware respond_to so Rails
  # serves text/html instead of auto-promoting to turbo-stream.
  def update
    redirect_to updated_post_path(params[:id], title: params[:title]), status: :see_other
  end

  def updated
    title = ERB::Util.html_escape(params[:title])
    respond_to do |format|
      format.html do
        render_with_layout <<~HTML
          <h1 id="page-title">Post Updated</h1>
          <p id="edit-result">Saved: #{title}</p>
        HTML
      end
    end
  end
end

# ── Capybara setup ─────────────────────────────────────────────────

Capybara.app = Rails.application
Capybara.default_driver = :lightpanda
Capybara.default_max_wait_time = 5
Capybara.server = :puma, { Silent: true }

# Turbo loads from a CDN as an ES module, so its readiness is async.
# Poll instead of `sleep N` — same shape, deterministic, faster.
def wait_for_turbo_init(timeout: 5)
  deadline = Time.now + timeout
  loop do
    return true if evaluate_script("typeof Turbo !== 'undefined' && !!Turbo.session")
    raise "Turbo did not initialize within #{timeout}s" if Time.now > deadline

    sleep 0.05
  end
end
