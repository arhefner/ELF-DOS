@echo off
echo === %args/$FOO test 1: normal completion ===
echo ""

echo --- %0-%9 substitution ---
echo Script name (%0): %0
echo Arg1 (%1): %1
echo Arg2 (%2): %2
echo Arg beyond what was passed (%7): [%7]
echo ""

echo --- $FOO / ${FOO} ---
echo bare: $TESTVAR
echo braced: ${TESTVAR}
echo unset var (should be empty): [$NOSUCHVAR]
echo ""

echo --- quoting ---
echo '$TESTVAR' literal: '$TESTVAR'
echo "$TESTVAR" substituted: "$TESTVAR"
echo \$TESTVAR literal: \$TESTVAR
echo '%1' literal: '%1'
echo ""

echo --- %ERRORLEVEL% regression (now via the new unified path) ---
type nonexistent_file_xyz.txt
echo ERRORLEVEL after failure: %ERRORLEVEL%
echo ""

echo --- overflow: this line should NOT overflow ---
echo short: $BIGVAR
echo ""

echo --- overflow: this line SHOULD overflow (BIGVAR referenced 3x) ---
echo long: $BIGVAR$BIGVAR$BIGVAR
echo (the line above should show "Line too long after substitution."
echo  and NOT the fully-expanded text -- if you see 180 X's instead,
echo  the overflow check failed to trigger)
echo ""

echo === test 1 complete (reached normal EOF) ===
