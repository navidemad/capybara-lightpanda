# docs/

Marketing + landing site for `capybara-lightpanda`. Hugo static site, deployed to GitHub Pages at `https://navidemad.github.io/capybara-lightpanda/`.

## Local dev

```bash
bin/website        # repo root — runs `mise exec -- hugo server --disableFastRender` from docs/
```

`hugo` is provided via `mise`. SCSS is transpiled with **dart-sass** (`transpiler: "dartsass"` in `head.html`) — node-sass / libsass shorthands won't work. Production builds minify and fingerprint the CSS bundle.

## Layout

- `hugo.toml` — site config. `disableKinds` strips taxonomy/RSS/sitemap; the only output is `home = ["HTML"]`. `markup.goldmark.renderer.unsafe = true` is required so the inline HTML in `content/_index.md` renders.
- `content/_index.md` — markdown for the `Pair with Cuprite` section (chapter 03). It's injected into `layouts/index.html` via `{{ .Content }}` inside `<main id="main" class="content">`. The rest of the page lives in `index.html`, not in markdown.
- `content/docs.md` — separate page (not yet wired into nav).
- `layouts/index.html` — the entire homepage (hero, why, swap, pair, matrix, beta, footer, chapter index). All page-level JS lives inline at the bottom of this file. **One file, ~1200 lines** — that's intentional, not tech debt to clean up.
- `layouts/partials/head.html` — meta + Google Fonts preconnect + SCSS pipeline (dart-sass → minify+fingerprint in prod).
- `layouts/partials/nav.html` — top nav.
- `layouts/_default/single.html` + `_markup/render-{heading,table}.html` — markdown rendering hooks (anchor links on headings, wrapped tables).

## SCSS conventions

`assets/css/main.scss` is the entry point. It `@use`s 25 numbered partials in `parts/_NN-name.scss`. **Cascade order is preserved by the numeric prefix — do not reorder lightly.** When adding a new partial:

1. Pick the next free number (currently 26).
2. Create `parts/_26-foo.scss`.
3. Add `@use "parts/26-foo" as *;` at the bottom of `main.scss`.

Each partial owns one section/component (hero, why, swap, matrix, beta, endrail, etc.) — keep them scoped to that BEM block.

## Inline JS in index.html

The `<script>` block at the bottom of `layouts/index.html` is a series of self-contained IIFEs, each handling one concern (chapter wrapping, smooth-scroll, scroll reveals, scroll-spy, parallax, GitHub stars, magnetic CTA, stat count-up, copy-to-clipboard). They all bail early if the target element is missing or `prefers-reduced-motion` is set. Keep new effects in the same shape — one IIFE, one job, no shared globals.

The first IIFE (chapter wrapping) is load-bearing: it converts the markdown's `<h2 id="...">` siblings into `<section class="chapter">` wrappers so the chapter ribbon (`_25-chapter-ribbon.scss`) and snap-scroll work. Don't remove it without also rewriting the markdown rendering.

## Don't touch

- `public/` — Hugo build output, gitignored.
- `resources/` — Hugo's SCSS asset cache, gitignored.
- `.hugo_build.lock` — Hugo runtime lock, gitignored.
