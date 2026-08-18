# frozen_string_literal: true

require_relative "../test_helper"

# A JS dialog nobody pre-armed is resolved by Lightpanda's silent default
# (confirm → cancel, prompt → null, alert → dismissed). Left unreported, a
# runaway `confirm` cancels the action and the spec still passes green — the
# false negative Cuprite's `raise_on_unhandled_modal` (PR #320) exists for.
# The gem warns by default and raises when the option is on; a properly
# wrapped dialog does neither.
describe "Capybara::Lightpanda unhandled modals" do
  let(:session) { TestSessions::Lightpanda }
  let(:options) { session.driver.browser.options }

  before { session.visit("/lightpanda/modal_type_leniency") }

  after do
    options.raise_on_unhandled_modal = false
    session.reset_session!
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it "warns (and lets Lightpanda's default stand) when a confirm opens with no pre-arm" do
    output = capture_stderr { session.find(:css, "#delete").click }

    assert_match(/confirm dialog with text `Are you sure\?` opened, but the action was not wrapped/, output)
    assert_match(/cancelled it by default/, output)
    assert_equal "kept", session.find(:css, "#outcome").text
  end

  it "raises UnhandledModalError from the click when raise_on_unhandled_modal is on" do
    options.raise_on_unhandled_modal = true

    error = assert_raises(Capybara::Lightpanda::UnhandledModalError) do
      session.find(:css, "#delete").click
    end

    assert_match(/Are you sure\?/, error.message)
    # The dialog is already gone by the time we raise — Lightpanda resolved it.
    assert_equal "kept", session.find(:css, "#outcome").text
  end

  it "reports each unhandled dialog once — the next action does not re-raise it" do
    options.raise_on_unhandled_modal = true
    assert_raises(Capybara::Lightpanda::UnhandledModalError) { session.find(:css, "#delete").click }

    assert_equal "kept", session.find(:css, "#outcome").text # find + text: no second raise
  end

  it "stays silent when the dialog is wrapped in accept_confirm" do
    options.raise_on_unhandled_modal = true

    output = capture_stderr do
      session.accept_confirm { session.find(:css, "#delete").click }
    end

    assert_empty output
    assert_equal "deleted", session.find(:css, "#outcome").text
  end

  it "forgets a pending unhandled dialog on reset_session!" do
    options.raise_on_unhandled_modal = true
    session.driver.browser.instance_variable_set(:@unhandled_modal, { type: "confirm", message: "stale" })

    session.reset_session!
    session.visit("/lightpanda/modal_type_leniency") # go_to checks too — must not raise
  end
end
