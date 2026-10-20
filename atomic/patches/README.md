# Patch series

`*.patch` files here are applied to the checked-out upstream tag by `atomic/ci/apply-patches.sh`, in name
order. Name them `NNNN-short-description.patch`; prefix with `ggml--` for a patch to the ggml submodule
(applied with `git -C ggml apply`). Keep each patch small, explain why in its header, and offer it
upstream: a patch that lands upstream is deleted here on the next tag.

`apply-patches.sh --check`, run from the root of a checkout of the tag, changes nothing: it lists every
patch that does not apply on top of the ones before it, with git's reason, and flags the ones that
reverse cleanly as already upstream.

Current series (build system only; no source code differs from the upstream tag):

| Patch | Why |
| --- | --- |
| `0001-export-libwebm-symbols-for-clang-on-windows.patch` | clang for Windows does not set `MSVC`, so libwebm's DLL exported nothing and `sd-cli`/`sd-server` failed to link. |
