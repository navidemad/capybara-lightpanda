# frozen_string_literal: true

require_relative "../test_helper"

# Modal type leniency: `accept_alert` must accept a `confirm()` dialog.
#
# Selenium cannot distinguish alerts from confirms (both are "alerts"), and
# Cuprite's dialog handler accepts whatever fires — so real suites wrap
# `data-confirm` deletes in `accept_alert` (solidus admin does exactly this)
# and pass on those drivers. The gem's `find_modal` therefore matches dialogs
# by message text only and ignores the reported type.
describe "Capybara::Lightpanda modal type leniency" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/modal_type_leniency") }
  after { session.reset_session! }

  it "accept_alert accepts a confirm() dialog" do
    message = session.accept_alert do
      session.find(:css, "#delete").click
    end

    assert_equal "Are you sure?", message
    assert_equal "deleted", session.find(:css, "#outcome").text
  end

  it "dismiss_confirm still cancels the dialog" do
    session.dismiss_confirm do
      session.find(:css, "#delete").click
    end

    assert_equal "kept", session.find(:css, "#outcome").text
  end

  it "raises ModalNotFound naming the seen dialog when the text does not match" do
    error = assert_raises(Capybara::ModalNotFound) do
      session.accept_confirm("totally different text", wait: 1) do
        session.find(:css, "#delete").click
      end
    end

    assert_match(/found 'Are you sure\?' instead/, error.message)
  end
end
