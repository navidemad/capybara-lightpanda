# frozen_string_literal: true

# Measures how easy README.md is to read. Dev-only; not part of the gem.
#
# Two numbers, the ones the `readme-writer` skill asks for
# (https://skills.rest/skill/readme-writer-bnferguson):
#
# - the Flesch-Kincaid grade level: lower is easier, the target is 9 or below;
# - the share of words found in the 1000 basic English words: higher is easier.
#
# Both are computed on the prose only. Code blocks, URLs and badges are
# removed first: left in, they dominate the counts and the grade says nothing
# about the sentences a person reads.
module Readability
  WORD_LIST = File.expand_path("readability/basic_words.txt", __dir__)
  MAX_GRADE = 9.0

  Report = Struct.new(:grade, :words, :sentences, :basic_share, :longest, keyword_init: true)

  module_function

  # Markdown -> the text a reader reads.
  def prose(markdown)
    text = markdown.gsub(/^```.*?^```/m, "")
    text = text.gsub(/!\[[^\]]*\]\([^)]*\)/, "")        # images and badges
    text = text.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')     # links keep their label
    text = text.gsub(/^\s*>\s*\[!\w+\]\s*$/, "")        # callout markers
    text = text.gsub(/<[^>]+>/, "")
    text = text.gsub(/^#+ .*$/, "")                     # a heading is not a sentence
    text = text.gsub(/^(\s*[-*] .*[^.!?:\s])\s*$/, '\1.') # a list item ends a sentence
    text.gsub(/^\s*[-*>] ?/, "").gsub(/[`*|]/, "")
  end

  # A dot inside a token ("README.md", "1.0.4", "x86_64") ends nothing.
  def sentences(text)
    text.split(/(?<=[.!?:])\s+|\n\s*\n/).map(&:strip).grep(/[a-zA-Z]/)
  end

  def words(text)
    text.scan(/[A-Za-z][A-Za-z'-]*/)
  end

  # Vowel groups, minus a silent final "e". The usual estimate; wrong on a few
  # words, stable enough to compare two versions of the same text.
  def syllables(word)
    word = word.downcase.gsub(/[^a-z]/, "")
    word = word.sub(/e\z/, "") unless word.end_with?("le") && word.length > 2
    [word.scan(/[aeiouy]+/).length, 1].max
  end

  def grade(text)
    list = words(text)
    return 0.0 if list.empty?

    count = [sentences(text).length, 1].max
    (0.39 * (list.length.to_f / count)) + (11.8 * (list.sum { |w| syllables(w) }.to_f / list.length)) - 15.59
  end

  def basic_words
    @basic_words ||= File.readlines(WORD_LIST, chomp: true).reject { |l| l.empty? || l.start_with?("#") }.to_set
  end

  # Exact matches only, like the skill's profiler: "tests" and "has" count as
  # misses. That keeps the number comparable with the skill's own script.
  def basic_share(text)
    list = text.downcase.scan(/[a-z]+/)
    return 0.0 if list.empty?

    100.0 * list.count { |w| basic_words.include?(w) } / list.length
  end

  def report(markdown, longest: 5)
    text = prose(markdown)
    all = sentences(text)
    Report.new(
      grade: grade(text).round(1),
      words: words(text).length,
      sentences: all.length,
      basic_share: basic_share(text).round(1),
      longest: all.max_by(longest) { |s| words(s).length }.map { |s| s.gsub(/\s+/, " ") }
    )
  end
end
