# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../script/readability"

# `rake readme:readability` fails the build when the README gets hard to read.
# These tests pin the two things that make its number worth trusting: it must
# measure the sentences a person reads, not the markup around them, and it
# must move the right way when the writing gets harder.
describe Readability do
  describe ".prose" do
    it "drops code blocks, so Ruby snippets can't pass as easy or hard sentences" do
      text = Readability.prose("Run it.\n\n```ruby\nCapybara::Lightpanda.configure { |c| c.timeout = 30 }\n```\n")

      refute_includes text, "configure"
      assert_includes text, "Run it."
    end

    it "keeps a link's label and drops its URL" do
      text = Readability.prose("Read the [docs](https://example.com/a/very/long/path).")

      assert_equal "Read the docs.", text.strip
    end

    it "drops badges and headings, which are not sentences" do
      text = Readability.prose("# Title\n\n[![Gem](https://img.shields.io/x)](https://rubygems.org)\n\nHello.\n")

      assert_equal "Hello.", text.strip
    end

    it "ends each list item, so a list doesn't read as one endless sentence" do
      text = Readability.prose("- real scrolling\n- screenshots\n")

      assert_equal 2, Readability.sentences(text).length
    end
  end

  describe ".sentences" do
    it "doesn't split on the dots of a file name or a version" do
      assert_equal 1, Readability.sentences("Read README.md before you use 1.0.4 here.").length
    end
  end

  describe ".grade" do
    it "rates long sentences of long words harder than short plain ones" do
      plain = "The gem gets the browser. You run a test. It works."
      dense = "Unsupported configurations necessitate comprehensive troubleshooting documentation, " \
              "notwithstanding extensive automated compatibility verification."

      assert_operator Readability.grade(plain), :<, 3
      assert_operator Readability.grade(dense), :>, Readability::MAX_GRADE
    end
  end

  describe ".basic_share" do
    it "counts exact matches only, to stay comparable with the skill's profiler" do
      # "the", "dog", "and", "cat" are basic words; "tests" (plural) is not listed.
      assert_in_delta 80.0, Readability.basic_share("The dog and cat tests"), 0.01
    end
  end

  describe "README.md" do
    it "stays at or below the target grade" do
      readme = File.read(File.expand_path("../../README.md", __dir__))

      assert_operator Readability.report(readme).grade, :<=, Readability::MAX_GRADE
    end
  end
end
