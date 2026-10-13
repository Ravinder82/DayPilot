#!/usr/bin/env bash
#
# DayPilot — Phase 1 bootstrap.
#
# Scaffolds the Swift Package Manager tree and validates that the local
# toolchain can produce a native Apple Silicon binary targeting macOS 14+.
# Safe to re-run: existing sources are never touched or deleted.

set -euo pipefail

readonly PROJECT_NAME="DayPilot"
readonly MINIMUM_MACOS_MAJOR=14
readonly MINIMUM_SWIFT_MAJOR=6

# Full module layout. Everything under Sources/ except App/ is populated in
# later phases, so only the placeholders that ship with Phase 1 are listed
# here.
readonly MODULE_DIRECTORIES=(
    "Sources/App"
    "Sources/Capture"
    "Sources/Ingestion"
    "Sources/Synthesis"
    "Sources/Audio"
    "Sources/Storage"
)
readonly RESOURCE_DIRECTORIES=(
    "Resources"
)
# Owns no sources yet — a placeholder keeps it tracked in version control.
readonly EMPTY_MODULE_DIRECTORIES=(
    "Sources/Synthesis"
    "Sources/Audio"
)
readonly REQUIRED_FILES=(
    "Package.swift"
    "Resources/Info.plist"
    "Resources/DayPilot.entitlements"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    readonly C_RESET="$(printf '\033[0m')"
    readonly C_BOLD="$(printf '\033[1m')"
    readonly C_GREEN="$(printf '\033[32m')"
    readonly C_YELLOW="$(printf '\033[33m')"
    readonly C_RED="$(printf '\033[31m')"
fi

step() {
    printf '\n%s==> %s%s\n' "${C_BOLD:-}" "$1" "${C_RESET:-}"
}

info() {
    printf '    %s\n' "$1"
}

success() {
    printf '    %sok%s    %s\n' "${C_GREEN:-}" "${C_RESET:-}" "$1"
}

warning() {
    printf '    %swarn%s  %s\n' "${C_YELLOW:-}" "${C_RESET:-}" "$1" >&2
}

fail() {
    printf '\n    %sfail%s  %s\n' "${C_RED:-}" "${C_RESET:-}" "$1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command '$1' was not found on PATH"
}

validate_toolchain() {
    step "Validating Swift toolchain"

    require_command "swift"
    require_command "xcode-select"
    require_command "xcrun"

    local version major selected developer remainder
    version="$(swift --version 2>&1 || true)"
    selected="$(xcrun --find swift 2>/dev/null || true)"
    developer="$(xcode-select -p 2>/dev/null || true)"

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then info "$line"; fi
    done <<<"$version"

    info "swift path:    ${selected:-unresolved}"
    info "developer dir: ${developer:-unresolved}"

    # `swift --version` prints "Apple Swift version 6.3.3 (...)" on its first
    # line, which also contains "swift-driver version" — parse by pattern
    # instead of by field so the two numbers never collide.
    major=""
    if [[ "$version" == *"Apple Swift version "* ]]; then
        remainder="${version#*Apple Swift version }"
        major="${remainder%%.*}"
    fi

    if [[ ! "$major" =~ ^[0-9]+$ ]]; then
        fail "could not parse the Swift version from 'swift --version' output"
    fi

    if (( major < MINIMUM_SWIFT_MAJOR )); then
        fail "Swift $major is too old — Package.swift requires swift-tools-version 6.0"
    fi

    success "Swift toolchain is usable (Apple Swift $major.x)"
}

validate_host() {
    step "Validating host capabilities"

    local macos arch macos_major
    macos="$(sw_vers -productVersion)"
    arch="$(uname -m)"
    macos_major="${macos%%.*}"

    info "macOS: $macos"
    info "arch:   $arch"

    if (( macos_major < MINIMUM_MACOS_MAJOR )); then
        warning "macOS $macos is below the $MINIMUM_MACOS_MAJOR.0 deployment floor — the app will not run here"
    else
        success "macOS $macos meets the $MINIMUM_MACOS_MAJOR.0 deployment floor"
    fi

    if [[ "$arch" == "arm64" ]]; then
        success "Apple Silicon host — the Neural Engine OCR path is available"
    else
        warning "$arch host detected — DayPilot needs Apple Silicon for on-device OCR"
    fi
}

# ---------------------------------------------------------------------------
# Scaffold
# ---------------------------------------------------------------------------

scaffold() {
    step "Scaffolding source tree"

    local directory
    for directory in "${MODULE_DIRECTORIES[@]}" "${RESOURCE_DIRECTORIES[@]}"; do
        if [[ -d "$directory" ]]; then
            info "$directory already exists"
        else
            mkdir -p "$directory"
            info "created $directory"
        fi
    done

    for directory in "${EMPTY_MODULE_DIRECTORIES[@]}"; do
        touch "$directory/.gitkeep"
    done

    local required
    for required in "${REQUIRED_FILES[@]}"; do
        [[ -f "$required" ]] || fail "missing $required — restore it before building"
    done
    success "required build files are in place"

    # Keep every script in the repo executable; bootstrap re-signs itself so a
    # fresh clone works without a manual chmod.
    chmod +x "$0"
    local script
    while IFS= read -r script; do
        chmod +x "$script"
    done < <(find . -name '*.sh' -not -path './.build/*' -type f 2>/dev/null || true)
    success "scripts made executable"
}

verify_scaffold() {
    step "Verifying scaffold"

    local path
    for path in "${MODULE_DIRECTORIES[@]}" "${RESOURCE_DIRECTORIES[@]}"; do
        [[ -d "$path" ]] || fail "expected directory $path to exist"
    done
    success "all module directories present"

    info ""
    info "Sources tree:"
    (cd Sources && find . -type d | sort | while IFS= read -r path; do info "  $path"; done)
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

main() {
    printf '%s%s bootstrap%s — Phase 1 scaffold and harness validation' \
        "${C_BOLD:-}" "$PROJECT_NAME" "${C_RESET:-}"

    validate_toolchain
    validate_host
    scaffold
    verify_scaffold

    step "Next steps"
    info "make build      compile the release binary"
    info "make selftest   run the system health check and exit"
    info "make run        package the signed app and open it"
    info "make install    copy DayPilot.app into /Applications"
    printf '\n'
}

# Run from the project root regardless of where the script is invoked from.
cd "$(dirname "$0")"
main "$@"
