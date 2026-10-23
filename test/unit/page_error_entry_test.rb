# frozen_string_literal: true

require_relative "../test_helper"

# Browser::Console.page_error_entry turns one Runtime.exceptionThrown event into
# a page_errors entry. The payloads below are what Lightpanda 1.0.2 sent
# (captured 2026-10-23). The expected entries are what javascripts/errors.js
# produced for the same page before this event replaced it: suites written
# against page_errors match on these fields, so the swap must not move them.
describe "Capybara::Lightpanda::Browser::Console.page_error_entry" do
  def entry(details, timestamp: 202_251)
    Capybara::Lightpanda::Browser::Console.page_error_entry("exceptionDetails" => details, "timestamp" => timestamp)
  end

  let(:type_error) do
    {
      "text" => "Uncaught", "url" => "anonymous", "lineNumber" => 0, "columnNumber" => 9,
      "exception" => {
        "type" => "object", "subtype" => "error", "className" => "TypeError",
        "description" => "TypeError: Cannot read properties of undefined (reading 'id')\n    " \
                         "at HTMLButtonElement.<anonymous> (anonymous:1:10)",
      },
    }
  end

  it "reports an uncaught Error as 'Name: message' with a 1-based location" do
    assert_equal(
      {
        kind: "error",
        message: "TypeError: Cannot read properties of undefined (reading 'id')",
        url: "anonymous", line: 1, column: 10,
        stack: type_error["exception"]["description"],
        timestamp: 202_251,
      },
      entry(type_error)
    )
  end

  # An Error's message can span lines. Cutting at the first newline would lose
  # the rest; the stack frames start at "\n    at ".
  it "keeps a multi-line message whole" do
    details = type_error.merge("exception" => type_error["exception"].merge(
      "className" => "Error", "description" => "Error: line one\nline two\n    at anonymous:1:30"
    ))

    assert_equal "Error: line one\nline two", entry(details)[:message]
  end

  # errors.js read `reason.message` for a rejection, without the "Name: "
  # prefix, and had no location to report.
  it "reports an unhandled rejection by its reason's message, with no location" do
    details = {
      "text" => "Uncaught (in promise)", "lineNumber" => 0, "columnNumber" => 0,
      "exception" => {
        "type" => "object", "subtype" => "error", "className" => "Error",
        "description" => "Error: rejected on purpose\n    at HTMLButtonElement.<anonymous> (anonymous:1:16)",
      },
    }

    result = entry(details)
    assert_equal ["unhandledrejection", "rejected on purpose", "", nil, nil],
                 result.values_at(:kind, :message, :url, :line, :column)
    assert_match(/\AError: rejected on purpose\n/, result[:stack])
  end

  it "reports a thrown or rejected primitive as its value, with no stack" do
    thrown = { "text" => "Uncaught", "lineNumber" => 65, "columnNumber" => 25,
               "exception" => { "type" => "string", "value" => "prim boom", "description" => "" }, }
    rejected = { "text" => "Uncaught (in promise)", "lineNumber" => 0, "columnNumber" => 0,
                 "exception" => { "type" => "string", "value" => "plain string", "description" => "" }, }

    assert_equal ["error", "prim boom", "", 66, 26, nil],
                 entry(thrown).values_at(:kind, :message, :url, :line, :column, :stack)
    assert_equal ["unhandledrejection", "plain string", nil], entry(rejected).values_at(:kind, :message, :stack)
  end

  # String(null) / String(undefined) — what errors.js reported for these.
  it "names a thrown null or undefined" do
    thrown_null = { "text" => "Uncaught", "exception" => { "type" => "object", "subtype" => "null", "value" => nil } }
    thrown_undefined = { "text" => "Uncaught", "exception" => { "type" => "undefined" } }

    assert_equal "null", entry(thrown_null)[:message]
    assert_equal "undefined", entry(thrown_undefined)[:message]
  end

  # A deep recursion stack can be megabytes, and the buffer keeps up to 1000.
  it "caps the stack" do
    details = type_error.merge("exception" => type_error["exception"].merge(
      "description" => "RangeError: Maximum call stack size exceeded#{"\n    at f (app.js:1:1)" * 1_000}"
    ))

    assert_equal 4_000, entry(details)[:stack].size
  end

  # A malformed event still means the page threw: land it rather than drop it.
  it "survives an event with no details" do
    result = Capybara::Lightpanda::Browser::Console.page_error_entry({})

    assert_equal ["error", "", "", nil, nil, nil], result.values_at(:kind, :message, :url, :line, :column, :stack)
  end
end
