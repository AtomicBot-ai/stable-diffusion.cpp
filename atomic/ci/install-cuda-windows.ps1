# Install a Windows CUDA toolkit from NVIDIA's redist archives: the compiler side (nvcc, crt, nvvm,
# cccl, cuobjdump) always for the x64 host, and the libraries ggml-cuda links and ships (cudart,
# cublas) for -TargetArch. arm64 is a cross build (Windows on Arm, CUDA 13.4+); x64 is native.
# Versions and checksums come from the redist manifest, so moving to a newer CUDA is a one-line
# change of -Version. Mirrors llama.cpp's .github/actions/windows-setup-cuda.
param(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Root,
  [ValidateSet('arm64', 'x64')][string]$TargetArch = 'arm64'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$base = 'https://developer.download.nvidia.com/compute/cuda/redist'
$manifest = Invoke-RestMethod "$base/redistrib_$Version.json"
$libPlatform = if ($TargetArch -eq 'arm64') { 'windows-arm64' } else { 'windows-x86_64' }
$parts = [ordered]@{
  cuda_nvcc      = 'windows-x86_64'
  cuda_crt       = 'windows-x86_64'
  libnvvm        = 'windows-x86_64'
  cccl           = 'windows-x86_64'
  cuda_cuobjdump = 'windows-x86_64'
  cuda_cudart    = $libPlatform
  libcublas      = $libPlatform
}

New-Item -ItemType Directory -Force $Root | Out-Null
foreach ($name in $parts.Keys) {
  $platform = $parts[$name]
  $entry = $manifest.$name.$platform
  if (-not $entry) { throw "redist $Version has no $name for $platform" }
  $zip = Join-Path $env:RUNNER_TEMP "$name-$platform.zip"
  Write-Host "$name $($manifest.$name.version) ($platform)"
  Invoke-WebRequest "$base/$($entry.relative_path)" -OutFile $zip
  $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sha -ne $entry.sha256) { throw "$name sha256 $sha, manifest says $($entry.sha256)" }
  $tmp = Join-Path $env:RUNNER_TEMP "$name-$platform"
  Expand-Archive $zip $tmp -Force
  $top = Get-ChildItem $tmp -Directory | Select-Object -First 1
  robocopy $top.FullName $Root /E /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $name ($LASTEXITCODE)" }
}

"$Root\bin" | Out-File -Append -Encoding utf8 $env:GITHUB_PATH
"CUDA_PATH=$Root" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV

Write-Host "--- import libraries"
Get-ChildItem "$Root\lib" -Recurse -Filter *.lib | ForEach-Object { $_.FullName.Substring($Root.Length) }
Write-Host "--- runtime DLLs"
Get-ChildItem "$Root\bin" -Recurse -Filter *.dll | ForEach-Object { $_.FullName.Substring($Root.Length) }
$libDir = if ($TargetArch -eq 'arm64') { 'arm64' } else { 'x64' }
foreach ($lib in 'cudart.lib', 'cublas.lib', 'cublasLt.lib', 'cuda.lib') {
  if (-not (Test-Path "$Root\lib\$libDir\$lib")) { throw "lib\$libDir\$lib missing" }
}
# robocopy leaves 1 ("files copied") behind, which a pwsh step would report as a failure.
exit 0
