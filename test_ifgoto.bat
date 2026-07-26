@echo off
echo === IF/GOTO test script (happy paths) ===
echo ""

echo --- Test 1: label reached via normal top-to-bottom flow ---
echo before label
:skipme
echo after label (both lines should print; :skipme itself must never appear)
echo ""

echo --- Test 2: forward GOTO ---
goto after_skip
echo FAIL: this line should have been skipped
:after_skip
echo forward goto landed correctly
echo ""
goto test2_done
:skip_this
echo FAIL: jumped to the wrong place
:test2_done
echo ""

echo --- Test 3: backward GOTO (one-shot loop via a marker file) ---
del ifgt_marker.tmp
rd ifgt_marker.tmp
:loop_top
if exist ifgt_marker.tmp goto loop_done
echo pass 1: creating marker, jumping backward to :loop_top
copy /bin/echo ifgt_marker.tmp
goto loop_top
:loop_done
echo backward goto loop completed correctly
del ifgt_marker.tmp
echo ""

echo --- Test 4: IF EXIST / IF NOT EXIST ---
copy /bin/echo existfile.tmp
if exist existfile.tmp echo EXIST test passed (file found)
if not exist doesnotexist.tmp echo NOT EXIST test passed (file correctly absent)
del existfile.tmp
echo ""

echo --- Test 5: IF EXIST + GOTO combination ---
copy /bin/echo existfile2.tmp
if exist existfile2.tmp goto exist_goto_ok
echo FAIL: should have jumped
goto exist_goto_done
:exist_goto_ok
echo IF EXIST + GOTO combination passed
:exist_goto_done
del existfile2.tmp
echo ""

echo --- Test 6: IF %ERRORLEVEL%== (the motivating use case) ---
type nonexistent_file_xyz.txt
if %ERRORLEVEL%==1 echo ERRORLEVEL failure test passed
copy /bin/echo okfile.tmp
if %ERRORLEVEL%==0 echo ERRORLEVEL success test passed
del okfile.tmp
echo ""

echo --- Test 7: IF str1==str2 and NOT ---
if 1==1 echo string equal test passed
if 1==2 echo FAIL: should not print
if NOT 1==1 echo FAIL: should not print
if NOT 1==2 echo string NOT-equal negation test passed
echo ""

echo --- Test 8: regression -- REM and blank lines still work ---
rem this is a comment, should not print or error

echo regression test passed (still running after REM/blank line)
echo ""

echo === ALL TESTS COMPLETED ===
