#!/bin/bash
# The one command that tells you whether Closeup is healthy.
#
#     ./check.sh            build the app, run every test, print a summary
#     ./check.sh --future   also list code that the newest macOS marks as outdated
#
# Takes a minute or two. Needs Xcode; needs no Apple ID, no permissions, and
# never opens the app. The full output is kept in build/check/ for when
# something fails. See MAINTENANCE.md for what to do with a failure.

cd "$(dirname "$0")" || exit 1
OUT="build/check"
mkdir -p "$OUT"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
note() { printf "  \033[33mNOTE\033[0m  %s\n" "$1"; }

if ! xcodebuild -version >/dev/null 2>&1; then
    fail "Xcode isn't set up. Install it from the App Store and open it once."
    exit 1
fi

# Signing is switched off: a check must not depend on anyone's Apple ID.
XCODE=(xcodebuild -project Closeup.xcodeproj -scheme Closeup -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO)
# Problems in our own files only (not Xcode's own chatter), each listed once.
ours() { grep -E "^/.*\.swift:[0-9]+:[0-9]+: $1:" "$2" | sed "s#$PWD/##" | sort -u; }

bold "Closeup check ($(xcodebuild -version | head -1), macOS $(sw_vers -productVersion))"
FAILED=0

# 1. Build the app the way the updater does (Release).
echo "Building the app..."
"${XCODE[@]}" -configuration Release build >"$OUT/build.log" 2>&1
BUILD=$?
WARNINGS=$(ours warning "$OUT/build.log")
if [ $BUILD -eq 0 ]; then
    pass "The app builds"
else
    fail "The app doesn't build"
    ours error "$OUT/build.log" | head -8 | sed 's/^/        /'
    FAILED=1
fi
if [ -n "$WARNINGS" ]; then
    note "$(echo "$WARNINGS" | wc -l | tr -d ' ') build warning(s):"
    echo "$WARNINGS" | head -8 | sed 's/^/        /'
elif [ $BUILD -eq 0 ]; then
    pass "No build warnings"
fi

# 2. Run every test.
echo "Running the tests..."
"${XCODE[@]}" test >"$OUT/test.log" 2>&1
TESTS=$?
SUMMARY=$(grep -E "Executed [0-9]+ tests?, with" "$OUT/test.log" | tail -1)
COUNT=$(echo "$SUMMARY" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
FAILURES=$(echo "$SUMMARY" | sed -E 's/.*with ([0-9]+) failures?.*/\1/')
if [ $TESTS -eq 0 ] && [ -n "$COUNT" ]; then
    pass "All $COUNT tests pass"
elif [ -n "$COUNT" ]; then
    fail "$FAILURES of $COUNT tests fail:"
    grep -E "^/.*: error: -\[" "$OUT/test.log" | sed -E "s#^$PWD/##; s/ : /\n            /" | head -16 | sed 's/^/        /'
    FAILED=1
else
    fail "The tests didn't run (they may not compile, or a test crashed):"
    { ours error "$OUT/test.log"; grep -E "Restarting after unexpected exit|crashed" "$OUT/test.log"; } | head -8 | sed 's/^/        /'
    FAILED=1
fi
if grep -q "golden-.*so I saved new ones" "$OUT/test.log"; then
    note "New reference pictures were saved in CloseupTests/Fixtures. Look at them, then run this again."
fi

# 3. Optional: what will the newest macOS complain about?
if [ "$1" = "--future" ]; then
    SDK=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)
    echo "Looking for outdated code (as if Closeup only supported macOS $SDK)..."
    xcodebuild -project Closeup.xcodeproj -scheme Closeup -configuration Debug \
        -derivedDataPath "$OUT/DerivedDataFuture" CODE_SIGNING_ALLOWED=NO \
        MACOSX_DEPLOYMENT_TARGET="$SDK.0" build >"$OUT/future.log" 2>&1
    FUTURE=$?
    OUTDATED=$(ours warning "$OUT/future.log" | grep -c "deprecated")
    if [ $FUTURE -ne 0 ]; then
        fail "Closeup doesn't build when it only supports macOS $SDK:"
        ours error "$OUT/future.log" | head -8 | sed 's/^/        /'
        echo "        Full output: $OUT/future.log"
        FAILED=1
    elif [ "$OUTDATED" -eq 0 ]; then
        pass "Nothing is marked outdated in macOS $SDK"
    else
        note "$OUTDATED uses of things macOS $SDK marks as outdated (they still work). By file:"
        ours warning "$OUT/future.log" | grep "deprecated" | cut -d: -f1 | sort | uniq -c | sort -rn | sed 's/^/      /'
        echo "        Full list: grep deprecated $OUT/future.log"
    fi
fi

echo
if [ $FAILED -eq 0 ]; then
    bold "RESULT: PASS"
else
    bold "RESULT: FAIL   (full output in $OUT/build.log and $OUT/test.log)"
fi
exit $FAILED
