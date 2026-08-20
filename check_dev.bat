@echo off
rem check_dev.bat - guards Makefile.win's install/update targets against
rem running with no DEV given. sys\elfdos-sys.exe writes directly to a
rem raw physical drive -- the wrong one (or an empty/guessed default)
rem destroys data with no possibility of recovery. Unlike the Linux
rem Makefile's own DEV=/dev/mmcblk0 default (safe only because that's
rem one person's own dev machine's fixed SD-reader path), there is no
rem sane universal default for a Windows physical-drive number, so this
rem refuses to guess rather than picking one.
rem
rem Args: %1 = the current DEV value (may be empty/unset), quoted by the
rem       caller since it can contain backslashes; %2 = the nmake target
rem       name that invoked this check, only used in the error message's
rem       own example command line.

if "%~1"=="" (
    echo Error: DEV is not set.
    echo Re-run as: nmake /F Makefile.win %~2 DEV=\\.\PhysicalDriveN
    echo Use the Disk Management snap-in ^(diskmgmt.msc^) or "wmic diskdrive list brief" to find the right physical drive number.
    echo Writing to the wrong physical drive destroys data with no recovery -- double-check before proceeding.
    exit /b 1
)

exit /b 0
