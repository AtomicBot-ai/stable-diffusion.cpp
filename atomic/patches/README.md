# Patch series

`*.patch` files here are applied to the checked-out upstream tag by `atomic/ci/apply-patches.sh`, in name
order. Name them `NNNN-short-description.patch`; prefix with `ggml--` for a patch to the ggml submodule
(applied with `git -C ggml apply`). Keep each patch small, explain why in its header, and offer it
upstream: a patch that lands upstream is deleted here on the next tag.

None yet: the published archives are built from the upstream tag as is.
