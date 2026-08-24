# Visual Verification of GitHub Markdown Rendering

Apply this after `gh issue create` (Step 7c) and after `gh pr create` (Step 8e). Mermaid diagrams, nested code fences, and HEREDOC escape edge cases break in subtle ways that look fine in the raw markdown but render wrong on GitHub. Two minutes of polishing the rendered page beats leaving a sloppy artifact for the maintainer to puzzle over.

## How to inspect

Use `agent-browser` (the Playwright MCP is not wired into this setup — verified 2026-08-24). Issue/PR pages are public, so no `--session-name`:

```bash
agent-browser open "<issue or PR URL>"    # then sleep 3-4s: mermaid renders async
agent-browser eval "<JS checks below>"
agent-browser screenshot --full /tmp/render.png   # then Read the PNG
agent-browser close
```

DOM checks that settle each question in one `eval` (all verified 2026-08-24):

```js
// Mermaid: GitHub renders each diagram into a cross-origin iframe — success is
// measured on these three, NOT on svg counts (the parent document's svgs are octicons):
[...document.querySelectorAll('iframe.render-viewer')].map(f => f.offsetHeight)
  // one iframe per diagram, src viewscreen.githubusercontent.com, real heights (~180-500px)
/Unable to render rich display|Parse error/i.test(document.querySelector('.markdown-body').textContent)
  // parse failures surface as this banner in the PARENT document — must be false
[...document.querySelectorAll('.markdown-body pre')].filter(p => p.offsetParent !== null && /sequenceDiagram|flowchart/.test(p.textContent)).length
  // raw mermaid source stays in hidden <pre> fallbacks — visible count must be 0
// PR-only: "Closes #n" hyperlink + sidebar linkage:
[...document.querySelectorAll('.markdown-body a')].some(a => /issues\/<n>/.test(a.href))
// Leftovers: /<paste|<issue-num>|wishlist|[Cc]apybara|RSpec/.test(body.textContent) must be false
```

**Screenshot caveat**: the mermaid iframes are cross-origin and routinely paint as blank rectangles in a headless screenshot — a blank diagram area in the PNG is NOT evidence of a broken render. Trust the DOM checks for the diagrams; use the screenshot for everything else (tables, code highlighting, heading structure, overall read).

## Common checklist (issue and PR)

- **Mermaid diagrams render as graphs, not raw text inside a `mermaid` code block.** If they show as code, the fence syntax is wrong (extra blank line inside the fence, missing `mermaid` language tag, or a stray indent). Success = the three iframe/banner/hidden-pre checks above, not svg-counting.
- **Code blocks (`repro.html` / `repro.sh` / `repro.js`, Zig snippets) are syntax-highlighted** with no leaked backticks from outer-fence interference, no HEREDOC `EOF` artifact bleeding into the body, no broken indentation. Read the actual rendered code, not just the markdown.
- **Headings and TOC sidebar** match the H2 hierarchy you intended. No skipped levels, no `## ## Foo` artifacts from accidental double-prefix.
- **Inline code** (`Network.clearBrowserCookies`, `Page.loadEventFired`, `src/<file>.zig` paths) renders as code, not as bare text. Spec links resolve, no 404s in the link previews.
- **No template leftovers**: no `<paste full body>`, no `<id>`, no `<issue-num>` placeholders, no copy of the wishlist accidentally pasted in.

## Issue-only check (Step 7c)

- **Both sequence diagrams** (broken vs. expected) render. They're the fastest way for a Zig engineer to understand a bug they didn't write.

## PR-only checks (Step 8e)

- **Both flowchart mermaid blocks render** — root-cause flowchart (red nodes for the broken path via `style B fill:#fdd`) and fix flowchart (green nodes via `style B fill:#dfd`). Color is a nice-to-have; the diagram structure rendering at all is the must-have. If a node label is truncated or arrows overlap, simplify the diagram and re-publish.
- **`Closes #<n>` is hyperlinked**, not plain text. GitHub turns recognized closing keywords into a link to the linked issue with a hover preview. If it shows as plain text, the syntax is wrong (rare; covered by Step 8d's programmatic check, but visual confirmation is faster than reading JSON).
- **The "Linked issues" / "Development" sidebar** on the right shows the issue from Step 7. Same signal as 8d but visual.
- **The "Files changed" tab matches the Fix bullets** — if a file appears in the diff that isn't in the bullets, either the bullets are incomplete or the diff has unrelated noise.

## Fix-and-republish loop

If anything renders wrong or could read better — phrasing, diagram layout, missing context in any section — fix the markdown and re-publish:

```bash
# For an issue:
gh issue edit <issue-num> --repo lightpanda-io/browser --body-file <fixed.md>

# For a PR:
gh pr edit <pr-num> --repo lightpanda-io/browser --body-file <fixed.md>

# Then re-verify:
agent-browser open "<URL>"   # + the eval checks from "How to inspect"
```

The skill is responsible for the **rendered** quality of the artifact, not just the source. Don't move on until the page reads cleanly to a Zig engineer who isn't on this conversation.
