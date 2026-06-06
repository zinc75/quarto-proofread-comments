#!/usr/bin/env bash
# Populate the docs build tree with the bits that live on `main` (the package
# branch): the extension itself, the full example.qmd (for the live HTML demo),
# and the front-matter-less manuscript body used by the 16 PDF wrappers.
#
# These outputs are EPHEMERAL — gitignored on the docs branch, regenerated on
# every build. Single source of truth = main. Works both locally (the docs
# worktree shares the same .git as the package worktree) and in CI (main is a
# branch of the same repo). Override the ref with MAIN_REF when the package
# branch is not yet named `main`, e.g.:
#
#   MAIN_REF=rename/quarto-proofread-comments scripts/populate.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # docs root

MAIN_REF="${MAIN_REF:-main}"
echo "populate: pulling extension + example from '${MAIN_REF}'"

# 1. The extension (filters: [proofread-comments] resolves _extensions/).
rm -rf _extensions
git archive "${MAIN_REF}" _extensions | tar -x

# 2. The full example, for the interactive HTML demo (renders to example.html).
git show "${MAIN_REF}:example.qmd" > example.qmd

# 3. The manuscript body only (front matter stripped), shared by the 16 wrappers.
#    Treat only the FIRST two `---` lines as the YAML delimiters.
git show "${MAIN_REF}:example.qmd" \
  | awk 'f>=2{print} /^---[[:space:]]*$/{f++}' > _example-body.qmd

echo "populate: wrote _extensions/, example.qmd, _example-body.qmd"
