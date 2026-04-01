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
  resources :posts, only: %i[index show new create edit update]
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
        <form action="#{posts_path}" method="post" id="new-post-form">
          <input type="text" name="title" id="post-title" placeholder="Title">
          <textarea name="body" id="post-body-input" placeholder="Write..."></textarea>
          <input type="submit" value="Publish">
        </form>
        <a href="#{posts_path}" id="cancel-new-post">Cancel</a>
      </turbo-frame>
    HTML
  end

  def create
    title = ERB::Util.html_escape(params[:title])
    body = ERB::Util.html_escape(params[:body])
    render_with_layout <<~HTML
      <h1 id="page-title">Post Created</h1>
      <p id="post-title-result">#{title}</p>
      <p id="post-body-result">#{body}</p>
    HTML
  end

  def edit
    render inline: <<~HTML
      <turbo-frame id="post-edit-frame">
        <form action="#{post_path(params[:id])}" method="post" id="edit-post-form">
          <input type="hidden" name="_method" value="patch">
          <input type="text" name="title" id="edit-title" value="Post ##{params[:id]}">
          <input type="submit" value="Save">
        </form>
      </turbo-frame>
    HTML
  end

  def update
    title = ERB::Util.html_escape(params[:title])
    render_with_layout <<~HTML
      <h1 id="page-title">Post Updated</h1>
      <p id="edit-result">Saved: #{title}</p>
    HTML
  end
end

# ── Capybara setup ─────────────────────────────────────────────────

Capybara.app = Rails.application
Capybara.default_driver = :lightpanda
Capybara.default_max_wait_time = 5

def wait_for_turbo_init
  sleep 1
end
