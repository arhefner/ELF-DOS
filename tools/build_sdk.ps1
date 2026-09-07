# build_sdk.ps1 - packages the external-developer SDK (headers, lib\
# modules, Developer's Guide) into a single elfdos-sdk.zip that a
# developer downloads and expands directly into their own project -- no
# git clone of ELF-DOS, no local build step of their own required.
#
# Windows counterpart to the Linux Makefile's own "sdk" target
# (elfdos-sdk.tar.gz) -- see that target's own header comment in
# Makefile for the full rationale (SOURCE only, pinned to a commit not
# a version number, kernel.inc/toolchain deliberately excluded). This
# is a standalone script, not inlined into Makefile.win itself, because
# nmake has no $(wildcard ...)/$(patsubst ...) to drive a file list the
# way GNU Make does, and hand-building a multi-line PowerShell one-liner
# inside a batch "^"-continued command string is exactly the kind of
# caret-escaping fragility not worth taking on for something this size
# -- matches this project's own existing "small standalone script for
# build-time computation" precedent (tools\check_kernel_margin.py,
# called from both Makefiles the same way).
#
# The header/lib/inc file lists below are a hand-kept copy of the Linux
# Makefile's own SDK_HEADERS/SDK_LIB_MODULES/SDK_LIB_INCS -- nmake has
# nothing to derive one list from the other, so if a module is ever
# added to or removed from the SDK surface, update both places (same
# "keep two lists in sync by hand" situation this project already lives
# with for SPECIAL_BINS vs. build_progs.bat's own skip list).
#
# Usage (from the repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_sdk.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_sdk.ps1 -OutFile dist\x.zip
#
# Invoked by Makefile.win's own "sdk" target; not meant to be run from
# any directory other than the repo root (all paths below are relative).

param(
    [string]$OutFile = "elfdos-sdk.zip"
)

$ErrorActionPreference = "Stop"

$SdkHeaders = @(
    "include\kernel_api.inc",
    "include\opcodes.def",
    "include\bios.inc"
)

# lib/ modules considered part of the public SDK surface (see
# docs/DEVELOPER_GUIDE.md's own "Library Modules" table).
$SdkLibModules = @(
    "env", "file_glob", "fmt32", "heap_bump", "heap_malloc", "icall",
    "lineedit", "modload", "move", "pathstr", "vollabel", "ymodem"
)

$SdkLibIncs = @(
    "include\file_glob.inc", "include\lineedit.inc",
    "include\modformat.inc", "include\vollabel.inc",
    "include\ymodem.inc"
)

$Stage = "build\sdk-stage"
$Root  = Join-Path $Stage "elfdos-sdk"

if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Root "include") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "lib")     | Out-Null

foreach ($f in $SdkHeaders) { Copy-Item $f (Join-Path $Root "include") }
foreach ($f in $SdkLibIncs) { Copy-Item $f (Join-Path $Root "include") }
foreach ($m in $SdkLibModules) { Copy-Item "lib\$m.asm" (Join-Path $Root "lib") }
Copy-Item "docs\DEVELOPER_GUIDE.md" $Root

# ---- MANIFEST.txt -- same content/shape as the Linux target's own ----
$commit = (git rev-parse HEAD).Trim()
$kmaj = (Select-String -Path "kernel\kernel.asm" -Pattern "KERNEL_VER_MAJOR:\s*equ\s*(\S+)").Matches[0].Groups[1].Value
$kmin = (Select-String -Path "kernel\kernel.asm" -Pattern "KERNEL_VER_MINOR:\s*equ\s*(\S+)").Matches[0].Groups[1].Value
$pb   = (Select-String -Path "include\kernel_api.inc" -Pattern "PROG_BASE:\s*equ\s*(\S+)").Matches[0].Groups[1].Value

$lines = @()
$lines += "ELF-DOS SDK snapshot"
$lines += ("Packaged:       " + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))
$lines += ("ELF-DOS commit: " + $commit)
$lines += ("Kernel version: " + $kmaj + "." + $kmin)
$lines += ("PROG_BASE:      " + $pb)
$lines += ""
$lines += "Headers:"
foreach ($f in ($SdkHeaders + $SdkLibIncs)) { $lines += ("  " + ($f -replace '\\','/')) }
$lines += "Library modules (lib/):"
foreach ($m in $SdkLibModules) { $lines += ("  $m.asm") }
$lines += ""
$lines += "DEVELOPER_GUIDE.md included -- see it for the full API reference."
$lines += "Toolchain (asm02/link02) is NOT included -- see DEVELOPER_GUIDE.md's own Build section for install instructions."

Set-Content -Path (Join-Path $Root "MANIFEST.txt") -Value $lines -Encoding ASCII

# ---- Zip ----
if (Test-Path $OutFile) { Remove-Item -Force $OutFile }
Compress-Archive -Path $Root -DestinationPath $OutFile -CompressionLevel Optimal

Write-Host "SDK packaged to $OutFile"
$lines | ForEach-Object { Write-Host $_ }

Remove-Item -Recurse -Force $Stage
