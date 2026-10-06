#!/usr/bin/env bash
# Hardware check of the Atomic arm64 stable-diffusion.cpp builds on arm64 Linux with NVIDIA
# (DGX Spark / GB10, GH200). The Linux twin of verify-spark.ps1:
#   1. system facts and nvidia-smi;
#   2. linux-cuda13-arm64 and linux-cpu-arm64 of release @TAG@, checked against SHA256SUMS;
#   3. sd-cli --list-devices must show a CUDA device;
#   4. a 512x512 Z-Image Turbo image on the GPU (sampling GPU load), the same prompt at 256x256 on
#      the CPU build;
#   5. --video: a short Wan 2.2 TI2V 5B clip on the GPU.
# Report: ~/sd-verify/report.txt. Models are cached in ~/sd-verify-cache.
#
#   curl -fsSL https://github.com/@REPO@/releases/download/@TAG@/verify-spark.sh | bash -s -- [--video] [--quick] [--skip-cpu]
set -uo pipefail

TAG="@TAG@"
REPO="@REPO@"
VIDEO=0 QUICK=0 SKIP_CPU=0
for arg in "$@"; do
  case "$arg" in
    --video) VIDEO=1 ;;
    --quick) QUICK=1 ;;
    --skip-cpu) SKIP_CPU=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

SHORT="${TAG##*-}"
CACHE="${SD_VERIFY_CACHE:-$HOME/sd-verify-cache}"
OUT="$HOME/sd-verify"
REPORT="$OUT/report.txt"
mkdir -p "$CACHE" "$OUT"
echo "Atomic stable-diffusion.cpp arm64 check  $(date -Is)  tag $TAG" > "$REPORT"
RESULTS=()

say() { echo "$*" | tee -a "$REPORT"; }
section() { say ""; say "=== $*"; }
result() { local mark=FAIL; [ "$2" = 1 ] && mark=PASS; RESULTS+=("$mark  $1  $3"); say "$mark  $1  $3"; }

fetch() { # url file [sha256]
  local url="$1" file="$2" sha="${3:-}"
  if [ -f "$file" ] && [ -n "$sha" ] && [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$sha" ]; then return 0; fi
  echo "downloading $url"
  curl -L --fail --retry 5 --retry-delay 5 -C - -o "$file" "$url" || { echo "download failed: $url"; return 1; }
  if [ -n "$sha" ] && [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$sha" ]; then rm -f "$file"; echo "sha256 mismatch: $url"; return 1; fi
}

run_sd() { # log exe args...
  local log="$1"; shift
  local exe="$1"; shift
  local start end
  start=$(date +%s.%N)
  ( cd "$(dirname "$exe")" && LD_LIBRARY_PATH="$(dirname "$exe")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$exe" "$@" ) > "$log" 2>&1
  RUN_CODE=$?
  end=$(date +%s.%N)
  RUN_SECONDS=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.1f", b - a }')
}

finish() {
  section "Summary"
  local failed=0
  for r in "${RESULTS[@]}"; do say "$r"; case "$r" in FAIL*) failed=$((failed + 1)) ;; esac; done
  say ""
  if [ "$failed" = 0 ]; then say "ALL PASS"; else say "$failed FAILED - send $REPORT and the *.log files in $OUT"; fi
}
trap finish EXIT

# --- 1. system ---------------------------------------------------------------------------------
section "System"
say "OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"), kernel $(uname -r)"
say "CPU: $(lscpu 2>/dev/null | sed -n 's/^Model name:\s*//p' | sort -u | paste -sd, -) ($(nproc) threads)"
say "RAM: $(awk '/MemTotal/ { printf "%.1f GB", $2 / 1048576 }' /proc/meminfo)"
arch="$(uname -m)"
result "aarch64 host" "$([ "$arch" = aarch64 ] && echo 1 || echo 0)" "uname -m=$arch"
if command -v nvidia-smi >/dev/null; then
  result "nvidia-smi" 1 "$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | paste -sd';' -)"
  nvidia-smi | sed 's/^/    /' >> "$REPORT"
  HAVE_SMI=1
else
  result "nvidia-smi" 0 "not found: is the NVIDIA driver installed?"
  HAVE_SMI=0
