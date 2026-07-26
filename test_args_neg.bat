@echo off
echo === %args test 3: batch ends via GOTO to an undefined label ===
echo arg1 is: %1
echo about to jump to a label that does not exist...
goto this_label_does_not_exist
echo FAIL: this line should never print
