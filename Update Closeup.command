#!/bin/bash
# Closeup updater. Double-click to run.
#
# Downloads the latest Closeup from GitHub, builds it with your own Apple ID
# (found automatically), puts it in Applications and opens it. Also works for
# a first install, once Xcode is installed and signed in.
#
# Nothing else is touched: your recordings stay in ~/Movies/Closeup.

set -euo pipefail
REPO="Diwyani/Closeup"
APP="/Applications/Closeup.app"

step() { printf "\n\033[1m%s\033[0m\n" "$1"; }
fail() {
    printf "\n\033[31m%s\033[0m\n\n" "$1"
    read -n 1 -s -r -p "Press any key to close this window."
    exit 1
}

step "Closeup updater"

xcodebuild -version >/dev/null 2>&1 \
    || fail "Xcode isn't set up yet. Install Xcode from the App Store, open it once, then run this again."

# Your team: from the Apple Development certificate Xcode made for you, or
# from Xcode's account settings. Set CLOSEUP_TEAM to override.
TEAM="${CLOSEUP_TEAM:-}"
if [ -z "$TEAM" ]; then
    TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -oE 'OU ?= ?[A-Z0-9]{10}' | head -1 | grep -oE '[A-Z0-9]{10}$' || true)
fi
if [ -z "$TEAM" ]; then
    TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | grep -oE 'teamID = "?[A-Z0-9]{10}' | head -1 | grep -oE '[A-Z0-9]{10}$' || true)
fi
[ -n "$TEAM" ] \
    || fail "Couldn't find your Apple ID in Xcode. Open Xcode, go to Settings, then Accounts, sign in, and run this again."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

step "Downloading the latest version"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.zip" -o "$WORK/closeup.zip" \
    || fail "Couldn't download Closeup. Check your internet connection and try again."
ditto -x -k "$WORK/closeup.zip" "$WORK"
SOURCE="$WORK/Closeup-main"

step "Building (this takes a minute or two)"
build() {
    xcodebuild -project "$SOURCE/Closeup.xcodeproj" -scheme Closeup -configuration Release \
        -derivedDataPath "$WORK/build" -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic "$@" -quiet 2>&1 \
        | grep -E "error:" || true
}
BUILT="$WORK/build/Build/Products/Release/Closeup.app"
build
if [ ! -d "$BUILT" ]; then
    # The app's ID can be taken by someone else's team; use one that's yours.
    step "Trying again with an app ID of your own"
    build PRODUCT_BUNDLE_IDENTIFIER="app.closeup.Closeup.$TEAM"
fi
[ -d "$BUILT" ] \
    || fail "The build didn't work. Please open an issue with this window's text: https://github.com/$REPO/issues"

step "Installing"
if pgrep -x Closeup >/dev/null; then
    osascript -e 'quit app "Closeup"' >/dev/null 2>&1 || true
    sleep 2
fi
rm -rf "$APP"
ditto "$BUILT" "$APP"

step "Done. Opening the new Closeup."
open "$APP"
sleep 2
