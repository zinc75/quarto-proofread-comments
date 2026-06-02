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
    wide_margins: true    # extend page width for a dedicated annotation zone (default: false)
    # extra_margin: "6.5cm" # width added to the page (default: 6.5cm)
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

Setting `enabled: false` restores the original page layout for final output — no trace of the annotation zone remains.

## Output Behaviour

### HTML

- Margin callouts styled as standard Quarto callouts, colourised per author.
- Icons use [Font Awesome 6](https://fontawesome.com/), injected automatically — no manual `include-in-header` needed.
- Inline comments render as compact badges that sit within text runs.

### PDF / LaTeX

- Comments render via the [`todonotes`](https://ctan.org/pkg/todonotes) package; inline comments use `\todo[inline]{...}`.
- Required LaTeX packages (`xcolor`, `todonotes`, `fontawesome5`) are injected automatically — no manual `include-in-header` needed.
- Icons use [Font Awesome 5](https://ctan.org/pkg/fontawesome5) in outline (regular) style, compatible with pdflatex, xelatex, and lualatex.
- Author colours are applied to the note background, border, and connecting line.
- The connection between a comment anchor and its margin note is a smooth Bézier curve with a hollow circle at the text position.
- **List of comments**: set `show_list: true` to prepend a styled, clickable list of all margin comments (rounded dashed frame). Inline comments are excluded.
- **Draft layout**: set `wide_margins: true` to extend the page and give notes a dedicated, clearly delimited zone — see [Draft layout (PDF)](#draft-layout-pdf).

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
