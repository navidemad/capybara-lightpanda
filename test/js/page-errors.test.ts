// Tests the SHIPPED errors.js — the bytes AutoScripts concatenates into the
// injected bundle. Same no-build-step trick as load.ts: the file is a sequence
// of plain declarations with no module syntax, so it evaluates as a
// `new Function(...)` body in the same classic-script parse mode the browser
// uses. A hand-rolled window/console is used rather than happy-dom because the
// point here is the payload shape and the event filtering, and a fake lets a
// resource-failure event (no string `message`) be constructed exactly.

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";

const ERRORS_SRC = new URL(
  "../../lib/capybara/lightpanda/javascripts/errors.js",
  import.meta.url,
);
const CONSOLE_RB = new URL(
  "../../lib/capybara/lightpanda/browser/console.rb",
  import.meta.url,
);

type Handler = (event: any) => void;

function load() {
  const handlers: Record<string, Handler[]> = {};
  const debugCalls: string[] = [];
  const win = {
    addEventListener(name: string, fn: Handler) {
      (handlers[name] ||= []).push(fn);
    },
  };
  const fakeConsole = {
    debug(message: string) {
      debugCalls.push(message);
    },
  };

  new Function("window", "console", readFileSync(ERRORS_SRC, "utf8"))(win, fakeConsole);

  const dispatch = (name: string, event: any) =>
    (handlers[name] || []).forEach((fn) => fn(event));
  const payloads = () =>
    debugCalls.map((c) => JSON.parse(c.replace("__lightpanda_page_error_", "")));

  return { handlers, debugCalls, dispatch, payloads };
}

test("both listeners are registered on window", () => {
  const { handlers } = load();
  expect(Object.keys(handlers).sort()).toEqual(["error", "unhandledrejection"]);
});

// The prefix is duplicated across the language boundary — JS emits it, Ruby
// matches it. If they drift, page errors silently become console_logs entries
// (the exact leak the separation exists to prevent), and no other test notices.
test("the sentinel prefix matches the Ruby constant", () => {
  const ruby = readFileSync(CONSOLE_RB, "utf8");
  const declared = ruby.match(/PAGE_ERROR_SENTINEL_PREFIX\s*=\s*"([^"]+)"/);
  expect(declared).not.toBeNull();

  const { dispatch, debugCalls } = load();
  dispatch("error", { message: "boom" });
  expect(debugCalls[0].startsWith(declared![1])).toBe(true);
});

test("an uncaught error reports message, location and stack", () => {
  const { dispatch, payloads } = load();
  dispatch("error", {
    message: "Cannot read properties of undefined (reading 'id')",
    filename: "http://app.test/assets/taxonomy.js",
    lineno: 94,
    colno: 22,
    error: { stack: "TypeError: …\n    at handle_create" },
  });

  expect(payloads()).toEqual([
    {
      kind: "error",
      message: "Cannot read properties of undefined (reading 'id')",
      url: "http://app.test/assets/taxonomy.js",
      line: 94,
      column: 22,
      stack: "TypeError: …\n    at handle_create",
    },
  ]);
});

// A failed <img>/<script> fetch fires `error` with no string message. Those are
// network facts that Network#traffic already carries; reporting them as page
// errors would make "the page threw" mean two different things.
test("a resource-failure event is ignored", () => {
  const { dispatch, debugCalls } = load();
  dispatch("error", { target: { tagName: "IMG" } });
  dispatch("error", {});
  dispatch("error", null);
  expect(debugCalls).toEqual([]);
});

test("missing location fields degrade to empty/null rather than undefined", () => {
  const { dispatch, payloads } = load();
  dispatch("error", { message: "bare" });

  // undefined would vanish from the JSON entirely and the Ruby entry would then
  // carry no :line key at all, so assert the nulls are explicit.
  expect(payloads()[0]).toEqual({
    kind: "error",
    message: "bare",
    url: "",
    line: null,
    column: null,
    stack: null,
  });
});

test("a rejection with an Error reason keeps message and stack", () => {
  const { dispatch, payloads } = load();
  dispatch("unhandledrejection", {
    reason: { message: "rejected on purpose", stack: "Error: rejected on purpose" },
  });

  const payload = payloads()[0];
  expect(payload.kind).toBe("unhandledrejection");
  expect(payload.message).toBe("rejected on purpose");
  expect(payload.stack).toBe("Error: rejected on purpose");
});

test("a rejection with a non-Error reason is stringified", () => {
  const { dispatch, payloads } = load();
  dispatch("unhandledrejection", { reason: "just a string" });
  dispatch("unhandledrejection", { reason: 42 });

  expect(payloads().map((p) => p.message)).toEqual(["just a string", "42"]);
});

test("a reason that throws on stringify still reports", () => {
  const { dispatch, payloads } = load();
  dispatch("unhandledrejection", {
    reason: {
      get message() {
        throw new Error("nope");
      },
    },
  });

  // Silence here would be the worst outcome: the page rejected and nothing said so.
  expect(payloads()[0].message).toBe("(rejection reason could not be stringified)");
});

test("a deep stack is capped so it can't flood the CDP socket", () => {
  const { dispatch, payloads } = load();
  dispatch("error", { message: "deep", error: { stack: "x".repeat(10_000) } });
  expect(payloads()[0].stack.length).toBe(4000);
});
