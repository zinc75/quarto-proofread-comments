# Quarto Comments Extension

The **Quarto Comments** extension adds collaboration-friendly annotations to Quarto documents. Authors can insert inline notes, to-dos, and discussion points that render as margin callouts in HTML outputs and as [`todonotes`](https://ctan.org/pkg/todonotes) in PDF/LaTeX builds. Comments can be toggled globally and customised per author or reviewer.

## Installation

```bash
quarto add zinc75/quarto-comments
```

The four shortcodes (`comment`, `todo`, `note`, `question`) become available as
soon as the extension is installed — there is no further enabling step. Adding a
[`extensions.quarto-comments` block](#configuration) to your front matter is
optional but recommended, to declare authors and tune the rendering.

To let a **non-inline comment placed mid-sentence** float into the margin in
HTML (instead of appearing as an inline badge), enable the bundled filter:

```yaml
filters:
  - comments
```

This is only needed for HTML; PDF places mid-sentence comments in the margin
either way. Comments on their own line do not require it.

## Screenshot

Here are sample renderings of the same document with comments in both HTML and PDF formats:

![HTML rendering with margin callouts and inline comments](sample-html.webp)

![PDF rendering with todo list and margin notes](sample-pdf.webp)

## Shortcodes

Four shortcodes — `comment`, `todo`, `note`, `question` — are available directly inside your document:

```markdown
{{< comment "Need to expand this section" author="vg" type="todo" >}}
{{< note "Cross-check with appendix" >}}
{{< todo "Update Table 2 after rerun" author="sm" >}}
{{< question "Can we validate with external data?" inline=true >}}
```

### Arguments

| Argument    | Type                                    | Description                                         |
|-------------|-----------------------------------------|-----------------------------------------------------|
| positional  | string                                  | Required comment text                               |
| `author`    | string                                  | Matches a key defined in the configuration          |
| `type`      | comment \| todo \| note \| question     | Controls styling for iconography and colours        |
| `inline`    | boolean                                 | Forces inline rendering instead of a margin callout |

`todo`, `note` and `question` are convenience shortcodes equivalent to `comment` with the matching `type` preset; all four share the same underlying logic.

> **Note:** The `author` value must not start with a space — `author="vg"` and `author="v g"` both work (internal spaces are ignored), but `author=" vg"` (leading space) is silently dropped by Quarto's shortcode parser before the extension sees it.

## Configuration

Options live under the `extensions.quarto-comments` key in the document front matter:

```yaml
---
title: "My Document"
format:
  html: default
  pdf: default
extensions:
  quarto-comments:
    enabled: true         # toggle comments globally (default: true)
    show_author: true     # show author labels (default: true)
    show_list: true       # prepend a styled list of all comments in PDF (default: false)
    connector: numbered   # in-text marker style: numbered (default) | bezier
    wide_margins: true    # extend page width for a dedicated annotation zone (default: false)
    # extra_margin: "6.5cm" # width added to the page (default: 6.5cm)
    # twocolumn_marginparwidth: "auto" # margin-note width in twocolumn, non-wide (default: "auto")
    authors:
      vg:
        name: "Vincent"
      cg:
        name: "Clara"
---
```

### Author colours

Three cases:

| Shortcode | Display name | Colour |
|-----------|-------------|--------|
| `author="vg"` declared in `authors:` | value of `name:` | auto-assigned from Bootstrap 5 palette, or manual override |
| `author="sm"` **not** declared in `authors:` | `sm` (the identifier itself) | auto-assigned from Bootstrap 5 palette |
| no `author` | *(none — label suppressed)* | default colour for the comment type |

Auto-assignment derives a distinct colour from the author's name using a hash into the Bootstrap 5 base palette (blue, indigo, purple, pink, red, orange, yellow, green, teal, cyan). No manual configuration is required.

To override, add `color_html` (CSS hex) and/or `color_latex` (xcolor spec) to the author entry:

```yaml
authors:
  vg:
    name: "Vincent"
    color_html: "#0072B2"
    color_latex: "blue!20"
```

### Other settings

- `enabled: false` strips all comment shortcodes from the output.
- `show_author: false` hides author labels on all comments.

### Draft layout (PDF)

Set `wide_margins: true` to extend the physical page width and reserve a dedicated annotation zone at the outer edge. The text body is completely unchanged — only extra paper is added to accommodate the notes.

```yaml
extensions:
  quarto-comments:
    wide_margins: true
    # extra_margin: "6.5cm"  # total width added to the page (default: 6.5cm)
    # inner_pad: "0.3cm"     # breathing room inside the zone on each side (default: 0.3cm)
    # frame_color: "gray!10" # background fill of the annotation zone (default: gray!10)
    # frame_line: "gray!60"  # colour of the dashed separator line (default: gray!60)
```

The annotation zone is displayed with a light grey background and a dashed vertical separator marking the original page boundary. A "Comments" label appears at the top of the zone.

This works whether or not the document loads the [`geometry`](https://ctan.org/pkg/geometry) package: the text block keeps exactly the position and width that `geometry` (or the default layout) assigns it — only extra paper and the annotation zone are added beyond it.

**One-sided documents**: the annotation zone always appears on the right.

**Two-sided documents** (`classoption: twoside`): the zone alternates sides — right on odd (recto) pages, left on even (verso) pages — so it always sits at the outer edge, away from the binding.

**Two-column documents** (`classoption: twocolumn`): the page is widened on **both** sides and an annotation zone is reserved at each edge, so first-column comments land in the left zone and second-column comments in the right zone (see [Two-column PDF](#two-column-pdf)).

Setting `enabled: false` restores the original page layout for final output — no trace of the annotation zone remains.

## Output Behaviour

### HTML

- Margin callouts styled as standard Quarto callouts, colourised per author.
- Icons use [Font Awesome 6](https://fontawesome.com/), injected automatically — no manual `include-in-header` needed.
- Inline comments (`inline=true`) render as compact badges that sit within text runs.
- **Mid-sentence comments**: a non-inline comment written in the middle of a sentence is moved into the margin (as a sidenote) without breaking the paragraph, provided the bundled filter is enabled with `filters: [comments]` (see [Installation](#installation)). Without the filter it degrades gracefully to an inline badge. This is handled by `comment-hoist.lua`, which the extension registers to run after shortcode expansion; it only affects HTML (PDF places mid-sentence comments in the margin natively).
- **In-text anchors**: every margin comment leaves a small clickable icon (in the author colour) at its position in the text, linked to its margin callout. Hovering either the icon or the callout highlights the other.

### PDF / LaTeX

- Comments render via the [`todonotes`](https://ctan.org/pkg/todonotes) package; inline comments use `\todo[inline]{...}`.
- Required LaTeX packages (`xcolor`, `todonotes`, `fontawesome5`) are injected automatically — no manual `include-in-header` needed.
- Icons use [Font Awesome 5](https://ctan.org/pkg/fontawesome5) in outline (regular) style, compatible with pdflatex, xelatex, and lualatex.
- Author colours are applied to the note background, border, and the in-text marker.
- **Connector style** (`connector`, default `numbered`): each margin comment shows a small clickable icon + number at its text position, linked to its note box, which repeats the same icon + number; comments are numbered in document order and the list of comments shows the same numbers. This needs no connecting line, so it is robust in one/two-sided, two-column, narrow-margin and page-break layouts. Set `connector: bezier` for the legacy smooth Bézier curve with a hollow circle at the text position instead.
- **List of comments**: set `show_list: true` to prepend a styled, clickable list of all comments (rounded dashed frame), numbered to match the in-text markers.
- **Draft layout**: set `wide_margins: true` to extend the page and give notes a dedicated, clearly delimited zone — see [Draft layout (PDF)](#draft-layout-pdf).

#### Two-column PDF

Two-column layouts (`classoption: twocolumn`) are supported and auto-detected — no extra configuration is required. The kernel places first-column notes in the left page margin and second-column notes in the right, and the extension adapts to that:

- **Without `wide_margins`**: the margin-note width is set automatically from the page geometry (the class default is far too narrow in two columns, which otherwise crushes the note text). Override it with `twocolumn_marginparwidth` (default `"auto"`).
- **With `wide_margins: true`**: the page is widened on both sides and a grey annotation zone is reserved at each edge, so no comment is pushed off the page.
- The in-text markers link correctly per column; in `connector: bezier` mode the curves also point to the correct side per column.

Single-column behaviour (one-sided and two-sided) is unchanged.

> **Known limitation — crowded margins / page breaks:** margin notes are placed
> by LaTeX's `\marginpar`, which floats a note to the next page when it does not
> fit and decides its side from the page being assembled. A note anchored right
> at a page break (e.g. just after a heading at the top of a page) can therefore
> be pushed onto a neighbour or land in the opposite margin. In the default
> numbered mode the in-text marker and its link stay correct (the number still
> identifies the note and the link still jumps to it) — only the box's placement
> is affected; in `connector: bezier` mode the curve then points at the displaced
> box. Giving notes more room avoids it — use `wide_margins: true`, or space out
> comments that fall near a page break.

### Other Formats

For formats other than HTML and PDF/LaTeX (e.g. `.docx`, EPUB), comments fall back to a plain-text representation rather than disappearing silently:

```
TODO (vg): Need to expand this section.
```

## Minimal Example

A runnable example document is included at `example.qmd`. From the repository root:

```bash
quarto render example.qmd --to html,pdf
```

The example demonstrates author configuration, automatic colour assignment, margin callouts, inline comments, and the comment list. Use it as a starting point when wiring the extension into your own projects.
