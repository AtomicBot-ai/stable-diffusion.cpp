#!/usr/bin/env bash
# package-linux.sh <build/bin> <out-dir> [cuda-home]
#
# Lay out a flat, symlink-free archive tree from a Linux build:
#   - every unversioned file of build/bin (executables, libstable-diffusion.so, and the
#     libggml-*.so backend modules, which ggml's loader finds by that plain name);
#   - each versioned soname (libggml.so.0, ...) only where an ELF in the tree needs it;
#   - the CUDA runtime sonames libggml-cuda.so needs, copied from the toolkit.
# Symlinks are dereferenced because Atomic Chat's unzip writes a link out as a plain file.
set -euo pipefail

bin="$1"
out="$2"
cuda_home="${3:-}"

rm -rf "$out"
mkdir -p "$out"

for f in "$bin"/*; do
  name="$(basename "$f")"
  case "$name" in *.so.*) continue ;; esac
  [ -f "$f" ] && cp -L "$f" "$out/$name"
done

cuda_libs=()
if [ -n "$cuda_home" ]; then
  for d in "$cuda_home/targets/sbsa-linux/lib" "$cuda_home/lib64"; do
    [ -d "$d" ] && cuda_libs+=("$d")
  done
fi

needed() {
  for e in "$out"/*; do
    readelf -d "$e" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
  done | sort -u
}

# A fixed point: a copied library can need another one.
for _ in 1 2 3 4; do
  added=0
  for so in $(needed); do
    [ -e "$out/$so" ] && continue
    if [ -e "$bin/$so" ]; then
      cp -L "$bin/$so" "$out/$so"
      added=1
      continue
    fi
    for d in "${cuda_libs[@]}"; do
      if [ -e "$d/$so" ]; then
        cp -L "$d/$so" "$out/$so"
        added=1
        break
      fi
    done
  done
  [ "$added" = 0 ] && break
done

# Run from the source root, like upstream's packaging step.
cp ggml/LICENSE "$out/ggml.txt"
cp LICENSE "$out/stable-diffusion.cpp.txt"
