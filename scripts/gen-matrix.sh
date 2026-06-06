#!/usr/bin/env bash
# Generate the curated PDF-configuration wrappers (examples/pdf/<slug>.qmd) and the
# Examples landing page (examples/index.qmd). The set below is a HAND-PICKED subset
# of the one/two-sided × normal/wide margins × one/two columns × numbered/bezier
# space — only the configurations worth showcasing. Re-run after editing the list;
# output is static (committed), NOT generated in CI.
set -euo pipefail
cd "$(dirname "$0")/.."   # docs root

OUT=examples/pdf
INDEX=examples/index.qmd
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -name '*.qmd' -delete   # keep _metadata.yml

# Curated configurations to showcase, as <side>-<margin>-<col>-<connector> slugs.
# The first one is the default/recommended combination.
configs=(
  oneside-wide-1col-numbered
  oneside-wide-1col-bezier
  oneside-wide-2col-numbered
  twoside-wide-1col-numbered
  twoside-nonwide-1col-numbered
  twoside-nonwide-1col-bezier
)

cat > "$INDEX" <<'HEAD'
---
title: "Examples — PDF configurations"
---

The same manuscript (`example.qmd`, pulled from `main`) rendered under a few
representative PDF configurations, so you can see how the layout options behave.
For the interactive version with hover and links, see the
[live HTML demo](../example.html).

## Choosing your options

- **The defaults are the safest combination — start here.** `connector: numbered`
  with `wide_margins: true` handles one- and two-sided, one- and two-column, and
  page breaks robustly.
- **Avoid `connector: bezier` in two-column layouts.** The curved connector can
  overflow or fail when a margin note floats across a column or page boundary;
  the numbered marker stays correct there.
- **Use `wide_margins: false` only with few, short annotations.** A normal-width
  margin quickly cramps notes — long reviewer names or several stacked notes will
  not fit. (Wide margins reserve a dedicated, roomy annotation zone.)
- **For long comment text, use the inline form** (`inline=true`) instead of a
  margin note, so the text flows in the body rather than overflowing a narrow
  margin.

## The configurations

```{=html}
<div class="cfg-grid">
HEAD

count=0
for slug in "${configs[@]}"; do
  IFS='-' read -r side margin col conn <<< "$slug"

  classopt="$side"
  [ "$col" = "2col" ] && classopt="${side}, twocolumn"
  widev=true; [ "$margin" = "nonwide" ] && widev=false

  coltxt="1 column";       [ "$col" = "2col" ]       && coltxt="2 columns"
  margtxt="wide margins";  [ "$margin" = "nonwide" ] && margtxt="normal margins"
  label="${side} · ${margtxt} · ${coltxt} · ${conn}"
  badge=""
  [ "$count" -eq 0 ] && badge=' <span class="cfg-badge">default</span>'

  # include-in-header snippets, combined into ONE block (YAML allows the key once).
  # Showcase cheat for NON-WIDE margins: widen the page ~5mm/side and the marginpar
  # so the demo's long reviewer names fit (wide mode already has the big zone).
  geom_snippet='\usepackage{geometry}
\geometry{textwidth=\dimexpr\textwidth-1cm\relax,marginparwidth=\dimexpr\marginparwidth+5mm\relax}'
  # TWO-COLUMN: markdown tables become longtable, which cannot typeset in twocolumn;
  # this shim briefly switches to onecolumn so the table spans the page.
  hack_snippet=$(cat <<'HACK'
\makeatletter
\let\oldlt\longtable
\let\endoldlt\endlongtable
\def\longtable{\@ifnextchar[\longtable@i \longtable@ii}
\def\longtable@i[#1]{\begin{figure}[h]
\onecolumn
\begin{minipage}{0.5\textwidth}
\oldlt[#1]
}
\def\longtable@ii{\begin{figure}[h]
\onecolumn
\begin{minipage}{0.5\textwidth}
\oldlt
}
\def\endlongtable{\endoldlt
\end{minipage}
\twocolumn
\end{figure}}
\makeatother
HACK
)
  hdr=""
  [ "$margin" = "nonwide" ] && hdr="${geom_snippet}"
  if [ "$col" = "2col" ]; then
    if [ -n "$hdr" ]; then hdr="${hdr}"$'\n'"${hack_snippet}"; else hdr="${hack_snippet}"; fi
  fi

  {
    echo "---"
    # title + author come from examples/pdf/_metadata.yml (mirroring example.qmd);
    # here we only set the per-config subtitle.
    echo "subtitle: \"${label}\""
    echo "format:"
    echo "  pdf:"
    echo "    classoption: [${classopt}]"
    if [ -n "$hdr" ]; then
      echo "    include-in-header:"
      echo "      text: |"
      printf '%s\n' "$hdr" | sed 's/^/        /'
    fi
    # Full extension config per wrapper (Quarto does not deep-merge the nested
    # extensions map from _metadata.yml, so reviewers must be inline here). Only
    # connector + wide_margins vary; reviewers mirror example.qmd, block syntax.
    echo "extensions:"
    echo "  quarto-proofread-comments:"
    echo "    enabled: true"
    echo "    show_list: true"
    echo "    list_title: \"Annotations\""
    echo "    connector: ${conn}"
    echo "    wide_margins: ${widev}"
    cat <<'REV'
    reviewers:
      sup:
        name: "Prof. Halvorsen"
        color_html: "#0072B2"
        color_latex: "blue!20"
      r2:
        name: "John Chief"
        color_html: "#D55E00"
        color_latex: "orange!35"
      co:
        name: "Dr. Marchetti"
      ed:
        name: "Copy-editor"
        color_html: "#CC79A7"
        color_latex: "magenta!25"
REV
    echo "---"
    echo ""
    echo "{{< include ../../_example-body.qmd >}}"
  } > "$OUT/$slug.qmd"

  cat >> "$INDEX" <<CARD
<div class="cfg-card">
<div class="cfg-card-head">${label}${badge}</div>
<a class="cfg-thumb" href="pdf/${slug}.pdf"><img src="pdf/${slug}.thumb.png" alt="${label}"></a>
<a class="cfg-pdf" href="pdf/${slug}.pdf"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M.5 9.5a.5.5 0 0 1 .5.5v2a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2a.5.5 0 0 1 1 0v2a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-2a.5.5 0 0 1 .5-.5z"/><path d="M7.646 11.354a.5.5 0 0 0 .708 0l3-3a.5.5 0 0 0-.708-.708L8.5 9.793V1.5a.5.5 0 0 0-1 0v8.293L5.354 7.646a.5.5 0 1 0-.708.708l3 3z"/></svg> View PDF</a>
</div>
CARD

  count=$((count + 1))
done

printf '</div>\n```\n' >> "$INDEX"
echo "gen-matrix: wrote ${count} wrappers in ${OUT} and ${INDEX}"
