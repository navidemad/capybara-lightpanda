# frozen_string_literal: true

require_relative "../test_helper"

# Issue #220. accept_*/dismiss_* pre-arm Lightpanda (LP.handleJavaScriptDialog
# fills one slot on the target), run the block, then find_modal claims the
# dialog the block opened. Two leaks broke that contract:
# - every dialog was queued for find_modal, including one opened long before
#   the arm, so an accept_* whose block opened nothing still "found" a modal;
# - a block that opened nothing left the slot armed, so the next dialog nobody
#   wrapped got that stale answer, silently.
describe "Modal pre-arm state" do
  let(:session) { TestSessions::Lightpanda }

  before { session.visit("/lightpanda/modal_prearm") }
  after { session.reset_session! }

  def quietly
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it "does not let a dialog from before the arm satisfy accept_alert" do
    quietly { session.click_button("Alert") } # unwrapped: warned, then forgotten

    assert_raises(Capybara::ModalNotFound) do
      session.accept_alert(wait: 0.5) { session.click_button("Nothing") }
    end
  end

  it "does not answer a later unwrapped confirm with a pre-arm its block never used" do
    assert_raises(Capybara::ModalNotFound) do
      session.accept_confirm(wait: 0.5) { session.click_button("Nothing") }
    end

    warning = quietly { session.click_button("Delete") }

    assert_equal "kept", session.find(:css, "#outcome").text,
                 "the stale accept leaked into a confirm nobody wrapped"
    assert_match(/confirm dialog with text `Delete\?` opened, but the action was not wrapped/, warning)
  end

  it "still answers the dialog its own block opens" do
    message = session.accept_confirm { session.click_button("Delete") }

    assert_equal "Delete?", message
    assert_equal "deleted", session.find(:css, "#outcome").text
  end
end
