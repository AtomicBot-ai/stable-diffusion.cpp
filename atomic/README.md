# Atomic builds of stable-diffusion.cpp

This fork builds **every** stable-diffusion.cpp engine [Atomic Chat](https://github.com/AtomicBot-ai/Atomic-Chat)
ships, from an unmodified [leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) tag:

- **upstream's nine archives, with upstream's flags:** `macos-arm64`; `win-cpu-x64`, `win-vulkan-x64`,
  `win-cuda12-x64` (+ the `cudart-sd-bin-win-cu12-x64` companion) and `win-rocm-x64`; `linux-cpu-x64`,
  `linux-vulkan-x64` and `linux-rocm-x64`;
- **archives upstream does not publish:** `linux-cpu-arm64` and `linux-cuda13-arm64` (DGX Spark / GB10),
  `win-cpu-arm64` and `win-cuda13-arm64` (RTX Spark / N1X), `linux-cuda12-x64`, and `win-cuda13-x64`.

They are consumed through `atomic-chat-conf/backends/sdcpp-manifest.json`; the conf repo's
`mirror-sdcpp.yml` re-signs the Windows and macOS ones with Atomic Chat's certificates.

## Branches

| Branch   | What it is                                                                 |
| -------- | -------------------------------------------------------------------------- |
| `master` | A fast-forward mirror of upstream `master`. Never commit here.             |
| `atomic` | The default branch: upstream `master` plus **only added files** (`atomic/`, `.github/workflows/release-atomic.yml`). |

Source code is never changed on a branch. Every build starts from an **upstream tag** and applies the
patch series in [`atomic/patches/`](patches/). That keeps rebasing trivial and makes the release
notes say exactly what differs from upstream.

## Building a release

Actions → **Release (Atomic)**:
- `upstream_tag`: the tag Atomic Chat's manifest pins, e.g. `master-883-137f740`;
- `targets`: `all`, or a comma-separated list of backend ids to rebuild while fixing one;
- `publish`: creates the release of the tag here, and needs `all`.

Then run `mirror-sdcpp.yml` in atomic-chat-conf for the same tag.

Every archive except ROCm is smoke-tested on a machine without a GPU: it must start, list its devices,
and generate an image through sd-server's HTTP API. On Linux this runs in a bare `python:3.12-slim`
container, so a missing runtime library fails CI. ROCm gets build and structure checks only, since no
runner has the AMD driver, which is also the case upstream.

### Choices that are easy to get wrong

- **CUDA versions.** Linux uses 13.0 from NVIDIA's **SBSA** repo (the `arm64` repo is Jetson), the
  toolkit upstream's own `-spark` Docker image is built with; it needs only the r580 driver DGX OS ships.
  Windows uses 13.4, the first CUDA with Windows on Arm. Archs `90-virtual;121-real`: sm_121 SASS for
  GB10/N1X, a Hopper PTX floor for GH200/GB200/Thor.
- **Linux archives are flat and symlink-free.** Atomic Chat's unzip writes a symlink out as a plain
  file, so `atomic/ci/package-linux.sh` dereferences and copies only the sonames that are needed.
  The CUDA runtime (`libcudart`, `libcublas`, `libcublasLt`) is bundled; `libcuda.so.1` comes from the
  driver.
- **Windows is two builds merged**, as llama.cpp does it. ggml-cpu refuses MSVC on ARM, so the tree is
  built with clang (`atomic/cmake/arm64-windows-llvm.cmake`); `ggml-cuda.dll` is cross-compiled with
  MSVC + x64 nvcc against NVIDIA's arm64 libraries (`atomic/cmake/arm64-windows-msvc-cuda.cmake`) **inside
  sd.cpp's CMake tree**. That last part matters: sd.cpp compiles ggml with `-DGGML_MAX_NAME=160`, and a
  standalone ggml build would disagree on the `ggml_tensor` layout.
- **Known gap on Windows CUDA:** the clang-built `stable-diffusion.dll` has no `SD_USE_CUDA`, so
  `sd_backend_supports_cuda_mma()` is false and attention heads narrower than 64 are not padded for
  the MMA flash-attention path. Speed only, and only for such models (SD 1.x has 40-wide
  heads; SD 2.x/SDXL 64; Atomic Chat's current families 128). The fix is a small patch resolving the driver API
  at runtime instead of linking `CUDA::cuda_driver`, worth offering upstream.
- **Both Windows halves use the DLL CRT** and ship the ARM64 VC++ runtime app-locally.

The toolchain files are copied verbatim from ggml-org/llama.cpp `cmake/` (MIT); refresh them from there.

## Checking on real hardware

`atomic/verify/verify-spark.ps1` (Windows; `verify-spark.cmd` is the double-click wrapper) and
`verify-spark.sh` (Linux) download the archives of a release, check them against `SHA256SUMS`, list the
devices, and generate a Z-Image Turbo image on the GPU and on the CPU. With `-Video`/`--video`
they also make a short Wan 2.2 TI2V 5B clip. The report goes to `Desktop\sd-verify\report.txt`
(`~/sd-verify/report.txt` on Linux).
