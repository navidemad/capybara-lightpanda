// Loads the SHIPPED predicates.js — the exact bytes AutoScripts concatenates
// into the injected bundle — and returns its functions for direct testing.
//
// The trick that avoids a build step: predicates.js is a sequence of plain
// `function` declarations with no `export`/`import`. We read its text and
// evaluate it as a `new Function(...)` body, which is the SAME classic-script
// parse mode the browser uses when AutoScripts injects the IIFE. So the test
// path and the ship path can never drift — if the file parses here it parses
// there, and vice versa. The only difference from attach.js is that we
// `return` the functions instead of assigning them to `window._lightpanda`.
//
// happy-dom provides the DOM, but its visibility fidelity is not browser-grade:
// it has no `checkVisibility()` and no layout (getBoundingClientRect is zeros,
// elementFromPoint is null). So these tests target the gem's OWN logic — the
// whitespace/block rules, the ancestor walks, the visibility short-circuits —
// and treat `checkVisibility`/layout as a controllable input (see makeDom's
// stub). Deep hit-testing / real visibility stays in the Capybara battery.

import { Window } from "happy-dom";
import { readFileSync } from "node:fs";

const PREDICATES_SRC = new URL(
  "../../lib/capybara/lightpanda/javascripts/predicates.js",
  import.meta.url,
);

export interface Predicates {
  isVisible(el: unknown): boolean;
  isObscured(el: unknown): boolean;
  isDisabled(el: unknown): boolean;
  isContentEditable(el: unknown): boolean;
  visibleText(el: unknown): string;
  [name: string]: (el: unknown) => unknown;
}

// Every top-level `function NAME(...)` declared in predicates.js. Derived from
// the source rather than hand-listed so a NEW predicate is automatically
// exposed to the tests — otherwise a function could ship into the bundle with
// zero unit coverage and nothing would flag it. (A renamed function is already
// caught loudly: the return-list would reference an undefined name and throw.)
export function predicateNames(): string[] {
  const source = readFileSync(PREDICATES_SRC, "utf8");
  return [...source.matchAll(/^function\s+([A-Za-z0-9_]+)\s*\(/gm)].map(
    (m) => m[1],
  );
}

// Build the predicate functions bound to a given window/document, exactly as
// attach.js would wire them onto _lightpanda — but returned instead of
// assigned to window._lightpanda.
function instantiate(win: Window): Predicates {
  const source = readFileSync(PREDICATES_SRC, "utf8");
  const names = predicateNames();
  const factory = new Function(
    "window",
    "document",
    `${source}\n;return { ${names.map((n) => `${n}: ${n}`).join(", ")} };`,
  );
  return factory(win, win.document) as Predicates;
}

export interface Dom {
  window: Window;
  document: Document;
  predicates: Predicates;
  // Set an element's `checkVisibility()` return value (happy-dom lacks it).
  // Defaults to visible:true for every element a test doesn't override.
  setVisible(el: unknown, visible: boolean): void;
}

// Create a fresh happy-dom realm with the given body HTML, with a default
// `checkVisibility` of `true` patched onto every element so visibleText's
// text-assembly logic can be exercised. Override per element via setVisible.
export function makeDom(bodyHTML: string): Dom {
  const window = new Window({ url: "http://localhost/" });
  const document = window.document as unknown as Document;
  document.body.innerHTML = bodyHTML;

  // happy-dom doesn't implement checkVisibility(); default everything visible.
  // NOTE: happy-dom shares one Element.prototype across all Window realms, so
  // this patch is applied once and inherited by every makeDom() call. That's
  // safe ONLY because the stub is stateless-per-instance — it reads
  // per-element `this.__lp_visible` (fresh elements default to undefined →
  // visible), so nothing leaks across tests. Keep it stateless: do not close
  // over realm/test state here or tests will bleed across files.
  const proto = (window as any).Element.prototype;
  if (typeof proto.checkVisibility !== "function") {
    proto.checkVisibility = function () {
      return this.__lp_visible !== false;
    };
  }

  const predicates = instantiate(window);
  function setVisible(el: any, visible: boolean) {
    el.__lp_visible = visible;
  }

  return { window, document, predicates, setVisible };
}
