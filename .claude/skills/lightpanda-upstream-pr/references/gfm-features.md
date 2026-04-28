# Advanced GFM features

GitHub Flavored Markdown supports several features beyond standard markdown. Use these where they add genuine value in issue / PR bodies (Steps 7 and 8). The mermaid diagrams the skill already mandates are the load-bearing example — the rest below are optional, used only when they reduce reviewer effort.

## `<kbd>` — keyboard shortcuts

Renders as styled raised key caps. Use in keybinding tables and setup instructions.

```markdown
Press <kbd>Cmd</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd> to open the palette.

| Action | Mac | Linux |
|--------|-----|-------|
| Save | <kbd>Cmd</kbd> + <kbd>S</kbd> | <kbd>Ctrl</kbd> + <kbd>S</kbd> |
```

## `<details>` / `<summary>` — collapsible sections

Use for long configuration references, changelogs, or optional deep-dives that would otherwise bulk up the top of the README. Put a blank line before markdown content inside `<details>` for it to render correctly.

```markdown
<details>
<summary>Advanced configuration options</summary>

| Option | Default | Description |
|--------|---------|-------------|
| `timeout` | `30` | Request timeout in seconds |

</details>
```

In an upstream issue/PR body, useful for full reproducer logs, multi-file Zig diffs that aren't strictly required to follow the argument, or `gh api` JSON dumps. Keep the visible body terse; tuck supporting evidence behind `<details>`.

## Mermaid diagrams

Use for architecture overviews, flow charts, sequence diagrams, ER diagrams, and Gantt charts. Renders as SVG inline.

````markdown
```mermaid
graph TD
    A[User] --> B[API Gateway]
    B --> C[Auth Service]
    B --> D[Data Service]
```
````

This skill already mandates two diagrams per fix — sequence diagram (broken vs. expected) in the issue body, flowchart (old vs. new code path) in the PR body. See `templates.md`.

## GeoJSON / TopoJSON maps

Renders an interactive Leaflet map. Useful for projects with a geographic component. Works both as a fenced block in a `.md` file and when browsing a `.geojson` file directly in GitHub.

````markdown
```geojson
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "geometry": { "type": "Point", "coordinates": [-122.4194, 37.7749] },
      "properties": { "name": "San Francisco" }
    }
  ]
}
```
````

## STL models

Renders an interactive 3D WebGL viewer. ASCII STL only for fenced blocks; binary `.stl` files also render when browsed on GitHub. Useful for hardware/electronics projects.

````markdown
```stl
solid cube
  facet normal 0 0 -1
    outer loop
      vertex 0 0 0
      vertex 1 0 0
      vertex 1 1 0
    endloop
  endfacet
endsolid cube
```
````

## SVG `<foreignObject>` — CSS animations

GitHub strips `<style>` tags from markdown but renders `<img src="file.svg">`. SVGs can contain `<foreignObject>` wrapping XHTML+CSS, enabling `@keyframes` animations, `prefers-color-scheme` media queries, and custom fonts. Embed images inside the SVG as base64 data URIs (external loads are blocked by CSP).

```xml
<!-- animation.svg -->
<svg xmlns="http://www.w3.org/2000/svg" width="400" height="80">
  <foreignObject width="400" height="80">
    <body xmlns="http://www.w3.org/1999/xhtml">
      <style>
        @keyframes fade { 0%,100% { opacity:1 } 50% { opacity:0.3 } }
        .t { font-family: monospace; animation: fade 2s infinite; }
      </style>
      <div class="t">animated text</div>
    </body>
  </foreignObject>
</svg>
```

Combine with `<picture>` for dark/light mode variants:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="header-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="header-light.svg">
  <img src="header-light.svg" alt="project header">
</picture>
```

## Color model swatches

Wrapping a color value in backticks renders a small color swatch preview next to it when GitHub detects the format. Supported in issues and PRs (rendering may vary in READMEs).

Supported formats: `` `#ffffff` `` `` `rgb(255, 255, 255)` `` `` `hsl(0, 0%, 100%)` ``

## Alerts

Callout blocks for notes, warnings, and tips. Use sparingly — one or two per README max.

```markdown
> [!NOTE]
> Useful information the reader should know.

> [!TIP]
> Helpful advice for doing things better.

> [!IMPORTANT]
> Key information users need to succeed.

> [!WARNING]
> Urgent info that needs immediate attention.

> [!CAUTION]
> Advises about risks or negative outcomes.
```

In upstream issue/PR bodies, `> [!NOTE]` works well for the "this PR explicitly defers X to a follow-up" callout, and `> [!WARNING]` for "this changes observable CDP behavior for clients that rely on the old shape". Don't stack more than two alerts in one body — at that point they stop being callouts.
