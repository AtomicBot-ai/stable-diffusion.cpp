# Fail unless every .exe and .dll under -Dir is an ARM64 PE image (machine 0xAA64).
# Reads the PE header directly, so it needs no Visual Studio and runs on any Windows runner.
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'

$bad = @()
$files = Get-ChildItem $Dir -File | Where-Object { $_.Extension -in '.exe', '.dll' }
if (-not $files) { throw "no exe/dll under $Dir" }
foreach ($file in $files) {
  $stream = [System.IO.File]::OpenRead($file.FullName)
  try {
    $reader = New-Object System.IO.BinaryReader($stream)
    $stream.Seek(0x3C, 'Begin') | Out-Null
    $peOffset = $reader.ReadInt32()
    $stream.Seek($peOffset, 'Begin') | Out-Null
    if ($reader.ReadUInt32() -ne 0x00004550) { $bad += "$($file.Name): not a PE image"; continue }
    $machine = $reader.ReadUInt16()
  } finally {
    $stream.Dispose()
  }
  $label = '0x{0:X4}' -f $machine
  if ($machine -ne 0xAA64) { $bad += "$($file.Name): machine $label" } else { Write-Host "$($file.Name): ARM64" }
}
if ($bad) { $bad | Write-Host; throw "not ARM64: $($bad.Count) file(s)" }
