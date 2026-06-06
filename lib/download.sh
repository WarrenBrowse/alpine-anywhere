#!/bin/sh
# download.sh - Alpine CDN download functions for alpine-anywhere

# =============================================================================
# URL Building Functions
# =============================================================================

# Build base URL for Alpine releases
build_alpine_base_url() {
    echo "${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}"
}

# Build URL for a specific file
build_alpine_file_url() {
    file_type="$1"
    base_url=$(build_alpine_base_url)

    case "$file_type" in
        vmlinuz)
            echo "${base_url}/netboot/vmlinuz-${KERNEL_FLAVOR}"
            ;;
        initramfs)
            echo "${base_url}/netboot/initramfs-${KERNEL_FLAVOR}"
            ;;
        modloop)
            echo "${base_url}/netboot/modloop-${KERNEL_FLAVOR}"
            ;;
        *)
            die "Unknown file type: $file_type"
            ;;
    esac
}

# =============================================================================
# Download Functions
# =============================================================================

# Download a file with progress indication
download_file() {
    url="$1"
    dest="$2"
    filename=$(basename "$dest")

    log_debug "Downloading: $url -> $dest"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] curl -fsSL -o '$dest' '$url'"
        return 0
    fi

    if ! curl -fSL --progress-bar -o "$dest" "$url"; then
        die "Failed to download: $url"
    fi

    log_debug "Downloaded: $filename"
}

# Download all required Alpine files
download_alpine_files() {
    log_step "Downloading Alpine Linux files..."

    download_dir="${WORK_DIR}/alpine"
    mkdir -p "$download_dir"

    # Download vmlinuz
    vmlinuz_url=$(build_alpine_file_url vmlinuz)
    log_info "Downloading vmlinuz-${KERNEL_FLAVOR}..."
    download_file "$vmlinuz_url" "${download_dir}/vmlinuz"

    # Download initramfs
    initramfs_url=$(build_alpine_file_url initramfs)
    log_info "Downloading initramfs-${KERNEL_FLAVOR}..."
    download_file "$initramfs_url" "${download_dir}/initramfs"

    # Download modloop
    modloop_url=$(build_alpine_file_url modloop)
    log_info "Downloading modloop-${KERNEL_FLAVOR}..."
    download_file "$modloop_url" "${download_dir}/modloop"

    log_info "All Alpine files downloaded successfully"
}

# =============================================================================
# Verification Functions
# =============================================================================

# Verify downloaded files exist and have content
verify_downloads() {
    log_step "Verifying downloaded files..."

    # Skip verification in dry-run mode
    if [ "$DRY_RUN" = "true" ]; then
        log_info "File verification skipped (dry-run mode)"
        return 0
    fi

    download_dir="${WORK_DIR}/alpine"

    for file in vmlinuz initramfs modloop; do
        path="${download_dir}/${file}"
        if [ ! -f "$path" ]; then
            die "Missing file: $path"
        fi
        if [ ! -s "$path" ]; then
            die "Empty file: $path"
        fi
        log_debug "Verified: $file ($(du -h "$path" | cut -f1))"
    done

    log_info "All files verified"
}

# =============================================================================
# Mirror Functions
# =============================================================================

# List of fallback mirrors (space-separated string)
FALLBACK_MIRRORS="https://dl-cdn.alpinelinux.org/alpine https://uk.alpinelinux.org/alpine https://nl.alpinelinux.org/alpine https://ftp.halifax.rwth-aachen.de/alpine"

# Test if a mirror is accessible
test_mirror() {
    mirror="$1"
    test_url="${mirror}/v${ALPINE_VERSION}/releases/${DETECTED_ARCH}/"

    log_debug "Testing mirror: $mirror"

    if curl -fsSL --connect-timeout 5 --max-time 10 "$test_url" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Find a working mirror
find_working_mirror() {
    log_step "Finding a working Alpine mirror..."

    # Test configured mirror first
    if test_mirror "$ALPINE_MIRROR"; then
        log_info "Using configured mirror: $ALPINE_MIRROR"
        return 0
    fi

    log_warn "Configured mirror not available, trying fallbacks..."

    for mirror in $FALLBACK_MIRRORS; do
        if test_mirror "$mirror"; then
            ALPINE_MIRROR="$mirror"
            log_info "Using fallback mirror: $ALPINE_MIRROR"
            return 0
        fi
    done

    die "No working Alpine mirror found"
}
