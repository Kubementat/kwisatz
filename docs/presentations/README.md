# Presentations

Onboarding decks for the repo. Each one is a single self-contained [Reveal.js](https://revealjs.com)
file loaded from a CDN — no build step, no dependencies to install.

## running-the-test-suite.html

How the test ladder works and how to run every layer of it: static analysis (shellcheck, ruff),
the repo guards in `tests/lint.sh`, the pytest layer, and the VM integration/idempotency suite in
`tests/run-vm-tests.sh`. 20 slides, ends with a cheat sheet.

```bash
# open it directly
xdg-open docs/presentations/running-the-test-suite.html

# or serve it (needed if you want to share it on the LAN)
python3 -m http.server -d docs/presentations 8000
# → http://localhost:8000/running-the-test-suite.html
```

Keys: `→`/`←` navigate, `Esc` overview, `s` speaker notes, `b` black screen, `?` help.
Slides are laid out on a 1280×760 canvas; a small auto-fit script shrinks any slide that would be
taller instead of clipping it (re-check the copy if the console reports a shrink below ~0.85).
To export: open `running-the-test-suite.html?print-pdf` and print to PDF (landscape, no margins).

## Editing

* Slides are `<section>` elements inside `<div class="reveal"><div class="slides">`; the slide
  counter in the `<div class="foot">` footer is hand-written, keep it in sync when adding one.
* Reusable pieces live in the `<style>` block: `.term` (terminal window), `.card` (+
  `accent-*`), `.grid g2/g3/g4`, `.flow`, `.pyr`, `.tag ok/bad/warn`, `.kicker`.
* Terminal output that needs inline colour is a plain `<pre class="raw">` with
  `<span class="ok|bad|warn|cmt|mut">` markup. Do **not** wrap those in `<code class="language-*">`:
  highlight.js escapes existing markup and the spans show up literally.
* Real shell commands go in `<pre><code class="language-bash">` so highlight.js colours them.
* Keep every slide within the 760 px canvas (auto-fit will shrink it instead of clipping, but the
  text then gets small). Check with a headless Chrome measurement, or just eyeball `Esc` overview.
* Content must match the repo: verify commands against `tests/README.md`,
  `specification/project/test-strategy.md` and the scripts themselves when you touch a slide.
