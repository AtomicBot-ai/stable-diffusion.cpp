<#
.SYNOPSIS
  Hardware check of the Atomic arm64 stable-diffusion.cpp builds on a Windows-on-Arm NVIDIA laptop
  (RTX Spark / N1X). Written for Windows PowerShell 5.1, which every Windows 11 has.

.DESCRIPTION
  1. Records the system: Windows build, CPU architecture, RAM, nvidia-smi.
  2. Downloads win-cuda13-arm64 and win-cpu-arm64 of release @TAG@ and checks them against SHA256SUMS.
  3. sd-cli --list-devices must show a CUDA device.
  4. Generates a 512x512 Z-Image Turbo image on the GPU (the files Atomic Chat's catalog uses), sampling
     GPU load, then the same prompt at 256x256 on the CPU build for comparison.
  5. -Video: a short Wan 2.2 TI2V 5B clip on the GPU.
  Writes Desktop\sd-verify\report.txt beside the images and logs, and opens the folder.

  Models are cached in %USERPROFILE%\sd-verify-cache, so a second run downloads nothing.
  -Quick uses SD-Turbo (2 GB, one file) instead of Z-Image Turbo (7.8 GB, three files).
#>
param(
  [string]$Tag = '@TAG@',
  [string]$Repo = '@REPO@',
  [switch]$Video,
  [switch]$Quick,
  [switch]$SkipCpu,
  [string]$Cache = (Join-Path $env:USERPROFILE 'sd-verify-cache')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$short = ($Tag -split '-')[-1]
$outDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'sd-verify'
New-Item -ItemType Directory -Force $outDir, $Cache | Out-Null
$report = Join-Path $outDir 'report.txt'
$results = New-Object System.Collections.ArrayList
Set-Content -Path $report -Value "Atomic stable-diffusion.cpp arm64 check  $(Get-Date -Format s)  tag $Tag" -Encoding UTF8

function Say([string]$text) { Write-Host $text; Add-Content -Path $report -Value $text -Encoding UTF8 }
function Section([string]$title) { Say ''; Say "=== $title" }
function Result([string]$step, [bool]$ok, [string]$detail) {
  $mark = if ($ok) { 'PASS' } else { 'FAIL' }
  [void]$results.Add("$mark  $step  $detail")
  Say "$mark  $step  $detail"
}

function Fetch([string]$url, [string]$file, [string]$sha256) {
  if ((Test-Path $file) -and $sha256 -and ((Get-FileHash $file -Algorithm SHA256).Hash.ToLower() -eq $sha256)) { return }
  Write-Host "downloading $url"
  # curl.exe ships with Windows 10+ and resumes a broken multi-GB download (-C -).
  & curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o "$file" "$url"
  if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE): $url" }
  if ($sha256) {
    $got = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $sha256) { Remove-Item $file -Force; throw "sha256 mismatch for $url" }
  }
}

