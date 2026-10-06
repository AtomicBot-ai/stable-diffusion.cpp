# Lay out a self-contained Windows-on-Arm archive tree.
#
#   -BinDir   the clang build output; its exe/dll files and the licenses are copied into -OutDir
#   -CudaDll  ggml-cuda.dll from the MSVC cross build, added to an existing -OutDir
#   -CudaRoot the CUDA install whose arm64 runtime DLLs ggml-cuda.dll needs
#
# Every import of every binary must resolve inside the tree or to an OS DLL; the NVIDIA driver
# (nvcuda.dll) is the one allowed exception. The ARM64 VC++ runtime is copied in app-locally, since
# Windows on Arm does not ship it. All binaries must be ARM64, and ggml-cuda must carry sm_121.
param(
  [string]$BinDir,
  [Parameter(Mandatory)][string]$OutDir,
  [Parameter(Mandatory)][string]$VcVars,
  [string]$CudaDll,
  [string]$CudaRoot
)
$ErrorActionPreference = 'Stop'

$vsRoot = (Resolve-Path (Join-Path (Split-Path $VcVars) '..\..\..')).Path
$dumpbin = Get-ChildItem "$vsRoot\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" | Sort-Object FullName | Select-Object -Last 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vsRoot" }
$crt = Get-ChildItem "$vsRoot\VC\Redist\MSVC\*\arm64\Microsoft.VC14*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "the ARM64 VC++ redistributable is not installed under $vsRoot" }
Write-Host "dumpbin: $($dumpbin.FullName)"
Write-Host "ARM64 CRT: $($crt.FullName)"

if ($BinDir) {
  if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  Copy-Item (Join-Path $BinDir '*.exe'), (Join-Path $BinDir '*.dll') $OutDir
  Copy-Item ggml\LICENSE (Join-Path $OutDir 'ggml.txt')
  Copy-Item LICENSE (Join-Path $OutDir 'stable-diffusion.cpp.txt')
}
foreach ($required in 'sd-cli.exe', 'sd-server.exe', 'stable-diffusion.dll') {
  if (-not (Test-Path (Join-Path $OutDir $required))) { throw "$required is missing from $OutDir" }
}
if ($CudaDll) { Copy-Item $CudaDll $OutDir -Force }

$cudaBin = if ($CudaRoot) { Join-Path $CudaRoot 'bin\arm64' } else { $null }
$system32 = Join-Path $env:SystemRoot 'System32'
$allowedMissing = @('nvcuda.dll')

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
      if ($cudaBin -and (Test-Path (Join-Path $cudaBin $dep))) {
        Copy-Item (Join-Path $cudaBin $dep) $OutDir; $added = $true; Write-Host "+ $dep (CUDA)"; continue
      }
      if (Test-Path (Join-Path $crt.FullName $dep)) {
        Copy-Item (Join-Path $crt.FullName $dep) $OutDir; $added = $true; Write-Host "+ $dep (VC++ runtime)"; continue
      }
      if ($dep -like 'api-ms-win-*' -or $dep -like 'ext-ms-win-*' -or (Test-Path (Join-Path $system32 $dep))) { continue }
      if ($allowedMissing -contains $dep.ToLowerInvariant()) { continue }
      throw "$($bin.Name) imports $dep, which is neither in the archive nor an OS DLL"
    }
  }
  if (-not $added) { break }
}

& (Join-Path $PSScriptRoot 'check-pe-arm64.ps1') -Dir $OutDir

if ($CudaDll) {
  $cuobjdump = Join-Path $CudaRoot 'bin\cuobjdump.exe'
  $elf = & $cuobjdump --list-elf (Join-Path $OutDir 'ggml-cuda.dll')
  $elf | Write-Host
  if (-not ($elf -match 'sm_121')) { throw 'ggml-cuda.dll carries no sm_121 code' }
}

Get-ChildItem $OutDir | Format-Table Name, Length -AutoSize | Out-String | Write-Host
