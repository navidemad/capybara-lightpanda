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

    # Stores written while Lightpanda (< build 9877) reported every cookie
    # without SameSite as "None" must still load: since upstream #3529 the
    # browser refuses SameSite=None without Secure, and a silent refusal
    # would drop the whole session on reload.
    it "restores an insecure SameSite=None cookie as unspecified SameSite" do
      browser.stubs(:command).with("Network.getAllCookies").returns(
        "cookies" => [cookie_attrs.merge("secure" => false, "sameSite" => "None")]
      )
      cookies.store(tmp_path)

      browser.expects(:command).with("Network.setCookie", Not(has_key(:sameSite))).returns("success" => true)
      cookies.load(tmp_path)
    end

    it "keeps SameSite=None on a secure cookie" do
      browser.stubs(:command).with("Network.getAllCookies").returns(
        "cookies" => [cookie_attrs.merge("sameSite" => "None")]
      )
      cookies.store(tmp_path)

      browser.expects(:command).with("Network.setCookie", has_entries(sameSite: "None")).returns("success" => true)
      cookies.load(tmp_path)
    end

    it "reports cookies the browser refused instead of dropping them silently" do
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [cookie_attrs])
      cookies.store(tmp_path)
      browser.stubs(:command).with("Network.setCookie", anything).returns("success" => false)

      _out, err = capture_io { assert cookies.load(tmp_path) }

      assert_match(/refused cookies .*: session/, err)
    end

    # Builds before 10212 stored cookies with malformed fields; since upstream
    # #3791 setting one back answers -32602. One such entry in a saved file
    # must not abort restoring the rest of the session.
    it "keeps restoring after a cookie the browser rejects as malformed" do
      good = cookie_attrs.merge("name" => "good")
      bad = cookie_attrs.merge("name" => "a;b")
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [bad, good])
      cookies.store(tmp_path)
      refusal = Capybara::Lightpanda::BrowserError.new("code" => -32_602, "message" => "Sanitizing cookie failed")
      browser.expects(:command).with("Network.setCookie", has_entries(name: "a;b")).raises(refusal)
      browser.expects(:command).with("Network.setCookie", has_entries(name: "good")).returns("success" => true)

      _out, err = capture_io { assert cookies.load(tmp_path) }

      assert_match(/refused cookies .*: a;b\z/, err.strip)
    end

    # Only the sanitizing refusal is a per-cookie verdict; any other browser
    # error (a dead connection, a protocol failure) must still surface.
    it "still raises browser errors other than a cookie refusal" do
      browser.stubs(:command).with("Network.getAllCookies").returns("cookies" => [cookie_attrs])
      cookies.store(tmp_path)
      browser.stubs(:command).with("Network.setCookie", anything)
             .raises(Capybara::Lightpanda::BrowserError.new("code" => -32_000, "message" => "boom"))

      assert_raises(Capybara::Lightpanda::BrowserError) { cookies.load(tmp_path) }
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

  describe "#set" do
    let(:browser) { mock("Browser") }
    let(:cookies) { Capybara::Lightpanda::Cookies.new(browser) }

    # Lightpanda answers {success: false} and drops an invalid cookie
    # (e.g. SameSite=None without Secure, upstream #3529); the return value
    # is the only way a caller learns it never stuck.
    it "returns false when the browser refuses the cookie" do
      browser.stubs(:command).returns("success" => false)

      refute cookies.set(name: "a", value: "b", domain: "example.test", same_site: "None")
    end

    it "returns true when the browser accepts it" do
      browser.stubs(:command).returns("success" => true)

      assert cookies.set(name: "a", value: "b", domain: "example.test")
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

    # Ferrum/Cuprite spelling — real suites read cookies by name off the
    # driver (`browser.cookies["session_id"]`), so the subscript must work.
    it "looks up a cookie by name via [] and returns nil when absent" do
      assert_equal "1", cookies["a"].value
      assert_nil cookies["missing"]
    end
  end
end
