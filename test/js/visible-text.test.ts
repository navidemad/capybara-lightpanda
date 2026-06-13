// visibleText is the gem's DIY replacement for Chrome's innerText: Lightpanda
// has no rendering, so its native innerText returns textContent verbatim (no
// whitespace collapsing, no hidden-descendant filtering, no block line breaks).
// Capybara's text matchers (`have_text`, `text: "Line\nLine"`) expect
// Chrome-innerText semantics, so the rules below are exactly what makes those
// matchers pass. Each test pins one rule and says why it matters.

import { test, expect } from "bun:test";
import { makeDom } from "./load.ts";

test("collapses runs of ASCII whitespace in text nodes to a single space", () => {
  // Source templates indent and wrap freely; Chrome's innerText collapses that
  // so `have_text("a b")` matches markup written as `a\n      b`.
  const { predicates, document } = makeDom("<span>a\n\t  b   c</span>");
  expect(predicates.visibleText(document.querySelector("span"))).toBe("a b c");
});

test("preserves NBSP (it is not ASCII whitespace)", () => {
  // NBSP is meaningful content (e.g. "10 000" thousands separators). Collapsing
  // it would corrupt amounts/labels the test asserts on.
  const { predicates, document } = makeDom("<span>a b</span>");
  expect(predicates.visibleText(document.querySelector("span"))).toBe("a b");
});

test("wraps block-display containers in newlines so paragraphs separate", () => {
  // Two <p>s render as two lines in Chrome; Capybara's `text` joins them with a
  // newline. Without the block-wrap they'd concatenate into one run.
  const { predicates, document } = makeDom("<div><p>one</p><p>two</p></div>");
  // Inner newlines come from each block; leading/trailing are trimmed by the
  // Ruby side (filter_text), so we assert the structure, not the edges.
  expect(predicates.visibleText(document.querySelector("div")).trim()).toBe(
    "one\n\ntwo",
  );
});

test("does NOT wrap inline elements in newlines", () => {
  // <span>/<b> are inline — wrapping them would inject phantom breaks mid-line.
  const { predicates, document } = makeDom("<p>a<span>b</span>c</p>");
  expect(predicates.visibleText(document.querySelector("p")).trim()).toBe("abc");
});

test("does not emit a phantom line break for an empty block between inline text", () => {
  // Chrome's innerText collapses required breaks around empty blocks. An empty
  // <div> between two text nodes must NOT split them across lines. (A <section>
  // wrapper, not <p>, because <div> can't be a child of <p> — the HTML parser
  // would auto-close the <p> and move `b` out, changing the structure we mean
  // to test.)
  const { predicates, document } = makeDom("<section>a<div></div>b</section>");
  expect(predicates.visibleText(document.querySelector("section")).trim()).toBe(
    "ab",
  );
});

test("renders <br> as a hard newline", () => {
  const { predicates, document } = makeDom("<span>a<br>b</span>");
  expect(predicates.visibleText(document.querySelector("span"))).toBe("a\nb");
});

test("reads <textarea> value instead of its child text", () => {
  // A textarea's editable content lives in `.value`, not its DOM children;
  // Capybara expects the current value to surface as text.
  const { predicates, document } = makeDom("<textarea>typed</textarea>");
  const ta = document.querySelector("textarea") as any;
  ta.value = "edited";
  expect(predicates.visibleText(ta)).toBe("edited");
});

test("an empty <textarea> contributes no text (the `|| ''` fallback)", () => {
  // Covers the empty branch the test above never reaches — a cleared textarea
  // must yield "" rather than leaking its (absent) child text.
  const { predicates, document } = makeDom("<textarea></textarea>");
  (document.querySelector("textarea") as any).value = "";
  expect(predicates.visibleText(document.querySelector("textarea"))).toBe("");
});

test("drops visibility:hidden descendants using real getComputedStyle (no stub)", () => {
  // Unlike the checkVisibility-stub test below, this drives the gem's REAL
  // hide path: isVisible's `getComputedStyle(el).visibility === 'hidden'`
  // short-circuit, which happy-dom resolves faithfully. So it can't pass for
  // the wrong reason — break that branch and this fails.
  const { predicates, document } = makeDom(
    '<div>shown <span style="visibility:hidden">gone</span></div>',
  );
  expect(predicates.visibleText(document.querySelector("div")).trim()).toBe(
    "shown",
  );
});

test("walks a ShadowRoot (nodeType 11) and returns its text", () => {
  // The nodeType === 11 branch (DocumentFragment / ShadowRoot) has no element
  // of its own to visibility-test, so it just recurses into children. Without
  // this test that whole branch could be deleted and everything still passed.
  const { predicates, document } = makeDom('<div id="host"></div>');
  const root = (document.getElementById("host") as any).attachShadow({
    mode: "open",
  });
  root.innerHTML = "<p>one</p><p>two</p>";
  expect(predicates.visibleText(root).trim()).toBe("one\n\ntwo");
});

test("excludes text from elements reported not-visible", () => {
  // The whole reason this isn't just textContent: hidden descendants must drop
  // out. We drive checkVisibility (happy-dom lacks it) to mark the span hidden.
  const { predicates, document, setVisible } = makeDom(
    "<div>shown <span>hidden</span></div>",
  );
  setVisible(document.querySelector("span"), false);
  expect(predicates.visibleText(document.querySelector("div")).trim()).toBe(
    "shown",
  );
});

test("walks into a visible block and keeps its text", () => {
  const { predicates, document } = makeDom(
    "<div><h1>Title</h1><p>body</p></div>",
  );
  expect(predicates.visibleText(document.querySelector("div")).trim()).toBe(
    "Title\n\nbody",
  );
});
