# Quarto Proofread Comments Extension

The **Quarto Proofread Comments** extension adds collaboration-friendly annotations to Quarto documents. You can **insert** a margin note anywhere, or **highlight a span of existing text and attach a note to it** — as comments, to-dos, notes, or questions. Annotations render as styled margin callouts and flowing in-text marks in HTML, as [`todonotes`](https://ctan.org/pkg/todonotes) margin notes + marker-pen highlights in PDF/LaTeX, and as plain text elsewhere. They can be toggled globally and coloured per reviewer.

## Installation

```bash
quarto add zinc75/quarto-proofread-comments
```

Then enable the bundled filter in your document front matter — it is the single entry point that does all the rendering:

```yaml
filters:
  - proofread-comments
```

Declaring reviewers and tuning the rendering via an [`extensions.quarto-proofread-comments` block](#configuration) is optional but recommended.

## Syntax

Annotations use pandoc **bracketed-span** syntax — `[…]{.comment …}`:

```markdown
Empty brackets INSERT a comment in the margin []{.comment by="vg" remark="A remark."}.

Wrapping text HIGHLIGHTS it and attaches the note to that span:
[this passage]{.comment by="vg" remark="A remark about the highlighted text."}.

An inline badge stays in the running text []{.comment by="vg" inline=true remark="Quick aside."}.
```

| Attribute | Values | Description |
|-----------|--------|-------------|
| *(bracket content)* | empty / text | **empty** → inserted comment; **text** → highlight that text |
| `remark` | string | the comment text shown in the margin (Markdown and `$maths$` are rendered) |
| `type` | `comment` \| `todo` \| `note` \| `question` | icon + colour family (default `comment`) |
| `by` | string | the reviewer; matches a key in the configuration, sets the colour and label |
| `inline` | boolean | empty bracket only: render an inline badge instead of a margin note |

- `type` and `by` are independent: a `todo` by `vg` shows the to-do icon in Vincent's colour.
- The **highlighted text** may contain maths. In PDF, prose is highlighted with a flowing marker and each formula (inline, `$$…$$`, or a system) is highlighted via a dedicated maths path — automatically, even when text and maths are mixed.

## Configuration

Options live under `extensions.quarto-proofread-comments` in the front matter. Everything has a sensible default, so a minimal setup just declares your reviewers:

```yaml
---
title: "My Document"
format:
  html: default
  pdf: default
filters:
  - proofread-comments
extensions:
  quarto-proofread-comments:
    reviewers:
      vg:
        name: "Vincent"
      cg:
        name: "Clara"
---
```

All options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | toggle all annotations; `false` strips them entirely (final submission) |
| `show_author` | boolean | `true` | show the reviewer label on each comment |
| `show_list` | boolean | `false` | PDF: prepend a styled, clickable list of all comments |
| `list_title` | string | `Annotations` | title of that list |
| `connector` | `numbered` \| `bezier` | `numbered` | PDF in-text marker for inserted comments: clickable icon + number, or a Bézier curve |
| `inline_style` | `flow` \| `box` | `flow` | PDF inline badges: flowing badge, or the legacy `\todo[inline]` box |
| `wide_margins` | boolean | `true` | widen the page and reserve a margin annotation zone (see [Draft layout](#draft-layout-pdf)) |
| `marginpar_fix` | boolean | `true` | load [`mparhack`](https://ctan.org/pkg/mparhack) to fix the two-sided `\marginpar` side bug; set `false` if it clashes with your class/template |
| `extra_margin` | length | `6.5cm` | width added to the page in wide mode |
| `inner_pad` | length | `0.3cm` | padding inside the annotation zone, each side |
| `frame_color` | xcolor spec | `gray!10` | background fill of the annotation zone |
| `frame_line` | xcolor spec | `gray!60` | colour of the dashed separator line |
| `twocolumn_marginparwidth` | length \| `auto` | `auto` | margin-note width in two-column, non-wide layouts |
| `reviewers` | map | *(none)* | per-reviewer `name`, with optional `color_html` / `color_latex` (see below) |

### Reviewer colours

| Comment | Display name | Colour |
|---------|--------------|--------|
| `by="vg"`, declared in `reviewers:` | the entry's `name:` | manual override, else auto-assigned from a Bootstrap-5 palette |
| `by="sm"`, **not** declared | `sm` (the identifier) | auto-assigned from the palette |
| **no `by`** | *(none — label suppressed)* | **neutral grey**, regardless of `type` |

Auto-assignment hashes the name into the palette, so each reviewer gets a distinct, stable colour with no configuration — and the **same** colour is used in HTML and PDF. To override:

```yaml
reviewers:
  vg:
    name: "Vincent"
    color_html: "#0072B2"
    color_latex: "blue!20"
```

### Other settings

- `enabled: false` strips every annotation (no styling, no packages, no leftover assets) for final output.
- `show_author: false` hides the reviewer label on every comment.
- `marginpar_fix: false` skips loading `mparhack` — use it if that package clashes with your document class/template (it rewrites the LaTeX output routine, which cannot be tested against every possible template).

### Draft layout (PDF)

`wide_margins: true` (the default) widens the physical page and reserves a dedicated annotation zone at the outer edge, leaving the text block exactly where `geometry` (or the class default) puts it. The zone has a light grey background, a dashed separator at the original page boundary, and a label.

- **One-sided**: zone on the right.
- **Two-sided** (`classoption: twoside`): zone alternates to the outer edge (right on recto, left on verso).
- **Two-column** (`classoption: twocolumn`): the page is widened on **both** sides with a zone at each edge.

Set `wide_margins: false` for normal page margins; `extra_margin`, `inner_pad`, `frame_color` and `frame_line` tune the zone.

## Output behaviour

### HTML

- **Inserted comments** render as Quarto-style margin callouts, coloured per reviewer, each leaving a small clickable in-text anchor. A comment written mid-sentence floats to the margin without breaking the paragraph.
- **Highlights** mark the text with a flowing marker-pen background (an irregular tinted gradient that breaks across lines); the highlight itself is the clickable anchor to its margin note.
- **Inline badges** (`inline=true`) are compact, coloured, and flow/break with the text.
- **Hover** an anchor or a highlight (or its callout) and the other is emphasised.
- Font Awesome, the styles and the hover script are injected automatically.

### PDF / LaTeX

- **Inserted comments** use [`todonotes`](https://ctan.org/pkg/todonotes) margin notes. The in-text marker is a clickable icon + number with an arrow to the insertion point (`connector: numbered`, default), or a Bézier curve (`connector: bezier`).
- **Highlights** use the [`highlightx`](https://ctan.org/pkg/highlightx) package for a flowing marker-pen effect (prose via `soul`, formulas via a dedicated maths path). Their in-text marker is a superscript number at the end of the span, with **no arrow** — the highlight already shows the range.
- **Inline badges** (`inline_style: flow`, default) are a flowing rounded badge (`soul`/`soulpos`); `inline_style: box` is the legacy `\todo[inline]`.
- `show_list: true` prepends a clickable list of all comments (titled via `list_title`), numbered to match the markers.
- Required packages (`xcolor`, `todonotes`, `fontawesome5`, `mparhack`, and `soul`/`soulpos`/`tcolorbox`/`highlightx` as needed) are injected automatically; works with pdflatex, xelatex and lualatex.

> **Known limitation — `\marginpar` placement.** Margin notes are placed by LaTeX's `\marginpar`, which can float a note that does not fit and decides its side in the output routine. `mparhack` (loaded by default) corrects the side, but a note crowded right at a page or column break can still be displaced. In `numbered` mode the in-text marker and its link stay correct. Give notes room (`wide_margins`, on by default) or space out comments near breaks.

### Other formats

For formats other than HTML and PDF (e.g. `.docx`, EPUB), annotations fall back to plain text rather than disappearing — highlighted text is kept and the note is appended in brackets.

## Example

A runnable example is included at `example.qmd`. From the repository root:

```bash
quarto render example.qmd --to html,pdf
```

It demonstrates inserted comments, highlights (of text, of a formula, and of a system), inline badges, the four comment types, reviewer colours (declared, undeclared, and none), and the comment list.

## Credits

This extension started as a fork of [`quarto-comments`](https://github.com/vgreg/quarto-comments) by **Vincent Grégoire**, whose original margin-comment extension is the basis and inspiration for this work. Released under the MIT License (see [`LICENSE`](LICENSE)).
