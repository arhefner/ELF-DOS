@echo off
echo === IF/GOTO test script (negative path -- deliberately ends the batch) ===
echo about to jump to a label that does not exist...
goto this_label_does_not_exist
echo FAIL: this line should never print -- if you see it, GOTO's not-found handling is broken
