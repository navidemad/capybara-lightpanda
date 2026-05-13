# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"
require "yaml"
require "capybara/lightpanda/errors"
require "capybara/lightpanda/cookies"

describe Capybara::Lightpanda::Cookies::Cookie do
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

  let(:cookie) { Capybara::Lightpanda::Cookies::Cookie.new(attributes) }

  it "exposes typed accessors" do
    assert_equal "session", cookie.name
    assert_equal "abc123", cookie.value
    assert_equal ".example.com", cookie.domain
    assert_equal "/", cookie.path
    assert_equal 12, cookie.size
    assert_equal "Lax", cookie.samesite
    assert_equal "Lax", cookie.same_site
  end

  it "exposes booleans with predicate methods" do
    assert_equal true, cookie.secure?
    assert_equal true, cookie.httponly?
    assert_equal true, cookie.http_only?
    assert_equal false, cookie.session?
  end

  describe "#expires" do
    it "returns a Time when the cookie has a positive expires value" do
      assert_kind_of Time, cookie.expires
      assert_equal 1_700_000_000, cookie.expires.to_i
    end

    it "returns nil for session cookies (negative expires)" do
      session_cookie = Capybara::Lightpanda::Cookies::Cookie.new(attributes.merge("expires" => -1))
      assert_nil session_cookie.expires
    end

    it "returns nil when expires is zero" do
      zero_cookie = Capybara::Lightpanda::Cookies::Cookie.new(attributes.merge("expires" => 0))
      assert_nil zero_cookie.expires
    end

    it "returns nil when expires is missing" do
      no_expires = Capybara::Lightpanda::Cookies::Cookie.new(attributes.except("expires"))
      assert_nil no_expires.expires
    end
  end

  describe "#==" do
    it "compares attribute hashes" do
      twin = Capybara::Lightpanda::Cookies::Cookie.new(attributes.dup)
      assert_equal cookie, twin
    end

    it "is not equal to a different attribute set" do
      other = Capybara::Lightpanda::Cookies::Cookie.new(attributes.merge("value" => "different"))
      refute_equal cookie, other
    end

    it "is not equal to a non-Cookie object" do
      refute_equal cookie, attributes
    end
  end

  describe "#to_h" do
    it "returns the underlying attributes hash" do
      assert_equal attributes, cookie.to_h
    end
  end
end

describe Capybara::Lightpanda::Cookies do
  describe "#store and #load" do
    let(:browser) { mock("Browser") }
    let(:cookies) { Capybara::Lightpanda::Cookies.new(browser) }
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
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [cookie_attrs])

      cookies.store(tmp_path)

      assert File.exist?(tmp_path), "expected #{tmp_path} to exist"
      assert_equal [cookie_attrs], YAML.load_file(tmp_path)

      browser.expects(:command).with(
        "Network.setCookie",
        has_entries(
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

    it "round-trips sameSite through the YAML file" do
      attrs_with_samesite = cookie_attrs.merge("sameSite" => "Lax")
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [attrs_with_samesite])

      cookies.store(tmp_path)

      # restore_cookie must forward sameSite to Network.setCookie as `sameSite:`
      # (CDP camelCase) — otherwise SameSite-sensitive cookies silently lose
      # their enforcement on reload.
      browser.expects(:command).with(
        "Network.setCookie",
        has_entries(name: "session", sameSite: "Lax")
      )
      cookies.load(tmp_path)
    end

    it "drops invalid sameSite values rather than passing them to CDP" do
      browser.stubs(:command).with("Network.getAllCookies").returns(
        "cookies" => [cookie_attrs.merge("sameSite" => "Bogus")]
      )

      cookies.store(tmp_path)

      # CDP rejects unknown SameSite values; the gem must filter to canonical
      # spec strings ("Strict" / "Lax" / "None") so a hand-edited YAML can't
      # turn a load into a CDP error.
      browser.expects(:command).with(
        "Network.setCookie",
        Not(has_key(:sameSite))
      )
      cookies.load(tmp_path)
    end

    it "defaults to cookies.yml when no path is given" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [])
          cookies.store
          assert File.exist?("cookies.yml"), "expected cookies.yml in tmpdir"
        end
      end
    end
  end

  describe "Enumerable" do
    let(:browser) { mock("Browser") }
    let(:cookies) { Capybara::Lightpanda::Cookies.new(browser) }

    let(:raw_cookies) do
      [
        { "name" => "a", "value" => "1", "domain" => ".example.com", "path" => "/" },
        { "name" => "b", "value" => "2", "domain" => ".other.com", "path" => "/" },
      ]
    end

    before do
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => raw_cookies)
    end

    it "yields each cookie" do
      yielded = cookies.map(&:name)
      assert_equal %w[a b], yielded
    end

    it "supports Enumerable methods like find/select/map" do
      assert_equal "2", cookies.find { |c| c.name == "b" }.value
      assert_equal ["a"], cookies.select { |c| c.domain.include?("example") }.map(&:name)
    end

    it "returns an Enumerator when called without a block" do
      assert_kind_of Enumerator, cookies.each
    end
  end
end
