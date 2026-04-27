# Visual Verification of GitHub Markdown Rendering

Apply this after `gh issue create` (Step 7c) and after `gh pr create` (Step 8e). Mermaid diagrams, nested code fences, and HEREDOC escape edge cases break in subtle ways that look fine in the raw markdown but render wrong on GitHub. Two minutes of polishing the rendered page beats leaving a sloppy artifact for the maintainer to puzzle over.

## How to inspect

```
mcp__playwright__browser_navigate(url: "<issue or PR URL>")
mcp__playwright__browser_snapshot()        # accessibility snapshot — verifies structure
mcp__playwright__browser_take_screenshot() # pixel snapshot — verifies rendering
```

Use both: the accessibility snapshot proves mermaid blocks rendered as actual `svg`/graph nodes (not as `mermaid` code blocks), and the screenshot catches layout/contrast issues.

## Common checklist (issue and PR)

- **Mermaid diagrams render as graphs, not raw text inside a `mermaid` code block.** If they show as code, the fence syntax is wrong (extra blank line inside the fence, missing `mermaid` language tag, or a stray indent). The accessibility snapshot will show real `svg` / graph nodes when it works.
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
mcp__playwright__browser_navigate(url: "<URL>")
```

The skill is responsible for the **rendered** quality of the artifact, not just the source. Don't move on until the page reads cleanly to a Zig engineer who isn't on this conversation.
