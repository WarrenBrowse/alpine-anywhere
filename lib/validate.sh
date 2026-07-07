#!/bin/sh
# validate.sh - Pre-flight validations for alpine-anywhere

# =============================================================================
# Input sanitization
# =============================================================================
#
# Values that end up on the kernel command line (root=, ip=, modloop=, apkovl=,
# alpine_repo=) are placed inside `--command-line="..."`, where shell quoting
# does NOT protect us (the kernel re-parses the string). The only safe defence
# is to constrain these inputs to a benign character set at the source. Anything
# that reaches a remote shell is additionally shell_quote'd, but these tokens
# get a charset check on top.

# Abort unless VALUE matches the safe-token charset (alnum and . _ / : = , @ + -).
# Empty values pass (callers gate on emptiness separately where it matters).
# Usage: assert_safe_token NAME "$VALUE"
assert_safe_token() {
    _ast_name="$1"; _ast_val="$2"
    case "$_ast_val" in
        '') return 0 ;;
        *[!A-Za-z0-9._/:=,@+-]*)
            die "unsafe characters in ${_ast_name}: '${_ast_val}' (allowed: alphanumerics and . _ / : = , @ + -)"
            ;;
    esac
    return 0
}

# Validate the inputs that flow into remote shells and the kernel cmdline.
# Call after parse_arguments and after network detection populates DETECTED_*.
validate_safe_inputs() {
    assert_safe_token "alpine-version" "$ALPINE_VERSION"
    assert_safe_token "mirror" "$ALPINE_MIRROR"
    assert_safe_token "kernel-flavor" "$KERNEL_FLAVOR"
    assert_safe_token "ssh-port" "$SSH_PORT"
    assert_safe_token "target-disk" "$TARGET_DISK"
    assert_safe_token "target-slot" "$TARGET_SLOT"
    assert_safe_token "overlay-device" "$OVERLAY_DEVICE"
    assert_safe_token "extra-packages" "$EXTRA_PACKAGES"
    # DETECTED_* may be empty before network detection; checked again post-detect
    assert_safe_token "detected-hostname" "$DETECTED_HOSTNAME"
    assert_safe_token "detected-interface" "$DETECTED_INTERFACE"
    assert_safe_token "detected-ip" "$DETECTED_IP_ADDRESS"
    assert_safe_token "detected-netmask" "$DETECTED_NETMASK"
    assert_safe_token "detected-gateway" "$DETECTED_GATEWAY"
    assert_safe_token "detected-cidr" "$DETECTED_CIDR"
    # SSH_PORT must be numeric on top of the charset check
    case "$SSH_PORT" in
        ''|*[!0-9]*) die "SSH port must be numeric: '$SSH_PORT'" ;;
    esac
    # TARGET_DISK, when set, must look like a device path
    if [ -n "$TARGET_DISK" ]; then
        case "$TARGET_DISK" in
            /dev/*) : ;;
            *) die "target disk must be a /dev path: '$TARGET_DISK'" ;;
        esac
    fi

    # Data-persistence inputs
    assert_safe_token "key-url" "$KEY_URL"
    case "$DATA_FS" in btrfs|ext4) ;; *) die "invalid --data-fs '$DATA_FS' (btrfs|ext4)" ;; esac
    case "$UNLOCK_METHOD" in ssh|keyfile|passphrase) ;; *) die "invalid --unlock-method '$UNLOCK_METHOD' (ssh|keyfile|passphrase)" ;; esac
    case "$CONTAINERS" in none|podman|docker|both) ;; *) die "invalid --containers '$CONTAINERS' (none|podman|docker|both)" ;; esac
    case "$CONTAINER_RUNTIME" in crun|runsc) ;; *) die "invalid --container-runtime '$CONTAINER_RUNTIME' (crun|runsc)" ;; esac
    # keyfile method: --key-url fetches the key at boot; with no URL, aa generates
    # a random key and stages it on the boot partition (zero-config autonomous unlock).

    # Customization inputs: fail early on the control host if the path is missing
    # (run_custom_script re-checks inside the chroot, but a clear message here
    # avoids deploying only to abort mid-build).
    if [ -n "$CUSTOM_SCRIPT" ] && [ ! -f "$CUSTOM_SCRIPT" ]; then
        die "custom script not found: '$CUSTOM_SCRIPT'"
    fi
    if [ -n "$CUSTOM_FILES" ] && [ ! -e "$CUSTOM_FILES" ]; then
        die "custom files path not found: '$CUSTOM_FILES'"
    fi
}

# =============================================================================
# Local Validations
# =============================================================================

# Check required local commands
validate_local_commands() {
    log_step "Validating local commands..."

    # In local mode we run ON the target, so ssh/scp (control-host tools) are
    # not needed there; only the archive tools are. A download tool (curl OR
    # busybox wget) is required in both modes.
    local required_commands
    if [ "$LOCAL_MODE" = "true" ]; then
        required_commands="tar gzip"
    else
        required_commands="ssh tar gzip"
    fi
    local missing=""

    for cmd in $required_commands; do
        if ! command_exists "$cmd"; then
            missing="${missing:+$missing }$cmd"
        fi
    done

    # Need at least one HTTP download tool
    if ! command_exists curl && ! command_exists wget; then
        missing="${missing:+$missing }curl-or-wget"
    fi

    if [ -n "$missing" ]; then
        die "Missing required commands: $missing"
    fi

    log_info "All required local commands are available"
}
