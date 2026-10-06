#!/usr/bin/env bash
# Apply atomic/patches/*.patch to the checked-out upstream tag, in name order.
#
# A patch named `ggml--<name>.patch` is applied inside the ggml submodule (git apply cannot
# reach into a submodule from the superproject); every other patch at the repository root.
set -euo pipefail
shopt -s nullglob

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches" && pwd)"
applied=0
for patch in "$dir"/*.patch; do
  name="$(basename "$patch")"
  case "$name" in
    ggml--*) target=ggml ;;
    *) target=. ;;
  esac
  echo "::group::git -C $target apply $name"
  git -C "$target" apply --verbose --whitespace=nowarn "$patch"
  echo "::endgroup::"
  applied=$((applied + 1))
done
echo "applied $applied patch(es)"
