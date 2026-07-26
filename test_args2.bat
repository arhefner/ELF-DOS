@echo off
del dualredir_out.txt
echo === %args test 2: nested reservation (dual redirect + %N on one line) ===
echo ""

echo this line uses %1 as a filename plus BOTH redirects together
edlin %1 < NUL > dualredir_out.txt
echo edlin returned -- checking dualredir_out.txt and %1 next
type dualredir_out.txt
echo ""

echo --- confirm %1 still resolves correctly on a LATER line too ---
echo arg1 is still: %1
echo ""

echo === test 2 complete (reached normal EOF) ===
