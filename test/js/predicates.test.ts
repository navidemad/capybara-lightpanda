// Ancestor-walk predicates and the visibility short-circuits. These are the
// parts that DON'T depend on Lightpanda's checkVisibility/layout, so happy-dom
// can exercise them faithfully. Each test pins the Capybara behavior it backs.

import { test, expect } from "bun:test";
import { makeDom } from "./load.ts";

// --- isContentEditable -------------------------------------------------------
// Lightpanda's native HTMLElement.isContentEditable is hardwired to false (no
// caret pipeline), so node.rb walks ancestors itself. This is what makes
// `fill_in` into a contenteditable region work.

test("isContentEditable: true when an ancestor is contenteditable", () => {
  const { predicates, document } = makeDom(
    '<div contenteditable="true"><p><span id="t">x</span></p></div>',
  );
  expect(predicates.isContentEditable(document.getElementById("t"))).toBe(true);
});

test("isContentEditable: bare `contenteditable` attribute (empty value) counts", () => {
  // `<div contenteditable>` is valid HTML meaning editable; only "false" opts out.
  const { predicates, document } = makeDom('<div contenteditable><span id="t">x</span></div>');
  expect(predicates.isContentEditable(document.getElementById("t"))).toBe(true);
});

test('isContentEditable: contenteditable="false" opts out', () => {
  const { predicates, document } = makeDom(
    '<div contenteditable="false"><span id="t">x</span></div>',
  );
  expect(predicates.isContentEditable(document.getElementById("t"))).toBe(false);
});

test("isContentEditable: nearest ancestor wins (false under true)", () => {
  // The closest contenteditable declaration governs the node, matching the DOM
  // spec's inheritance — a false island inside an editable region is read-only.
  const { predicates, document } = makeDom(
    '<div contenteditable="true"><div contenteditable="false"><span id="t">x</span></div></div>',
  );
  expect(predicates.isContentEditable(document.getElementById("t"))).toBe(false);
});

test("isContentEditable: false with no contenteditable anywhere", () => {
  const { predicates, document } = makeDom('<div><span id="t">x</span></div>');
  expect(predicates.isContentEditable(document.getElementById("t"))).toBe(false);
});

// --- isDisabled --------------------------------------------------------------
// Capybara's Node#disabled? is more permissive than CSS :disabled — an <option>
// inside a disabled <select> reports disabled even though it doesn't match
// :disabled per spec. Mirrors Cuprite so the shared specs pass.

test("isDisabled: an element matching :disabled is disabled", () => {
  const { predicates, document } = makeDom('<input id="t" disabled>');
  expect(predicates.isDisabled(document.getElementById("t"))).toBe(true);
});

test("isDisabled: an enabled element is not disabled", () => {
  const { predicates, document } = makeDom('<input id="t">');
  expect(predicates.isDisabled(document.getElementById("t"))).toBe(false);
});

test("isDisabled: <option> inside a disabled <select> is disabled (the Cuprite quirk)", () => {
  // This is the case CSS :disabled misses; the ancestor walk is the whole point.
  const { predicates, document } = makeDom(
    '<select disabled><option id="t">a</option></select>',
  );
  expect(predicates.isDisabled(document.getElementById("t"))).toBe(true);
});

test("isDisabled: <option> inside an enabled <select> is not disabled", () => {
  const { predicates, document } = makeDom(
    '<select><option id="t">a</option></select>',
  );
  expect(predicates.isDisabled(document.getElementById("t"))).toBe(false);
});

test("isDisabled: <option> under an <optgroup> walks past it to the disabled <select>", () => {
  // Exercises the multi-hop `while (p)` ancestor loop, not just a direct
  // parent — the option's immediate parent here is the optgroup, not the
  // select, so the walk must climb two levels.
  const { predicates, document } = makeDom(
    '<select disabled><optgroup label="g"><option id="t">a</option></optgroup></select>',
  );
  expect(predicates.isDisabled(document.getElementById("t"))).toBe(true);
});

// NOTE on the disabled-<fieldset> case: predicates.js's comment says a control
// inside a disabled <fieldset> reports disabled. That works in real Lightpanda
// because its `:disabled` matches fieldset descendants per spec (verified
// live: matches(':disabled') === true), so isDisabled's first branch already
// covers it — no gem-specific ancestor walk needed (the walk is OPTION-only).
// We deliberately DON'T add a happy-dom test for it: happy-dom's `:disabled`
// does NOT match fieldset descendants, so any assertion here would encode
// happy-dom's quirk rather than the gem's contract. That path stays covered by
// the live Capybara battery.

// --- isVisible short-circuits ------------------------------------------------
// checkVisibility (stubbed here) ignores visibility:hidden|collapse per spec,
// so the gem handles those explicitly before delegating. That explicit branch
// is what we can test without a real layout engine.

test("isVisible: false for a null / non-element node", () => {
  const { predicates, document } = makeDom("<div>x</div>");
  expect(predicates.isVisible(null)).toBe(false);
  expect(predicates.isVisible(document.createTextNode("x"))).toBe(false);
});

test("isVisible: visibility:hidden is rejected even when checkVisibility says shown", () => {
  // The explicit short-circuit: checkVisibility's defaults don't catch this.
  const { predicates, document } = makeDom('<div id="t" style="visibility:hidden">x</div>');
  expect(predicates.isVisible(document.getElementById("t"))).toBe(false);
});

test("isVisible: visibility:collapse is rejected", () => {
  const { predicates, document } = makeDom('<div id="t" style="visibility:collapse">x</div>');
  expect(predicates.isVisible(document.getElementById("t"))).toBe(false);
});

test("isVisible: delegates to checkVisibility when visibility is not hidden", () => {
  const { predicates, document, setVisible } = makeDom('<div id="t">x</div>');
  const el = document.getElementById("t");
  expect(predicates.isVisible(el)).toBe(true);
  setVisible(el, false);
  expect(predicates.isVisible(el)).toBe(false);
});

// --- isObscured early guards -------------------------------------------------
// Deep hit-testing (elementFromPoint + real rects) needs a layout engine and
// lives in the Capybara battery. happy-dom CAN exercise the visibility:hidden
// short-circuit, which returns "obscured" without consulting layout.

test("isObscured: visibility:hidden short-circuits to obscured", () => {
  const { predicates, document } = makeDom('<div id="t" style="visibility:hidden">x</div>');
  expect(predicates.isObscured(document.getElementById("t"))).toBe(true);
});

