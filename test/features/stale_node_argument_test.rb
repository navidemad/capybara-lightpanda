# frozen_string_literal: true

require_relative "../test_helper"

# A node from the previous document passed as an *argument* makes Lightpanda
# answer "Argument should belong to the same JavaScript world as target
# object". It must raise NodeNotFoundError — a member of the driver's
# invalid_element_errors — so Capybara's automatic_reload and callers'
# stale-element rescues treat it like every other gone node, not as an
# unclassified BrowserError.
describe "a stale node passed as a script argument" do
  let(:session) { TestSessions::Lightpanda }

  after { session.reset_session! }

  it "raises NodeNotFoundError after the page navigates away" do
    session.visit("/lightpanda/simple")
    stale = session.find(:css, "#content")
    session.visit("/lightpanda/other")

    error = assert_raises(Capybara::Lightpanda::NodeNotFoundError) do
      session.execute_script("arguments[0].textContent", stale)
    end
    assert_includes session.driver.invalid_element_errors, error.class
  end
end
