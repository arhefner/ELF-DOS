@echo off
rem build_progs.bat - auto-discover and build every "ordinary"
rem (single-file) progs\*.asm into bin\<name>, skipping template.asm
rem and the 9 programs that link against lib\ (those get real nmake
rem rules in Makefile.win instead, with proper incremental rebuilds --
rem see its own header comment). Invoked by "nmake /F Makefile.win
rem progs" so that adding a new progs\*.asm file needs no Makefile.win
rem edit, matching the Linux Makefile's own auto-discovery property
rem (nmake itself has no equivalent of GNU Make's $(wildcard ...) to
rem do this at parse time, hence offloading it to this script).
rem
rem Args: %1=ASM  %2=ASMFLAGS  %3=LINK  %4=LFLAGS -- passed in from
rem Makefile.win's own macros, so the flags live in exactly one place
rem rather than risking this script's copy drifting out of sync.
rem
rem NOTE: this rebuilds the whole auto-discovered set unconditionally
rem every time it runs, rather than checking each file's own timestamp
rem the way a real nmake/make target would -- asm02/link02 are fast
rem enough that this hasn't been worth a hand-rolled date compare in
rem batch. If that ever changes, this is the place to add one.

setlocal enabledelayedexpansion

set "ASM=%~1"
set "ASMFLAGS=%~2"
set "LINK=%~3"
set "LFLAGS=%~4"

if not exist bin mkdir bin

set EXITCODE=0

for %%f in (progs\*.asm) do (
    set "name=%%~nf"
    set "skip="
    if /I "!name!"=="template"   set "skip=1"
    if /I "!name!"=="envtest"    set "skip=1"
    if /I "!name!"=="printenv"   set "skip=1"
    if /I "!name!"=="export"     set "skip=1"
    if /I "!name!"=="unset"      set "skip=1"
    if /I "!name!"=="bumptest"   set "skip=1"
    if /I "!name!"=="malloctest" set "skip=1"
    if /I "!name!"=="ls"         set "skip=1"
    if /I "!name!"=="more"       set "skip=1"
    if /I "!name!"=="edlin"      set "skip=1"
    if /I "!name!"=="move"       set "skip=1"
    if /I "!name!"=="xcopy"      set "skip=1"

    if not defined skip (
        echo Building !name!...
        pushd progs
        %ASM% %ASMFLAGS% %%~nxf
        if errorlevel 1 (
            echo asm02 failed on %%~nxf
            popd
            set EXITCODE=1
        ) else (
            popd
            %LINK% %LFLAGS% -o bin\!name! progs\!name!.prg
            if errorlevel 1 (
                echo link02 failed on !name!
                set EXITCODE=1
            ) else (
                del /F /Q bin\!name!.lkb 2>nul
            )
        )
    )
)

endlocal & exit /b %EXITCODE%
