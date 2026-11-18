# frozen_string_literal: true

# A signed-in customer and a guest can share an application URL in one test.
# Resetting the guest must leave the customer's browser state intact.
module SessionIsolationContract
  def test_two_sessions_keep_independent_login_state_across_a_guest_reset
    customer = @page
    guest = Capybara::Session.new(customer.mode, customer.app)
    customer.visit("/")
    guest.visit(customer.current_url)
    customer.execute_script("document.cookie = 'account=customer; path=/'; localStorage.setItem('cart', 'saved')")
    account = "document.cookie.split('; ').find(pair => pair.startsWith('account=')) || null"
    assert_nil guest.evaluate_script(account)
    assert_nil guest.evaluate_script("localStorage.getItem('cart')")
    guest.execute_script("document.cookie = 'account=guest; path=/'; localStorage.setItem('cart', 'temporary')")
    assert_equal "account=customer", customer.evaluate_script(account)
    guest.reset_session!
    guest.visit(customer.current_url)
    assert_nil guest.evaluate_script(account)
    assert_nil guest.evaluate_script("localStorage.getItem('cart')")
    assert_equal "account=customer", customer.evaluate_script(account)
    assert_equal "saved", customer.evaluate_script("localStorage.getItem('cart')")
  ensure
    guest&.driver&.quit
  end
end