function Run-Sd([string]$exe, [string[]]$arguments, [string]$log) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $dir = Split-Path $exe
  $old = $env:PATH
  $env:PATH = "$dir;$old"
  try {
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $dir -NoNewWindow -PassThru `
      -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
    # Without touching Handle first, Windows PowerShell can report a null ExitCode.
    $null = $p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
  } finally {
    $env:PATH = $old
  }
  $sw.Stop()
  Get-Content "$log.out", "$log.err" -ErrorAction SilentlyContinue | Set-Content $log -Encoding UTF8
  Remove-Item "$log.out", "$log.err" -ErrorAction SilentlyContinue
  return @{ Code = $code; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Text = [string](Get-Content $log -Raw) }
}

function Quote([string]$value) { if ($value -match '\s') { '"' + $value + '"' } else { $value } }

try {
  # --- 1. system -------------------------------------------------------------------------------
  Section 'System'
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  Say "Windows: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
  Say "CPU: $($cpu.Name), $($cpu.NumberOfLogicalProcessors) threads"
  Say ("RAM: {0:N1} GB" -f ($os.TotalVisibleMemorySize / 1MB))
  $arch = $env:PROCESSOR_ARCHITECTURE
  Result 'native ARM64 shell' ($arch -eq 'ARM64') "PROCESSOR_ARCHITECTURE=$arch"
  $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  if ($smi) {
    $gpu = (& nvidia-smi.exe --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader) -join '; '
    Result 'nvidia-smi' $true $gpu
    (& nvidia-smi.exe) | ForEach-Object { Add-Content -Path $report -Value "    $_" -Encoding UTF8 }
  } else {
    Result 'nvidia-smi' $false 'not found: is the NVIDIA driver installed?'
  }

  # --- 2. archives -------------------------------------------------------------------------------
  Section 'Archives'
  $base = "https://github.com/$Repo/releases/download/$Tag"
  $sumsFile = Join-Path $Cache "SHA256SUMS-$Tag"
  Fetch "$base/SHA256SUMS" $sumsFile $null
  $sums = @{}
  foreach ($line in Get-Content $sumsFile) {
    $parts = $line -split '\s+', 2
    if ($parts.Count -eq 2) { $sums[$parts[1].Trim().TrimStart('*')] = $parts[0].ToLower() }
  }
  $trees = @{}
  foreach ($variant in 'cuda13', 'cpu') {
    $name = "sd-master-$short-bin-win-$variant-arm64.zip"
    if (-not $sums.ContainsKey($name)) { throw "$name is not in SHA256SUMS of $Tag" }
    $zip = Join-Path $Cache $name
    Fetch "$base/$name" $zip $sums[$name]
    $tree = Join-Path $Cache "$Tag-$variant"
    if (Test-Path $tree) { Remove-Item $tree -Recurse -Force }
    Expand-Archive $zip $tree -Force
    $trees[$variant] = $tree
    Result "archive $variant" $true "$name, sha256 ok"
  }
  $gpuCli = Join-Path $trees['cuda13'] 'sd-cli.exe'
  $cpuCli = Join-Path $trees['cpu'] 'sd-cli.exe'

  # --- 3. devices ----------------------------------------------------------------------------------
  Section 'Devices'
  $devices = Run-Sd $gpuCli @('--list-devices') (Join-Path $outDir 'list-devices.log')
  Say $devices.Text.Trim()
  $hasCuda = $devices.Text -match '(?im)^cuda0\s'
  Result 'CUDA device visible' $hasCuda 'sd-cli --list-devices (cuda13 build)'

  # --- 4. image --------------------------------------------------------------------------------------
  Section 'Image'
  if ($Quick) {
    $model = Join-Path $Cache 'sd_turbo-f16-q8_0.gguf'
    Fetch 'https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/main/sd_turbo-f16-q8_0.gguf' $model 'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580'
    $modelArgs = @('-m', (Quote $model), '--cfg-scale', '1', '--steps', '1')
    $label = 'SD-Turbo'
  } else {
    $dm = Join-Path $Cache 'z-image-turbo-Q4_K_M.gguf'
    $vae = Join-Path $Cache 'z-image-ae.safetensors'
    $llm = Join-Path $Cache 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
    Fetch 'https://huggingface.co/unsloth/Z-Image-Turbo-GGUF/resolve/main/z-image-turbo-Q4_K_M.gguf' $dm 'e6494f87de6abaf6a561924f50317a5f271fc34bb4222aabbd801197df8f7daa'
    Fetch 'https://huggingface.co/unsloth/Z-Image-Turbo-ComfyUI/resolve/main/split_files/vae/ae.safetensors' $vae 'afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38'
    Fetch 'https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf' $llm '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597'
    $modelArgs = @('--diffusion-model', (Quote $dm), '--vae', (Quote $vae), '--llm', (Quote $llm), '--cfg-scale', '1.0', '--steps', '8')
    $label = 'Z-Image Turbo Q4_K_M'
  }
  $prompt = '"a red apple on a wooden table, soft window light, studio photo"'

  $gpuPng = Join-Path $outDir 'image-gpu.png'
  $utilCsv = Join-Path $outDir 'gpu-util.csv'
  $sampler = $null
  if ($smi) {
    $sampler = Start-Process nvidia-smi.exe -ArgumentList '--query-gpu=timestamp,utilization.gpu,memory.used', '--format=csv,noheader,nounits', '-lms', '1000', '-f', (Quote $utilCsv) -WindowStyle Hidden -PassThru
  }
  $gpuRun = Run-Sd $gpuCli ($modelArgs + @('-p', $prompt, '-W', '512', '-H', '512', '--seed', '42', '--diffusion-fa', '--backend', 'cuda0', '-v', '-o', (Quote $gpuPng))) (Join-Path $outDir 'image-gpu.log')
  if ($sampler) { Stop-Process -Id $sampler.Id -ErrorAction SilentlyContinue }
  $cudaInit = ($gpuRun.Text -split "`n" | Where-Object { $_ -match 'ggml_cuda_init|compute capability' } | Select-Object -First 3) -join ' | '
  Say "cuda init: $cudaInit"
  $peak = 0
  if (Test-Path $utilCsv) {
    foreach ($row in Get-Content $utilCsv) {
      $cols = $row -split ','
      if ($cols.Count -ge 2) { $u = 0; if ([int]::TryParse($cols[1].Trim(), [ref]$u) -and $u -gt $peak) { $peak = $u } }
    }
  }
  $gpuOk = ($gpuRun.Code -eq 0) -and (Test-Path $gpuPng) -and ((Get-Item $gpuPng).Length -gt 50KB)
  Result "GPU image ($label, 512x512)" $gpuOk "exit $($gpuRun.Code), $($gpuRun.Seconds)s, peak GPU load $peak%"

  if (-not $SkipCpu) {
    $cpuPng = Join-Path $outDir 'image-cpu.png'
    $cpuRun = Run-Sd $cpuCli ($modelArgs + @('-p', $prompt, '-W', '256', '-H', '256', '--seed', '42', '--backend', 'cpu', '-v', '-o', (Quote $cpuPng))) (Join-Path $outDir 'image-cpu.log')
    $cpuOk = ($cpuRun.Code -eq 0) -and (Test-Path $cpuPng) -and ((Get-Item $cpuPng).Length -gt 10KB)
    Result "CPU image ($label, 256x256, cpu build)" $cpuOk "exit $($cpuRun.Code), $($cpuRun.Seconds)s"
    if ($gpuOk -and $cpuOk) {
      # The CPU run has a quarter of the pixels; per pixel the GPU should be far ahead.
      $perPixel = [math]::Round(($cpuRun.Seconds * 4) / [math]::Max($gpuRun.Seconds, 0.1), 1)
      Result 'GPU faster than CPU' ($perPixel -gt 2) "about ${perPixel}x per pixel"
    }
  }

  # --- 5. video --------------------------------------------------------------------------------------
  if ($Video) {
    Section 'Video'
    $wan = Join-Path $Cache 'Wan2.2-TI2V-5B-Q4_K_M.gguf'
    $wvae = Join-Path $Cache 'Wan2.2_VAE.safetensors'
    $t5 = Join-Path $Cache 'umt5-xxl-encoder-Q4_K_M.gguf'
    Fetch 'https://huggingface.co/unsloth/Wan2.2-TI2V-5B-GGUF/resolve/main/Wan2.2-TI2V-5B-Q4_K_M.gguf' $wan '95b19697b7f98e65b0a543640e9ca7b4dfec32e2a6e3731e8e10708be52655e2'
    Fetch 'https://huggingface.co/unsloth/Wan2.2-TI2V-5B-GGUF/resolve/main/VAE/Wan2.2_VAE.safetensors' $wvae 'e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156'
    Fetch 'https://huggingface.co/city96/umt5-xxl-encoder-gguf/resolve/main/umt5-xxl-encoder-Q4_K_M.gguf' $t5 '17cf97a5bbbc60a646d6105b832b6f657ce904a8a1ad970e4b59df0c67584a40'
    $clip = Join-Path $outDir 'video-gpu.webm'
    $vidRun = Run-Sd $gpuCli @('-M', 'vid_gen', '--diffusion-model', (Quote $wan), '--vae', (Quote $wvae), '--t5xxl', (Quote $t5),
      '-p', '"a cat walking through tall grass, sunny day"', '--cfg-scale', '5.0', '--sampling-method', 'euler', '--flow-shift', '5.0',
      '--steps', '20', '-W', '832', '-H', '480', '--video-frames', '33', '--fps', '24', '--seed', '42', '--diffusion-fa',
      '--backend', 'cuda0', '-v', '-o', (Quote $clip)) (Join-Path $outDir 'video-gpu.log')
    $vidOk = ($vidRun.Code -eq 0) -and (Test-Path $clip) -and ((Get-Item $clip).Length -gt 50KB)
    Result 'GPU video (Wan 2.2 TI2V 5B, 832x480, 33 frames)' $vidOk "exit $($vidRun.Code), $($vidRun.Seconds)s"
  }
} catch {
  Result 'script' $false $_.Exception.Message
}

Section 'Summary'
$results | ForEach-Object { Add-Content -Path $report -Value $_ -Encoding UTF8; Write-Host $_ }
$failed = @($results | Where-Object { $_ -like 'FAIL*' }).Count
Say ''
if ($failed -eq 0) { Say 'ALL PASS' } else { Say "$failed FAILED - send report.txt and the *.log files from this folder" }
Invoke-Item $outDir
