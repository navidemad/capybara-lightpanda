# frozen_string_literal: true

require "bundler/setup"
require "fileutils"
require "tmpdir"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/cookies"

RSpec.describe Capybara::Lightpanda::Cookies::Cookie do
  let(:attributes) do
    {
      "name" => "session",
      "value" => "abc123",
      "domain" => ".example.com",
      "path" => "/",
      "expires" => 1_700_000_000,
      "size" => 12,
      "httpOnly" => true,
      "secure" => true,
      "session" => false,
      "sameSite" => "Lax",
    }
  end

  subject(:cookie) { described_class.new(attributes) }

  it "exposes typed accessors" do
    expect(cookie.name).to eq("session")
    expect(cookie.value).to eq("abc123")
    expect(cookie.domain).to eq(".example.com")
    expect(cookie.path).to eq("/")
    expect(cookie.size).to eq(12)
    expect(cookie.samesite).to eq("Lax")
    expect(cookie.same_site).to eq("Lax")
  end

  it "exposes booleans with predicate methods" do
    expect(cookie.secure?).to be true
    expect(cookie.httponly?).to be true
    expect(cookie.http_only?).to be true
    expect(cookie.session?).to be false
  end

  describe "#expires" do
    it "returns a Time when the cookie has a positive expires value" do
      expect(cookie.expires).to be_a(Time)
      expect(cookie.expires.to_i).to eq(1_700_000_000)
    end

    it "returns nil for session cookies (negative expires)" do
      session_cookie = described_class.new(attributes.merge("expires" => -1))
      expect(session_cookie.expires).to be_nil
    end

    it "returns nil when expires is zero" do
      zero_cookie = described_class.new(attributes.merge("expires" => 0))
      expect(zero_cookie.expires).to be_nil
    end

    it "returns nil when expires is missing" do
      no_expires = described_class.new(attributes.except("expires"))
      expect(no_expires.expires).to be_nil
    end
  end

  describe "#==" do
    it "compares attribute hashes" do
      twin = described_class.new(attributes.dup)
      expect(cookie).to eq(twin)
    end

    it "is not equal to a different attribute set" do
      other = described_class.new(attributes.merge("value" => "different"))
      expect(cookie).not_to eq(other)
    end

    it "is not equal to a non-Cookie object" do
      expect(cookie).not_to eq(attributes)
    end
  end

  describe "#to_h" do
    it "returns the underlying attributes hash" do
      expect(cookie.to_h).to eq(attributes)
    end
  end
end

RSpec.describe Capybara::Lightpanda::Cookies do
  describe "#store and #load" do
    let(:browser) { instance_double("Browser") }
    let(:cookies) { described_class.new(browser) }
    let(:tmp_path) { File.join(Dir.tmpdir, "lightpanda_cookies_test_#{$PID}.yml") }

    let(:cookie_attrs) do
      {
        "name" => "session",
        "value" => "abc",
        "domain" => ".example.com",
        "path" => "/",
        "expires" => 1_700_000_000,
        "httpOnly" => true,
        "secure" => true,
      }
    end

    after { FileUtils.rm_f(tmp_path) }

    it "round-trips cookies through a YAML file" do
      allow(browser).to receive(:command).with("Network.getAllCookies").and_return("cookies" => [cookie_attrs])

      cookies.store(tmp_path)

      expect(File.exist?(tmp_path)).to be true
      expect(YAML.load_file(tmp_path)).to eq([cookie_attrs])

      expect(browser).to receive(:command).with(
        "Network.setCookie",
        hash_including(
          name: "session",
          value: "abc",
          domain: ".example.com",
          path: "/",
          secure: true,
          httpOnly: true,
          expires: 1_700_000_000
        )
      )
      cookies.load(tmp_path)
    end

    it "defaults to cookies.yml when no path is given" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          allow(browser).to receive(:command).with("Network.getAllCookies").and_return("cookies" => [])
          cookies.store
          expect(File.exist?("cookies.yml")).to be true
        end
      end
    end
  end
end
