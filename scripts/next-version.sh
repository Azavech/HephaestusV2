#!/bin/bash
# Computes the version and the build number of HEAD from the git history (docs/ci.md › Versioning).
# Prints three lines for $GITHUB_OUTPUT: version=X.Y.Z, build=N and previous_tag=vX.Y.Z (or empty).
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 0 ]; then
  echo "usage: scripts/next-version.sh" >&2
  exit 2
fi

if [ "$(git rev-parse --is-inside-work-tree 2> /dev/null || true)" != "true" ] \
  || [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "next-version.sh: the whole git history is needed" >&2
  exit 1
fi

version_tag='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# The highest version tag read on standard input, ordered by major, minor and patch as numbers.
highest_tag() {
  { grep -E "$version_tag" || true; } \
    | sed 's/^v//' \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n \
    | tail -n 1 \
    | sed 's/^\(.\)/v\1/'
}

build=$(git rev-list --count HEAD)
tags_at_head=$(git tag --points-at HEAD)
head_tag=$(printf '%s\n' "$tags_at_head" | highest_tag)
# The tags merged into HEAD, without those that point at HEAD.
previous_tag=$(git tag --merged HEAD | { grep -v -x -F -e "$tags_at_head" || true; } | highest_tag)

if [ -n "$head_tag" ]; then
  # The commit is already tagged: its version is reused.
  version=${head_tag#v}
else
  base=${previous_tag#v}
  if [ -z "$base" ]; then
    base=0.0.0
  fi
  major=${base%%.*}
  rest=${base#*.}
  minor=${rest%%.*}
  patch=${rest#*.}

  if [ -n "$previous_tag" ]; then
    range="$previous_tag..HEAD"
  else
    range=HEAD
  fi

  # 0 patch, 1 minor, 2 major: the highest bump any commit asks for.
  bump=0
  major_subject='^[A-Za-z]+(\([^()]*\))?!:'
  minor_subject='^feat(\([^()]*\))?:'
  while IFS= read -r -d '' message || [ -n "$message" ]; do
    subject=${message%%$'\n'*}
    if [[ $subject =~ $major_subject ]] || [[ $message == *"BREAKING CHANGE"* ]]; then
      bump=2
      break
    elif [[ $subject =~ $minor_subject ]]; then
      bump=1
    fi
  done < <(git log -z --format=%B "$range")

  case $bump in
    2) version="$((major + 1)).0.0" ;;
    1) version="$major.$((minor + 1)).0" ;;
    *) version="$major.$minor.$((patch + 1))" ;;
  esac
fi

echo "version=$version"
echo "build=$build"
echo "previous_tag=$previous_tag"
