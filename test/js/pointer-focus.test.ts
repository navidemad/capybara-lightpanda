// pointerFocusTarget: what a real pointer press focuses. CLICK_JS applies it
// because Lightpanda's own click handling stopped focusing controls (upstream
// #3702) and an untrusted mousedown never runs the focus default — without it
// `click` then `page.send_keys` types into <body>. The Capybara-level behavior
// is pinned in test/features/pointer_focus_test.rb; these pin the walk itself.

import { test, expect } from "bun:test";
import { makeDom } from "./load.ts";

function target(html: string, id: string): string | null {
  const { predicates, document } = makeDom(html);
  const el = predicates.pointerFocusTarget(document.getElementById(id)) as HTMLElement | null;
  return el ? el.id || el.tagName : null;
}

test("a press inside a button focuses the button", () => {
  expect(target('<button id="b"><span id="t">x</span></button>', "t")).toBe("b");
});

test("a press on plain content focuses nothing (Chrome then focuses the body)", () => {
  expect(target('<div><p id="t">x</p></div>', "t")).toBe(null);
});

test("an anchor is focusable only with an href", () => {
  expect(target('<a id="a" href="/x"><b id="t">x</b></a>', "t")).toBe("a");
  expect(target('<a id="a"><b id="t">x</b></a>', "t")).toBe(null);
});

test("tabindex makes any element focusable", () => {
  expect(target('<div id="d" tabindex="-1"><span id="t">x</span></div>', "t")).toBe("d");
});

test("a disabled control is skipped in favor of a focusable ancestor", () => {
  expect(target('<div id="d" tabindex="0"><button id="t" disabled>x</button></div>', "t")).toBe("d");
});

test("a hidden input is never focused", () => {
  expect(target('<input id="t" type="hidden">', "t")).toBe(null);
});

test("an option press focuses its <select>", () => {
  expect(target('<select id="s"><option id="t">a</option></select>', "t")).toBe("s");
});

test("inside contenteditable, the outermost editing host takes focus", () => {
  expect(
    target('<div id="host" contenteditable><div contenteditable="true"><p id="t">x</p></div></div>', "t"),
  ).toBe("host");
});

test("a label press focuses its control, not the label", () => {
  expect(target('<label id="l" for="i"><span id="t">L</span></label><input id="i">', "t")).toBe("i");
});
