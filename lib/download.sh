#!/bin/sh
# download.sh - Alpine CDN download functions for alpine-anywhere

# =============================================================================
# HTTP helpers (curl preferred, busybox wget fallback)
# =============================================================================

# Fetch a URL to a file. Returns non-zero on failure.
http_fetch_file() {
    _url="$1"; _dest="$2"
    if command_exists curl; then
        curl -fSL --progress-bar -o "$_dest" "$_url"
    elif command_exists wget; then
        wget -O "$_dest" "$_url"
    else
        die "Neither curl nor wget is available"
    fi
}

# Fetch a URL to stdout. Returns non-zero on failure.
http_fetch_stdout() {
    _url="$1"
    if command_exists curl; then
        curl -fsSL "$_url"
    elif command_exists wget; then
        wget -qO- "$_url"
    else
        return 1
    fi
}

# Quietly test that a URL is reachable.
http_check_url() {
    _url="$1"
    if command_exists curl; then
        curl -fsSL --connect-timeout 5 --max-time 10 "$_url" >/dev/null 2>&1
    elif command_exists wget; then
        wget -q -T 10 -O /dev/null "$_url" >/dev/null 2>&1
    else
        return 1
    fi
}

# =============================================================================
# Download Functions
# =============================================================================

# Verify a downloaded file against its published SHA-512.
# The checksum source is, in order of preference:
#   1. $CHECKSUM_DIR/<basename>.sha512  (air-gapped / pinned local copy)
#   2. <url>.sha512 fetched over HTTPS   (Alpine publishes these alongside
#      every netboot / minirootfs / release artifact)
# Honest trust model: Alpine does NOT publish detached GPG signatures for the
# netboot images, so the anchor here is HTTPS transport + the published
# sha512. apk packages pulled later are separately covered by the signed
# APKINDEX. Returns: 0 verified, 2 no checksum available (caller decides
# policy), dies on an actual mismatch.
verify_sha512() {
    _vs_url="$1"; _vs_dest="$2"
    _vs_name=$(basename "$_vs_dest")
    _vs_want=""

    if [ -n "$CHECKSUM_DIR" ] && [ -f "${CHECKSUM_DIR}/${_vs_name}.sha512" ]; then
        _vs_want=$(awk '{print $1}' "${CHECKSUM_DIR}/${_vs_name}.sha512")
        log_debug "Checksum source: ${CHECKSUM_DIR}/${_vs_name}.sha512"
    else
        _vs_want=$(http_fetch_stdout "${_vs_url}.sha512" 2>/dev/null | awk '{print $1}' || true)
        log_debug "Checksum source: ${_vs_url}.sha512"
    fi

    if [ -z "$_vs_want" ]; then
        log_warn "No .sha512 published for ${_vs_name}"
        return 2
    fi

    _vs_got=$(sha512_file "$_vs_dest")
    if [ "$_vs_want" != "$_vs_got" ]; then
        log_error "CHECKSUM MISMATCH for ${_vs_name}"
        log_error "  expected: $_vs_want"
        log_error "  got:      $_vs_got"
        die "Integrity check failed for ${_vs_name} - refusing to use a tampered/corrupt artifact"
    fi

    log_info "Integrity verified (sha512): ${_vs_name}"
    return 0
}

# Apply the fail-closed verification policy to a freshly downloaded file.
# --no-verify downgrades to a warning (documented unsafe). A missing checksum
# is fatal by default (paranoid VPN host) unless --no-verify is set.
enforce_integrity() {
    _ei_url="$1"; _ei_dest="$2"
    if [ "$NO_VERIFY" = "true" ]; then
        log_warn "Integrity check SKIPPED for $(basename "$_ei_dest") (--no-verify)"
        return 0
    fi
    verify_sha512 "$_ei_url" "$_ei_dest"
    case $? in
        0) return 0 ;;
        2) die "No checksum available for $(basename "$_ei_dest"). Use --checksum-dir or (unsafe) --no-verify." ;;
    esac
}

# Download a file with progress indication, then verify its integrity.
download_file() {
    url="$1"
    dest="$2"
    filename=$(basename "$dest")

    log_debug "Downloading: $url -> $dest"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] download '$url' -> '$dest'"
        return 0
    fi

    if ! http_fetch_file "$url" "$dest"; then
        die "Failed to download: $url"
    fi

    enforce_integrity "$url" "$dest"

    log_debug "Downloaded: $filename"
}

# Mirror reachability is checked (find_working_mirror_local) but integrity is
# enforced at DOWNLOAD time (verify_sha512/enforce_integrity), which fails closed
# with a clear message if a checksum is missing. Gating mirror SELECTION on a
# specific artifact's checksum was both fragile (artifact/layout varies by mode
# and arch) and wrong for install mode (which uses apk + minirootfs, not the
# netboot kernel).
# Consumed by find_working_mirror_local in the main script (cross-file).
# shellcheck disable=SC2034
FALLBACK_MIRRORS="https://dl-cdn.alpinelinux.org/alpine https://uk.alpinelinux.org/alpine https://nl.alpinelinux.org/alpine https://ftp.halifax.rwth-aachen.de/alpine"
