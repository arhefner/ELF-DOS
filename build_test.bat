@echo off
rem build_test.bat - auto-discover and build every "ordinary"
rem (single-file) test\*.asm into test\bin\<name>, skipping the 3
rem programs that link against lib\ (envtest, bumptest, malloctest --
rem those get real nmake rules in Makefile.win instead, with proper
rem incremental rebuilds -- see its own header comment). Invoked by
rem "nmake /F Makefile.win test" so that adding a new test\*.asm file
rem needs no Makefile.win edit, matching build_progs.bat's own
rem auto-discovery property (and the Linux Makefile's own
rem TEST_SRCS/TEST_EXES, which needs no such split at all thanks to
rem $(wildcard ...)).
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

if not exist test\bin mkdir test\bin

set EXITCODE=0

for %%f in (test\*.asm) do (
    set "name=%%~nf"
    set "skip="
    if /I "!name!"=="envtest"    set "skip=1"
    if /I "!name!"=="bumptest"   set "skip=1"
    if /I "!name!"=="malloctest" set "skip=1"

    if not defined skip (
        echo Building !name!...
        pushd test
        %ASM% %ASMFLAGS% %%~nxf
        if errorlevel 1 (
            echo asm02 failed on %%~nxf
            popd
            set EXITCODE=1
        ) else (
            popd
            %LINK% %LFLAGS% -o test\bin\!name! test\!name!.prg
            if errorlevel 1 (
                echo link02 failed on !name!
                set EXITCODE=1
            ) else (
                del /F /Q test\bin\!name!.lkb 2>nul
            )
        )
    )
)

endlocal & exit /b %EXITCODE%
