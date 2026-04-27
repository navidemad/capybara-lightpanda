# probe-lib

Tiny vendored helpers for CDP probes + reproducers. Pulled out so each new probe
doesn't reinvent the same WebSocket + session-attach boilerplate.

## What's here

- `cdp.js` — `connect()` / `makeClient()` / `sleep()`. Wraps raw `ws` with
  `Target.createTarget` + `Target.attachToTarget` + `Page.enable` + `Runtime.enable`.
  Exposes `send(method, params)`, `eval(expr)`, `navigate(url)`, `waitFor(expr)`.

## How probes use it

Reproducer probes live in `/Users/navid/code/browser/repro/<id>-<slug>/` (gitignored).
**Copy `cdp.js` into the repro directory** alongside `probe.js` — the repro must
stay self-contained so the maintainer can run `bash repro.sh` with no reference
to this skill's directory. Don't `require` paths outside the repro folder.

```bash
cp .claude/skills/lightpanda-upstream-pr/references/probe-lib/cdp.js \
   /Users/navid/code/browser/repro/<id>-<slug>/cdp.js
```

Then in your `probe.js`:

```js
const { connect, sleep } = require('./cdp.js');

(async () => {
  const c = await connect();
  await c.navigate('http://127.0.0.1:8765/');
  const onPage = await c.eval('document.body.innerText.includes("FIRST_PAGE")');
  if (!onPage) { console.log('FAIL: precondition'); process.exit(1); }
  await c.eval('document.querySelector("#submit").click()');
  const ok = await c.waitFor('window.location.href.includes("/submitted")');
  c.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
```

## Why raw `ws` and not `chrome-remote-interface`

c-r-i works for trivial Chrome probes but fights Lightpanda at every turn:

- `/json/list` returns `[]` so `await CDP({port: 9222})` errors with `No inspectable targets`. Workaround: `target: 'ws://...'`. Then…
- `/json/protocol` returns 404, so c-r-i errors looking up method descriptors. Workaround: `local: true`. Then…
- The default flow assumes a single implicit session, but Lightpanda requires `Target.createTarget` + `Target.attachToTarget` returning a `sessionId` that has to be passed on every subsequent call.

By the time you've worked around all three, the c-r-i benefit is gone. Raw `ws`
is shorter and clearer for our use case. The CDP protocol itself is just JSON
RPC — there's no value-add from c-r-i's typed wrappers when our probes only
touch `Runtime.evaluate`, `Page.navigate`, `Page.enable`, and a handful of others.
