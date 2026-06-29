// visibleText delegates the rendered-text collection (block line breaks,
// display:none descendant skipping, whitespace) to NATIVE Element.innerText
// (Lightpanda #2785/#2795). What remains in JS — and what these tests pin — is
// the thin wrapper Capybara needs on top of innerText: (1) a visibility GATE so
// a not-visible element reads as "" (native innerText would return textContent
// per the HTML getter's step 1), and (2) a ShadowRoot/DocumentFragment branch
// (fragments have no innerText of their own). Block-break / hidden-descendant
// fidelity is the browser's job now and is covered by the real-browser Capybara
// #text battery, not here — happy-dom has no layout to reproduce it.

import { test, expect } from "bun:test";
import { makeDom } from "./load.ts";

test("a visible element passes straight through to native innerText", () => {
  // The gate must not mangle a visible element — it returns exactly what
  // innerText gives (whose block/whitespace fidelity is the browser's job).
  const { predicates, document } = makeDom("<div>hello world</div>");
  const div = document.querySelector("div") as any;
  expect(predicates.visibleText(div)).toBe(div.innerText);
});

test("a not-visible element yields '' (WebDriver semantics, via checkVisibility)", () => {
  // The whole reason this isn't just `el.innerText`: a hidden element (here
  // mimicked by the checkVisibility stub, as for a display:none ancestor) must
  // read as "", where native innerText would return its textContent.
  const { predicates, document, setVisible } = makeDom("<div>secret</div>");
  setVisible(document.querySelector("div"), false);
  expect(predicates.visibleText(document.querySelector("div"))).toBe("");
});

test("a visibility:hidden element yields '' (real getComputedStyle, no stub)", () => {
  // Drives isVisible's real `getComputedStyle(el).visibility` short-circuit, so
  // the gate can't pass for the wrong reason.
  const { predicates, document } = makeDom(
    '<div style="visibility:hidden">secret</div>',
  );
  expect(predicates.visibleText(document.querySelector("div"))).toBe("");
});

test("walks a ShadowRoot (nodeType 11), which has no innerText of its own", () => {
  // The fragment branch concatenates visible element children's innerText with
  // the text nodes between them; without it `shadow_root.text` would be "".
  const { predicates, document } = makeDom('<div id="host"></div>');
  const root = (document.getElementById("host") as any).attachShadow({
    mode: "open",
  });
  root.innerHTML = "<span>one</span>\n  <span>two</span>";
  // Inter-element template whitespace collapses to a single separating space.
  expect(predicates.visibleText(root).trim()).toBe("one two");
});

test("the ShadowRoot branch skips not-visible element children", () => {
  // A hidden child contributes nothing — proves the fragment branch applies the
  // same visibility gate per child, not a blind textContent concat.
  const { predicates, document, setVisible } = makeDom('<div id="host"></div>');
  const root = (document.getElementById("host") as any).attachShadow({
    mode: "open",
  });
  root.innerHTML =
    '<span class="keep">keep</span><span class="drop">drop</span>';
  setVisible(root.querySelector(".drop"), false);
  expect(predicates.visibleText(root).trim()).toBe("keep");
});
