# Atomic arm64 builds of stable-diffusion.cpp

This fork exists to publish what [leejet/stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)
does not: release archives for **arm64 Linux** and **Windows on Arm**, with CUDA for NVIDIA's arm64 parts
(DGX Spark / GB10 on Linux, RTX Spark / N1X laptops on Windows). They are consumed by
[Atomic Chat](https://github.com/AtomicBot-ai/Atomic-Chat) through
`atomic-chat-conf/backends/sdcpp-manifest.json`, mirrored beside upstream's own assets of the same tag.

## Branches

| Branch   | What it is                                                                 |
| -------- | -------------------------------------------------------------------------- |
| `master` | A fast-forward mirror of upstream `master`. Never commit here.             |
| `atomic` | The default branch: upstream `master` plus **only added files** (`atomic/`, `.github/workflows/release-arm64.yml`). |

Source code is never changed on a branch. Every build starts from an **upstream tag** and applies the
patch series in [`atomic/patches/`](patches/) (empty means the tag as is). That keeps rebasing trivial
and makes the release notes say exactly what differs from upstream.

## Building a release

Actions → **Release arm64 (Atomic)** → `upstream_tag` = the tag Atomic Chat's manifest pins
(e.g. `master-883-137f740`), `publish` = on. The run:

| Job | Runner | Output |
| --- | --- | --- |
| `linux-cuda13-arm64` | `ubuntu-24.04-arm` | `sd-master-<sha7>-bin-Linux-Ubuntu-24.04-aarch64-cuda13.zip` |
| `linux-cpu-arm64` | `ubuntu-24.04-arm` | `sd-master-<sha7>-bin-Linux-Ubuntu-24.04-aarch64.zip` |
| `windows-arm64-cpu` | `windows-2022` (cross) | `sd-master-<sha7>-bin-win-cpu-arm64.zip` |
| `windows-arm64-cuda13` | `windows-2022` (cross) | `sd-master-<sha7>-bin-win-cuda13-arm64.zip` |
| `smoke-*` | `ubuntu-24.04-arm`, `windows-11-arm` | every archive starts, lists devices, generates an image over HTTP |
| `release` | | the release of `<upstream_tag>` here, with `SHA256SUMS` and the verify scripts |

Then run `mirror-sdcpp.yml` in atomic-chat-conf for the same tag.

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
