# frozen_string_literal: true

# A signed-in customer and a guest can share an application URL in one test.
# Resetting the guest must leave the customer's browser state intact.
module SessionIsolationContract
  APP = lambda do |env|
    account = Rack::Request.new(env).cookies["account"]
    [200, { "content-type" => "text/plain" }, [%w[customer guest].include?(account) ? account : "anonymous"]]
  end

  def test_two_sessions_keep_independent_login_state_across_a_guest_reset
    customer = Capybara::Session.new(@page.mode, APP)
    guest = Capybara::Session.new(@page.mode, APP)
    customer.visit("/")
    url = customer.current_url
    customer.execute_script("document.cookie = 'account=customer; path=/'; localStorage.setItem('cart', 'saved')")
    guest.visit(url)
    assert_equal "anonymous", guest.text
    assert_nil guest.evaluate_script("localStorage.getItem('cart')")

    guest.execute_script("document.cookie = 'account=guest; path=/'; localStorage.setItem('cart', 'temporary')")
    guest.visit(url)
    assert_equal "guest", guest.text
    assert_equal "temporary", guest.evaluate_script("localStorage.getItem('cart')")
    customer.visit(url)
    assert_equal "customer", customer.text

    guest.reset_session!
    guest.visit(url)
    assert_equal "anonymous", guest.text
    assert_nil guest.evaluate_script("localStorage.getItem('cart')")
    customer.visit(url)
    assert_equal "customer", customer.text
    assert_equal "saved", customer.evaluate_script("localStorage.getItem('cart')")
  ensure
    guest&.driver&.quit
    customer&.driver&.quit
  end
end