fi

# --- 2. archives -----------------------------------------------------------------------------------
section "Archives"
BASE="https://github.com/$REPO/releases/download/$TAG"
fetch "$BASE/SHA256SUMS" "$CACHE/SHA256SUMS-$TAG" || exit 1
declare -A TREE
for variant in cuda13 cpu; do
  if [ "$variant" = cuda13 ]; then suffix=-cuda13; else suffix=; fi
  name="$(awk '{print $2}' "$CACHE/SHA256SUMS-$TAG" | grep -E "^sd-master-$SHORT-bin-Linux-.*-aarch64$suffix\.zip$" | head -1)"
  [ -n "$name" ] || { result "archive $variant" 0 "not in SHA256SUMS of $TAG"; exit 1; }
  sha="$(awk -v n="$name" '$2 == n { print $1 }' "$CACHE/SHA256SUMS-$TAG")"
  fetch "$BASE/$name" "$CACHE/$name" "$sha" || { result "archive $variant" 0 "$name"; exit 1; }
  TREE[$variant]="$CACHE/$TAG-$variant"
  rm -rf "${TREE[$variant]}"
  mkdir -p "${TREE[$variant]}"
  unzip -q "$CACHE/$name" -d "${TREE[$variant]}"
  chmod +x "${TREE[$variant]}/sd-cli" "${TREE[$variant]}/sd-server"
  result "archive $variant" 1 "$name, sha256 ok"
done
GPU_CLI="${TREE[cuda13]}/sd-cli"
CPU_CLI="${TREE[cpu]}/sd-cli"

# --- 3. devices ----------------------------------------------------------------------------------------
section "Devices"
run_sd "$OUT/list-devices.log" "$GPU_CLI" --list-devices
cat "$OUT/list-devices.log" | tee -a "$REPORT"
grep -qiE '^cuda0\s' "$OUT/list-devices.log"; has_cuda=$(( $? == 0 ))
result "CUDA device visible" "$has_cuda" "sd-cli --list-devices (cuda13 build)"

# --- 4. image ----------------------------------------------------------------------------------------------
section "Image"
if [ "$QUICK" = 1 ]; then
  model="$CACHE/sd_turbo-f16-q8_0.gguf"
  fetch https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/main/sd_turbo-f16-q8_0.gguf "$model" d50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580 || exit 1
  MODEL_ARGS=(-m "$model" --cfg-scale 1 --steps 1)
  LABEL="SD-Turbo"
else
  fetch https://huggingface.co/unsloth/Z-Image-Turbo-GGUF/resolve/main/z-image-turbo-Q4_K_M.gguf "$CACHE/z-image-turbo-Q4_K_M.gguf" e6494f87de6abaf6a561924f50317a5f271fc34bb4222aabbd801197df8f7daa || exit 1
  fetch https://huggingface.co/unsloth/Z-Image-Turbo-ComfyUI/resolve/main/split_files/vae/ae.safetensors "$CACHE/z-image-ae.safetensors" afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38 || exit 1
  fetch https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf "$CACHE/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" 3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597 || exit 1
  MODEL_ARGS=(--diffusion-model "$CACHE/z-image-turbo-Q4_K_M.gguf" --vae "$CACHE/z-image-ae.safetensors"
    --llm "$CACHE/Qwen3-4B-Instruct-2507-Q4_K_M.gguf" --cfg-scale 1.0 --steps 8)
  LABEL="Z-Image Turbo Q4_K_M"
fi
PROMPT="a red apple on a wooden table, soft window light, studio photo"

sampler=
if [ "$HAVE_SMI" = 1 ]; then
  nvidia-smi --query-gpu=timestamp,utilization.gpu,memory.used --format=csv,noheader,nounits -lms 1000 -f "$OUT/gpu-util.csv" &
  sampler=$!
