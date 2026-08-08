# Repeatable screenshots of the patient app from a running emulator or device.
#
# The Flutter side had the same problem the dashboard did: the design was judged on computed
# contrast ratios and never actually looked at. This is the camera.
#
#   .\tool\screenshots.ps1                      # uses the only attached device
#   .\tool\screenshots.ps1 -Serial emulator-5554
#
# Output lands in patient/screenshots/, which is git-ignored: artefacts of a moment, regenerated
# on demand, and committing binaries that change on every tweak would bloat the repo.
#
# It does NOT drive the app through its screens — there is no reliable way to do that from adb
# without a UI-automation harness, and one is not worth adding for this. Take a shot, tap to the
# next screen yourself, take another. The value is in looking, not in the automation.

param(
  [string]$Serial = "",
  [string]$Name = "screen"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "screenshots"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$adbArgs = @()
if ($Serial) { $adbArgs += @("-s", $Serial) }

$stamp = Get-Date -Format "HHmmss"
$remote = "/sdcard/tera-shot.png"
$local = Join-Path $out "$Name-$stamp.png"

& adb @adbArgs shell screencap -p $remote
& adb @adbArgs pull $remote $local | Out-Null
& adb @adbArgs shell rm $remote

Write-Host "wrote $local"
