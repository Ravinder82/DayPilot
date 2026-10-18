#!/usr/bin/env bash
#
# DayPilot — production release packaging.
#
# Builds the release binary, bundles it into a standalone `.app` in dist/, and
# signs it. `make install` then copies the result into /Applications.
#
# Signing policy, in order of preference:
#   1. An `Apple Development` / `Developer ID` identity, if one exists.
#   2. Ad-hoc, as a last resort.
#
# An ad-hoc signature has no Team Identifier, so TCC classifies the binary as a
# *platform binary* and refuses to prompt for Screen Recording at all — the
# permission becomes permanently ungrantable, which looks exactly like a bug in
# DayPilot rather than a missing certificate. This script therefore prefers a
# real identity and says so loudly when it falls back.

set -euo pipefail

readonly PRODUCT="DayPilot"
readonly DIST_DIR="dist"
readonly APP_DIR="${DIST_DIR}/${PRODUCT}.app"
readonly CONTENTS="${APP_DIR}/Contents"
readonly MACOS_DIR="${CONTENTS}/MacOS"
readonly RESOURCES_DIR="${CONTENTS}/Resources"

readonly PLIST="Resources/Info.plist"
readonly ICNS="Resources/AppIcon.icns"
readonly SKILL_CONFIG=".opencode/skills/daypilot-tracker/daypilot-tracker.config.json"

# Colorized status output when attached to a terminal.
if [[ -t 1 ]]; then
    readonly C_RESET="$(printf '\033[0m')"
    readonly C_BOLD="$(printf '\033[1m')"
    readonly C_GREEN="$(printf '\033[32m')"
    readonly C_YELLOW="$(printf '\033[33m')"
    readonly C_RED="$(printf '\033[31m')"
fi

step() { printf '\n%s==> %s%s\n' "${C_BOLD:-}" "$1" "${C_RESET:-}"; }
info() { printf '    %s\n' "$1"; }
success() { printf '    %sok%s    %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$1"; }
warning() { printf '    %swarn%s  %s\n' "${C_YELLOW:-}" "${C_RESET:-}" "$1" >&2; }
fail() {
    printf '\n    %sfail%s  %s\n' "${C_RED:-}" "${C_RESET:-}" "$1" >&2
    exit 1
}

# Run from the repository root regardless of where the script was invoked.
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

step "Preflight"

for tool in swift codesign iconutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "required command '$tool' was not found on PATH"
done
success "toolchain present"

[[ -f "$PLIST" ]] || fail "missing $PLIST — run make setup first"

# The icon is optional, but a bundle without one looks unfinished.
if [[ ! -f "$ICNS" ]]; then
    warning "no $ICNS found — run 'make icon' or the app will use a generic icon"
else
    success "app icon present"
fi

# Pick the best available signing identity.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development|Developer ID/ {print $2; exit}')"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    success "signing identity: ${SIGNING_IDENTITY}"
else
    warning "no Apple Development / Developer ID identity found"
    warning "falling back to ad-hoc signing"
    warning "  → TCC will refuse to prompt for Screen Recording, so install /Applications"
    warning "    then sign once in Xcode before using the app."
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

step "Building for production"

swift build -c release --product "$PRODUCT" 2>&1 | grep -v '^\[[0-9]*/' || true

readonly BINARY=".build/release/${PRODUCT}"
[[ -x "$BINARY" ]] || fail "the release binary was not produced at ${BINARY}"
success "release binary built"

# ---------------------------------------------------------------------------
# Bundle
# ---------------------------------------------------------------------------

step "Assembling ${APP_DIR}"

# Build the bundle in a scratch directory. This project directory is
# file-provider managed, and Finder stamps com.apple.FinderInfo /
# com.apple.fileprovider.fpfs#P attributes on directories created inside it,
# which codesign rejects as "resource fork, Finder information, or similar
# detritus". Moving a finished bundle in is safe: only file contents are hashed.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

STAGED_APP="${STAGING}/${PRODUCT}.app"
mkdir -p "${STAGED_APP}/Contents/MacOS" "${STAGED_APP}/Contents/Resources"

cp "$BINARY" "${STAGED_APP}/Contents/MacOS/${PRODUCT}"
cp "$PLIST" "${STAGED_APP}/Contents/Info.plist"
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "${STAGED_APP}/Contents/Resources/${PRODUCT}.icns"
fi

# The skill configuration travels inside the app, so an installed copy is set up
# exactly as the repository is. The app still prefers a user override.
if [[ -f "$SKILL_CONFIG" ]]; then
    cp "$SKILL_CONFIG" "${STAGED_APP}/Contents/Resources/daypilot-tracker.config.json"
fi

# The Axo mascot model travels inside the app bundle.
if [[ -f "Resources/axo.glb" ]]; then
    cp "Resources/axo.glb" "${STAGED_APP}/Contents/Resources/axo.glb"
fi

# The sandboxing entitlement, when present. DayPilot samples other apps'
# windows, so an App Sandbox must not be applied.
if [[ -f "Resources/DayPilot.entitlements" ]]; then
    cp "Resources/DayPilot.entitlements" "$STAGING/"
fi

success "bundle contents assembled"

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

step "Code signing"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements "Resources/DayPilot.entitlements" \
        "$STAGED_APP" 2>&1 | grep -v '^$' || true
    success "signed with ${SIGNING_IDENTITY}"
else
    codesign --force --deep --sign - \
        --entitlements "Resources/DayPilot.entitlements" \
        "$STAGED_APP" 2>&1 | grep -v '^$' || true
    success "ad-hoc signed"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

step "Verifying signature"

if codesign --verify --deep --strict "$STAGED_APP" 2>&1; then
    success "signature verifies"
else
    fail "the bundle's signature does not verify"
fi

TEAM_ID="$(codesign -d --verbose=2 "$STAGED_APP" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p')"
info "TeamIdentifier: ${TEAM_ID:-not set}"

# ---------------------------------------------------------------------------
# Install into dist/
# ---------------------------------------------------------------------------

step "Publishing ${APP_DIR}"

rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"
mv "$STAGED_APP" "$APP_DIR"

SIZE="$(du -sh "$APP_DIR" | awk '{print $1}')"
success "${APP_DIR} (${SIZE})"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%s==> Ready%s\n' "${C_BOLD:-}" "${C_RESET:-}"
printf '    %s\n' "${APP_DIR}"
info "binary:    ${MACOS_DIR}/${PRODUCT}"
info "info:      ${APP_DIR}/Contents/Info.plist"
[[ -f "${RESOURCES_DIR}/${PRODUCT}.icns" ]] && info "icon:      ${RESOURCES_DIR}/${PRODUCT}.icns"

# The ad-hoc case is a real limitation, not a footnote: the app will launch but
# can never capture. Say it one more time, at the end, where it will be seen.
if [[ -z "$SIGNING_IDENTITY" ]]; then
    printf '\n'
    warning "AD-HOC SIGNED — Screen Recording permission cannot be granted."
    warning "Sign the bundle with a real identity before using it:"
    warning "  codesign --force --sign \"Apple Development: you (TEAMID)\" \\"
    warning "      --entitlements Resources/DayPilot.entitlements ${APP_DIR}"
    printf '\n'
fi

printf '\n%s\n' "DayPilot.app is ready in ${APP_DIR}."