fi
run_sd "$OUT/image-gpu.log" "$GPU_CLI" "${MODEL_ARGS[@]}" -p "$PROMPT" -W 512 -H 512 --seed 42 --diffusion-fa --backend cuda0 -v -o "$OUT/image-gpu.png"
gpu_code=$RUN_CODE gpu_s=$RUN_SECONDS
[ -n "$sampler" ] && kill "$sampler" 2>/dev/null
say "cuda init: $(grep -E 'ggml_cuda_init|compute capability' "$OUT/image-gpu.log" | head -3 | paste -sd'|' -)"
peak=$(awk -F, '{ gsub(/ /, "", $2); if ($2 + 0 > m) m = $2 + 0 } END { print m + 0 }' "$OUT/gpu-util.csv" 2>/dev/null || echo 0)
gpu_ok=0; [ "$gpu_code" = 0 ] && [ "$(stat -c %s "$OUT/image-gpu.png" 2>/dev/null || echo 0)" -gt 51200 ] && gpu_ok=1
result "GPU image ($LABEL, 512x512)" "$gpu_ok" "exit $gpu_code, ${gpu_s}s, peak GPU load ${peak}%"

if [ "$SKIP_CPU" = 0 ]; then
  run_sd "$OUT/image-cpu.log" "$CPU_CLI" "${MODEL_ARGS[@]}" -p "$PROMPT" -W 256 -H 256 --seed 42 --backend cpu -v -o "$OUT/image-cpu.png"
  cpu_code=$RUN_CODE cpu_s=$RUN_SECONDS
  cpu_ok=0; [ "$cpu_code" = 0 ] && [ "$(stat -c %s "$OUT/image-cpu.png" 2>/dev/null || echo 0)" -gt 10240 ] && cpu_ok=1
  result "CPU image ($LABEL, 256x256, cpu build)" "$cpu_ok" "exit $cpu_code, ${cpu_s}s"
  if [ "$gpu_ok" = 1 ] && [ "$cpu_ok" = 1 ]; then
    ratio=$(awk -v c="$cpu_s" -v g="$gpu_s" 'BEGIN { if (g < 0.1) g = 0.1; printf "%.1f", c * 4 / g }')
    result "GPU faster than CPU" "$(awk -v r="$ratio" 'BEGIN { print (r > 2) ? 1 : 0 }')" "about ${ratio}x per pixel"
  fi
fi

# --- 5. video ----------------------------------------------------------------------------------------------
if [ "$VIDEO" = 1 ]; then
  section "Video"
  fetch https://huggingface.co/unsloth/Wan2.2-TI2V-5B-GGUF/resolve/main/Wan2.2-TI2V-5B-Q4_K_M.gguf "$CACHE/Wan2.2-TI2V-5B-Q4_K_M.gguf" 95b19697b7f98e65b0a543640e9ca7b4dfec32e2a6e3731e8e10708be52655e2 || exit 1
  fetch https://huggingface.co/unsloth/Wan2.2-TI2V-5B-GGUF/resolve/main/VAE/Wan2.2_VAE.safetensors "$CACHE/Wan2.2_VAE.safetensors" e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156 || exit 1
  fetch https://huggingface.co/city96/umt5-xxl-encoder-gguf/resolve/main/umt5-xxl-encoder-Q4_K_M.gguf "$CACHE/umt5-xxl-encoder-Q4_K_M.gguf" 17cf97a5bbbc60a646d6105b832b6f657ce904a8a1ad970e4b59df0c67584a40 || exit 1
  run_sd "$OUT/video-gpu.log" "$GPU_CLI" -M vid_gen --diffusion-model "$CACHE/Wan2.2-TI2V-5B-Q4_K_M.gguf" \
    --vae "$CACHE/Wan2.2_VAE.safetensors" --t5xxl "$CACHE/umt5-xxl-encoder-Q4_K_M.gguf" \
    -p "a cat walking through tall grass, sunny day" --cfg-scale 5.0 --sampling-method euler --flow-shift 5.0 \
    --steps 20 -W 832 -H 480 --video-frames 33 --fps 24 --seed 42 --diffusion-fa --backend cuda0 -v -o "$OUT/video-gpu.webm"
  vid_ok=0; [ "$RUN_CODE" = 0 ] && [ "$(stat -c %s "$OUT/video-gpu.webm" 2>/dev/null || echo 0)" -gt 51200 ] && vid_ok=1
  result "GPU video (Wan 2.2 TI2V 5B, 832x480, 33 frames)" "$vid_ok" "exit $RUN_CODE, ${RUN_SECONDS}s"
fi
