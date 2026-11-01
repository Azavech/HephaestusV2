#!/bin/bash
# Checks the docs (docs/ci.md › check-docs.sh): every docs file is linked from docs/README.md, every
# table is aligned, and the docs hold no personal data. Runs the three checks, prints their findings
# and exits with status 1 when any of them failed.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/check-docs.sh" >&2
  exit 2
fi

failed=0

# 1. Index: each .md file under docs/, except docs/README.md, is the target of an inline link
#    `](<target>)` of docs/README.md, <target> being its path relative to docs/, optionally prefixed
#    by `./` and followed by `#<fragment>`.
# DOC-GAP: docs/ci.md › check-docs.sh writes `<path> is not linked` without saying what <path> is
# relative to; it is the path relative to the repository root, like the paths of check-public.sh.
if [ ! -f docs/README.md ]; then
  echo "docs/README.md is missing"
  failed=1
else
  targets=$(grep -o '](\(\./\)\{0,1\}[^)#]*\(#[^)]*\)\{0,1\})' docs/README.md \
    | sed -e 's/^](//' -e 's/)$//' -e 's/#.*$//' -e 's|^\./||' || true)
  while IFS= read -r file; do
    relative=${file#docs/}
    if ! printf '%s\n' "$targets" | grep -q -x -F -e "$relative"; then
      echo "docs/README.md: $file is not linked"
      failed=1
    fi
  done < <(find docs -type f -name '*.md' ! -path docs/README.md | LC_ALL=C sort)
fi

# 2. Tables: scripts/tables.py --check on every .md file under docs/.
docs_files=()
while IFS= read -r file; do
  docs_files+=("$file")
done < <(find docs -type f -name '*.md' | LC_ALL=C sort)
if [ "${#docs_files[@]}" -gt 0 ]; then
  if ! python3 -I scripts/tables.py --check "${docs_files[@]}"; then
    failed=1
  fi
fi

# 3. Personal data: scripts/check-public.sh docs.
if ! scripts/check-public.sh docs; then
  failed=1
fi

exit "$failed"
