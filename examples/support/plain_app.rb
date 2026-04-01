# frozen_string_literal: true

# Shared Rails app for plain (non-Turbo) examples.
# Required after bundler/inline resolves gems.

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

# ── Routes ─────────────────────────────────────────────────────────

Rails.application.routes.draw do
  root to: "pages#home"
  get  "about",       to: "pages#about"
  get  "dashboard",   to: "pages#dashboard"
  get  "dynamic",     to: "pages#dynamic"
  get  "frame_host",  to: "pages#frame_host"
  get  "frame_inner", to: "pages#frame_inner"
  resources :contacts, only: %i[new create show]
end

# ── Controllers ────────────────────────────────────────────────────

class PagesController < ActionController::Base
  include Rails.application.routes.url_helpers

  def home
    render inline: <<~HTML
      <h1>Welcome</h1>
      <nav>
        <a href="<%= about_path %>">About</a>
        <a href="<%= new_contact_path %>">New Contact</a>
        <a href="<%= dashboard_path %>">Dashboard</a>
        <a href="<%= dynamic_path %>">Dynamic</a>
        <a href="<%= frame_host_path %>">Frames</a>
      </nav>
      <p id="intro">Test suite for capybara-lightpanda</p>
    HTML
  end

  def about
    render inline: <<~HTML
      <h1>About</h1>
      <p id="description">A headless browser driver for Capybara.</p>
      <a href="<%= root_path %>">Home</a>
    HTML
  end

  def dashboard
    render inline: <<~HTML
      <h1>Dashboard</h1>
      <table id="stats">
        <thead><tr><th>Metric</th><th>Value</th></tr></thead>
        <tbody>
          <tr class="stat"><td class="name">Visitors</td><td class="value">1234</td></tr>
          <tr class="stat"><td class="name">Signups</td><td class="value">56</td></tr>
          <tr class="stat"><td class="name">Revenue</td><td class="value">$7890</td></tr>
        </tbody>
      </table>
      <ul id="actions">
        <li class="action">Export</li>
        <li class="action">Refresh</li>
        <li class="action">Settings</li>
      </ul>
    HTML
  end

  def dynamic
    render inline: <<~HTML
      <h1>Dynamic Page</h1>
      <div id="output"></div>
      <button id="btn-add" type="button">Add Item</button>
      <button id="btn-replace" type="button">Replace Content</button>
      <style>.hidden { display: none; }</style>
      <button id="btn-toggle" type="button">Toggle Section</button>
      <div id="toggleable" class="hidden"><p>Hidden section revealed</p></div>
      <div id="counter">Count: 0</div>
      <button id="btn-count" type="button">Increment</button>
      <button id="btn-delayed" type="button">Delayed Append</button>
      <input id="live-search" type="text" placeholder="Type to search...">
      <div id="search-results"></div>
      <script>
        var count = 0;
        document.getElementById('btn-add').addEventListener('click', function() {
          var el = document.createElement('p');
          el.className = 'dynamic-item';
          el.textContent = 'Item ' + (document.querySelectorAll('.dynamic-item').length + 1);
          document.getElementById('output').appendChild(el);
        });
        document.getElementById('btn-replace').addEventListener('click', function() {
          document.getElementById('output').innerHTML = '<p id="replaced">Content replaced</p>';
        });
        document.getElementById('btn-toggle').addEventListener('click', function() {
          document.getElementById('toggleable').classList.toggle('hidden');
        });
        document.getElementById('btn-count').addEventListener('click', function() {
          count++;
          document.getElementById('counter').textContent = 'Count: ' + count;
        });
        document.getElementById('btn-delayed').addEventListener('click', function() {
          setTimeout(function() {
            var el = document.createElement('p');
            el.id = 'delayed-item';
            el.textContent = 'Appeared after delay';
            document.getElementById('output').appendChild(el);
          }, 200);
        });
        document.getElementById('live-search').addEventListener('input', function(e) {
          var results = document.getElementById('search-results');
          if (e.target.value.length > 0) {
            results.innerHTML = '<p class="result">Result for: ' + e.target.value + '</p>';
          } else {
            results.innerHTML = '';
          }
        });
      </script>
    HTML
  end

  def frame_host
    render inline: <<~HTML
      <h1 id="main-title">Main Page</h1>
      <p id="main-text">Content outside the frame</p>
      <iframe id="inner-frame" src="<%= frame_inner_path %>"></iframe>
    HTML
  end

  def frame_inner
    render inline: <<~HTML
      <p id="frame-content">Inside the iframe</p>
      <a id="frame-link" href="#">Frame link</a>
    HTML
  end
end

class ContactsController < ActionController::Base
  include Rails.application.routes.url_helpers

  def new
    render inline: <<~HTML
      <h1>New Contact</h1>
      <%= form_with url: contacts_path, id: "contact-form" do |f| %>
        <div>
          <%= f.label :name %>
          <%= f.text_field :name, placeholder: "Full name" %>
        </div>
        <div>
          <%= f.label :email %>
          <%= f.email_field :email %>
        </div>
        <div>
          <%= f.label :phone %>
          <%= f.telephone_field :phone %>
        </div>
        <div>
          <%= f.label :notes %>
          <%= f.text_area :notes, rows: 4 %>
        </div>
        <div>
          <%= f.label :category %>
          <%= f.select :category, [["Personal", "personal"], ["Work", "work"], ["Other", "other"]], prompt: "Choose..." %>
        </div>
        <div>
          <%= f.label :priority %>
          <%= f.select :priority, [["Low", "low"], ["Medium", "medium"], ["High", "high"]], {}, { multiple: true, id: "priority" } %>
        </div>
        <fieldset>
          <legend>Preferred Contact</legend>
          <%= f.label :preferred_email, "Email" %>
          <%= f.radio_button :preferred, "email", id: "preferred_email" %>
          <%= f.label :preferred_phone, "Phone" %>
          <%= f.radio_button :preferred, "phone", id: "preferred_phone" %>
        </fieldset>
        <div>
          <%= f.label :newsletter %>
          <%= f.check_box :newsletter, id: "newsletter" %>
        </div>
        <div>
          <%= f.label :vip %>
          <%= f.check_box :vip, { id: "vip", disabled: true } %>
        </div>
        <%= f.submit "Save Contact" %>
      <% end %>
    HTML
  end

  def create
    render inline: <<~HTML
      <h1>Contact Saved</h1>
      <dl id="contact-details">
        <dt>Name</dt>  <dd id="show-name"><%= params[:name] %></dd>
        <dt>Email</dt> <dd id="show-email"><%= params[:email] %></dd>
        <dt>Phone</dt> <dd id="show-phone"><%= params[:phone] %></dd>
        <dt>Notes</dt> <dd id="show-notes"><%= params[:notes] %></dd>
        <dt>Category</dt> <dd id="show-category"><%= params[:category] %></dd>
        <dt>Preferred</dt> <dd id="show-preferred"><%= params[:preferred] %></dd>
        <dt>Newsletter</dt> <dd id="show-newsletter"><%= params[:newsletter] %></dd>
      </dl>
      <a href="<%= new_contact_path %>">Create another</a>
    HTML
  end

  def show
    render inline: "<h1>Contact #<%= params[:id] %></h1>"
  end
end

# ── Capybara setup ─────────────────────────────────────────────────

Capybara.app = Rails.application
Capybara.default_driver = :lightpanda
