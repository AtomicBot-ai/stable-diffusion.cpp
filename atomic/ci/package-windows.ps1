# Lay out a self-contained Windows archive tree (x64 or arm64).
#
#   -BinDir        a build's output; its exe/dll files and the licenses are copied into -OutDir
#   -CudaDll       ggml-cuda.dll from a separate (cross) build, added to an existing -OutDir
#   -CudaRoot      CUDA install whose runtime DLLs the binaries need; they are copied in
#   -AllowMissing  extra DLL name patterns that may stay unresolved: provided by a companion
#                  archive (win-cuda12's cudart) or by the GPU driver (AMD's amdhip64)
#   -ReportOnly    report unresolved imports as warnings instead of failing (ROCm: what the
#                  AMD driver ships is not knowable on a runner without it)
#
# Every import of every binary must resolve inside the tree, to an OS DLL, or to an allowed name;
# the NVIDIA driver (nvcuda.dll) is always allowed. The VC++ runtime of -Arch is copied in
# app-locally (Windows on Arm does not ship it; on x64 it is merely not guaranteed). Every binary
# must be a PE image for -Arch.
param(
  [string]$BinDir,
  [Parameter(Mandatory)][string]$OutDir,
  [Parameter(Mandatory)][string]$VcVars,
  [ValidateSet('arm64', 'x64')][string]$Arch = 'arm64',
  [string]$CudaDll,
  [string]$CudaRoot,
  [string[]]$AllowMissing = @(),
  [switch]$ReportOnly,
  [string]$CheckSm
)
$ErrorActionPreference = 'Stop'

$vsRoot = (Resolve-Path (Join-Path (Split-Path $VcVars) '..\..\..')).Path
$dumpbin = Get-ChildItem "$vsRoot\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" | Sort-Object FullName | Select-Object -Last 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vsRoot" }
$crt = Get-ChildItem "$vsRoot\VC\Redist\MSVC\*\$Arch\Microsoft.VC14*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "the $Arch VC++ redistributable is not installed under $vsRoot" }
Write-Host "dumpbin: $($dumpbin.FullName)"
Write-Host "$Arch CRT: $($crt.FullName)"

if ($BinDir) {
  if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  Copy-Item (Join-Path $BinDir '*.exe'), (Join-Path $BinDir '*.dll') $OutDir
  # ROCm builds put rocBLAS kernels in a subfolder next to the DLLs; keep any such tree.
  Get-ChildItem $BinDir -Directory | ForEach-Object { Copy-Item $_.FullName $OutDir -Recurse -Force }
  Copy-Item ggml\LICENSE (Join-Path $OutDir 'ggml.txt')
  Copy-Item LICENSE (Join-Path $OutDir 'stable-diffusion.cpp.txt')
}
foreach ($required in 'sd-cli.exe', 'sd-server.exe', 'stable-diffusion.dll') {
  if (-not (Test-Path (Join-Path $OutDir $required))) { throw "$required is missing from $OutDir" }
}
if ($CudaDll) { Copy-Item $CudaDll $OutDir -Force }

$cudaBins = @()
if ($CudaRoot) {
  foreach ($d in "bin\$Arch", 'bin') {
    $p = Join-Path $CudaRoot $d
    if (Test-Path $p) { $cudaBins += $p }
  }
}
$system32 = Join-Path $env:SystemRoot 'System32'
$allowed = @('nvcuda.dll') + $AllowMissing
$problems = @()

function Get-Dependents([string]$file) {
  $out = & $dumpbin.FullName /nologo /dependents $file
  if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $file" }
  $out | Where-Object { $_ -match '^\s+([A-Za-z0-9_.\-]+\.dll)\s*$' } | ForEach-Object { $Matches[1] }
}

for ($round = 0; $round -lt 5; $round++) {
  $added = $false
  foreach ($bin in Get-ChildItem $OutDir -File | Where-Object { $_.Extension -in '.exe', '.dll' }) {
    foreach ($dep in Get-Dependents $bin.FullName) {
      if (Test-Path (Join-Path $OutDir $dep)) { continue }
      if ($allowed | Where-Object { $dep -like $_ }) { continue }
      $fromCuda = $cudaBins | ForEach-Object { Join-Path $_ $dep } | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($fromCuda) { Copy-Item $fromCuda $OutDir; $added = $true; Write-Host "+ $dep (CUDA)"; continue }
      if (Test-Path (Join-Path $crt.FullName $dep)) {
        Copy-Item (Join-Path $crt.FullName $dep) $OutDir; $added = $true; Write-Host "+ $dep (VC++ runtime)"; continue
      }
      if ($dep -like 'api-ms-win-*' -or $dep -like 'ext-ms-win-*' -or (Test-Path (Join-Path $system32 $dep))) { continue }
      $problems += "$($bin.Name) imports $dep, which is neither in the archive nor an OS DLL"
    }
  }
  if (-not $added) { break }
}
$problems = $problems | Sort-Object -Unique
if ($problems) {
  if ($ReportOnly) { $problems | ForEach-Object { Write-Host "::warning::$_" } } else { $problems | Write-Host; throw "unresolved imports" }
}

& (Join-Path $PSScriptRoot 'check-pe.ps1') -Dir $OutDir -Machine $Arch

if ($CheckSm) {
  $cuobjdump = Join-Path $CudaRoot 'bin\cuobjdump.exe'
  if (-not (Test-Path $cuobjdump)) { $cuobjdump = 'cuobjdump.exe' }
  $elf = & $cuobjdump --list-elf (Join-Path $OutDir 'ggml-cuda.dll')
  $elf | Write-Host
  if (-not ($elf -match $CheckSm)) { throw "ggml-cuda.dll carries no $CheckSm code" }
}

Get-ChildItem $OutDir | Format-Table Name, Length -AutoSize | Out-String | Write-Host
