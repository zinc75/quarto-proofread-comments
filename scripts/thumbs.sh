#!/usr/bin/env bash
# Build one thumbnail per PDF: a 2x2 montage of the first four pages (page 1 is
# the annotation list, page 2+ the manuscript) where each page is a "card" with a
# thin edge and a soft drop shadow — so the gallery shows the layout at a glance.
# Click-through to the full PDF is wired in examples/index.qmd.
#
# Requires poppler (pdftoppm) and ImageMagick 6 or 7 (magick / convert).

set -euo pipefail
cd "$(dirname "$0")/.."   # docs root
DIR="${1:-_site/examples/pdf}"

# Compat ImageMagick 6 (convert) et 7 (magick)
if command -v magick &>/dev/null; then
  IM="magick"
elif command -v convert &>/dev/null; then
  IM="convert"
else
  echo "ImageMagick introuvable" >&2; exit 1
fi

shopt -s nullglob
for pdf in "$DIR"/*.pdf; do
  slug="$(basename "${pdf%.pdf}")"
  tmp="$(mktemp -d)"
  pdftoppm -png -r 90 -f 1 -l 4 "$pdf" "$tmp/p"
  # Each page -> a card: thin grey edge + soft drop shadow on transparency.
  i=0
  for pg in "$tmp"/p-*.png; do
    i=$((i + 1))
    $IM "$pg" -resize 700x \
      -bordercolor white -border 2 -bordercolor '#9aa0a6' -border 1 \
      \( +clone -background black -shadow 55x4+2+3 \) +swap \
      -background none -layers merge +repage "$tmp/card-$(printf '%02d' "$i").png"
  done
  # Assemble a 2-column grid WITHOUT montage (montage needs a font even for empty
  # labels, which fails on a font-less ImageMagick / CI). +smush = horizontal,
  # -smush = vertical join; works for any number of cards (last row may be partial).
  cards=( "$tmp"/card-*.png )
  rows=()
  k=0
  for ((j = 0; j < ${#cards[@]}; j += 2)); do
    row="$tmp/row-${k}.png"; k=$((k + 1))
    if [ $((j + 1)) -lt ${#cards[@]} ]; then
      $IM "${cards[j]}" "${cards[j + 1]}" -background none +smush 24 "$row"
    else
      cp "${cards[j]}" "$row"
    fi
    rows+=( "$row" )
  done
  $IM "${rows[@]}" -background none -smush 24 -background white -flatten \
    "$DIR/${slug}.thumb.png"
  rm -rf "$tmp"
  echo "thumbs: ${slug}.thumb.png"
done
echo "thumbs: done in ${DIR}"