#!/bin/sh
# ssh.sh - SSH connection and remote execution for alpine-anywhere

# =============================================================================
# SSH Configuration
# =============================================================================

# SSH multiplexing socket path
SSH_CONTROL_PATH=""

# Setup SSH multiplexing for connection reuse (enables sudo credential caching)
setup_ssh_multiplexing() {
    # Keep the control socket out of world-writable /tmp (where another local
    # user could pre-create or symlink the path). Prefer XDG_RUNTIME_DIR, else a
    # private ~/.ssh/ - both are 0700 and short enough for the macOS 104-byte
    # socket path limit (%C is a short hash).
    _ssm_dir="${XDG_RUNTIME_DIR:-$HOME/.ssh}"
    mkdir -p "$_ssm_dir" 2>/dev/null || _ssm_dir="$HOME/.ssh"
    chmod 700 "$_ssm_dir" 2>/dev/null || true
    SSH_CONTROL_PATH="${_ssm_dir}/aa-%C"
    log_debug "SSH multiplexing enabled: $SSH_CONTROL_PATH"
}

# Close SSH multiplexing connection
close_ssh_multiplexing() {
    if [ -n "$SSH_CONTROL_PATH" ]; then
        ssh_opts=$(_ssh_opts_no_batch)
        # shellcheck disable=SC2086
        ssh $ssh_opts -O exit "${TARGET_USER}@${TARGET_HOST}" 2>/dev/null || true
    fi
}

# Host-key verification options, shared by all three builders so they can never
# drift apart. With --known-hosts/--ssh-fingerprint we enforce a pinned key
# (StrictHostKeyChecking=yes against a dedicated file); otherwise we keep TOFU
# (accept-new) but the pinned fingerprint is printed once so the operator can
# detect a changed key (see announce_pinned_fingerprint).
_ssh_hostkey_opts() {
    if [ -n "$SSH_KNOWN_HOSTS" ]; then
        echo "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$SSH_KNOWN_HOSTS"
    else
        echo "-o StrictHostKeyChecking=accept-new"
    fi
}

# Build SSH options as a string (bash 3 compatible) - batch mode
_ssh_opts() {
    opts="-o BatchMode=yes"
    opts="$opts $(_ssh_hostkey_opts)"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -o ServerAliveInterval=30"
    opts="$opts -o ServerAliveCountMax=3"
    opts="$opts -p $SSH_PORT"

    # Add multiplexing if enabled
    if [ -n "$SSH_CONTROL_PATH" ]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [ -n "$SSH_IDENTITY" ]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    # Extra caller-supplied options (e.g. "-J root@jump" from warren
    # deploy tooling when the operator's VPN blocks direct SSH).
    if [ -n "${AA_SSH_EXTRA_OPTS:-}" ]; then
        opts="$opts $AA_SSH_EXTRA_OPTS"
    fi

    echo "$opts"
}

# Build SSH options without batch mode (for interactive password prompts)
_ssh_opts_no_batch() {
    opts="$(_ssh_hostkey_opts)"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -o ServerAliveInterval=30"
    opts="$opts -o ServerAliveCountMax=3"
    opts="$opts -p $SSH_PORT"

    # Add multiplexing if enabled
    if [ -n "$SSH_CONTROL_PATH" ]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [ -n "$SSH_IDENTITY" ]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    # Extra caller-supplied options (e.g. "-J root@jump" from warren
    # deploy tooling when the operator's VPN blocks direct SSH).
    if [ -n "${AA_SSH_EXTRA_OPTS:-}" ]; then
        opts="$opts $AA_SSH_EXTRA_OPTS"
    fi

    echo "$opts"
}

# Build SCP options (uses -P for port instead of -p)
_scp_opts() {
    opts="-o BatchMode=yes"
    opts="$opts $(_ssh_hostkey_opts)"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -P $SSH_PORT"

    # Add multiplexing if enabled
    if [ -n "$SSH_CONTROL_PATH" ]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [ -n "$SSH_IDENTITY" ]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    # Extra caller-supplied options (e.g. "-J root@jump" from warren
    # deploy tooling when the operator's VPN blocks direct SSH).
    if [ -n "${AA_SSH_EXTRA_OPTS:-}" ]; then
        opts="$opts $AA_SSH_EXTRA_OPTS"
    fi

    echo "$opts"
}

# =============================================================================
# SSH Execution Functions
# =============================================================================

# Execute command on remote host
ssh_exec() {
    command="$1"
    ssh_opts=$(_ssh_opts)

    log_debug "SSH exec: $command"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] ssh $ssh_opts ${TARGET_USER}@${TARGET_HOST} '$command'"
        return 0
    fi

    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# Execute command on remote host with sudo if needed
ssh_exec_sudo() {
    command="$1"

    if [ "$TARGET_USER" = "root" ]; then
        ssh_exec "$command"
    else
        # Use interactive mode with TTY for sudo password prompt if needed
        ssh_exec_interactive "sudo $command"
    fi
}

# Execute command and capture output (for dry-run, still runs to get real data)
ssh_exec_capture() {
    command="$1"
    ssh_opts=$(_ssh_opts)

    log_debug "SSH capture: $command"

    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# Execute command interactively (with TTY for password prompts)
ssh_exec_interactive() {
    command="$1"
    ssh_opts=$(_ssh_opts_no_batch)

    log_debug "SSH interactive: $command"

    # shellcheck disable=SC2086
    ssh -t $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# Execute a LITERAL script on the remote host with ZERO interpolation.
# The script text is piped to a remote `sh -s`; any data is passed as
# positional parameters ("$1".."$N") which the remote shell receives verbatim -
# shell metacharacters in the values cannot break out of the command.
# This is the injection-safe replacement for `ssh_exec "...$VAR..."`.
#
# Usage: ssh_exec_script 'echo "host=$1 dir=$2"; mkdir -p "$2"' "$HOSTNAME" "$DIR"
ssh_exec_script() {
    _ses_script="$1"; shift
    _ses_args=""
    for _ses_a in "$@"; do
        _ses_args="$_ses_args $(shell_quote "$_ses_a")"
    done
    ssh_opts=$(_ssh_opts)

    log_debug "SSH exec-script (${#_ses_script} bytes, $# args)"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] ssh ${TARGET_USER}@${TARGET_HOST} sh -s --$_ses_args <<'SCRIPT'"
        printf '%s\n' "$_ses_script"
        echo "SCRIPT"
        return 0
    fi

    # shellcheck disable=SC2086
    printf '%s\n' "$_ses_script" \
        | ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "sh -s --$_ses_args"
}

# Same as ssh_exec_script but runs the remote script under sudo when the target
# user is not root. Because sudo may need a TTY for the password prompt and the
# script arrives on stdin, we stage the script to a temp file on the remote and
# execute it by path (the path itself is shell-quoted). Data still travels as
# positional parameters, never interpolated into the script body.
ssh_exec_script_sudo() {
    _sess_script="$1"; shift

    if [ "$TARGET_USER" = "root" ]; then
        ssh_exec_script "$_sess_script" "$@"
        return $?
    fi

    _sess_args=""
    for _sess_a in "$@"; do
        _sess_args="$_sess_args $(shell_quote "$_sess_a")"
    done

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] (sudo) remote script with$_sess_args"
        printf '%s\n' "$_sess_script"
        return 0
    fi

    # Stage to an unpredictable remote temp file, then sudo-exec it by path.
    _sess_remote=$(ssh_exec_capture "mktemp /tmp/aa-script.XXXXXX") || die "cannot create remote temp script"
    printf '%s\n' "$_sess_script" | ssh_exec "cat > $(shell_quote "$_sess_remote")"
    ssh_exec_interactive "sudo sh $(shell_quote "$_sess_remote") --$_sess_args; _rc=\$?; rm -f $(shell_quote "$_sess_remote"); exit \$_rc"
}

# =============================================================================
# SCP Functions
# =============================================================================

# Copy file to remote host.
# Uses `ssh ... cat > dest` instead of scp/sftp so it works against minimal
# hosts that ship neither the scp binary nor /usr/lib/ssh/sftp-server (e.g. the
# immutable Alpine image itself). If remote_path ends with '/', the source
# basename is appended (scp-like directory semantics).
scp_to_remote() {
    local_path="$1"
    remote_path="$2"
    ssh_opts=$(_ssh_opts)

    log_debug "Copy to remote (cat): $local_path -> $remote_path"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] cat '$local_path' | ssh ${TARGET_USER}@${TARGET_HOST} 'cat > $remote_path'"
        return 0
    fi

    dest="$remote_path"
    case "$dest" in
        */) dest="${dest}$(basename "$local_path")" ;;
    esac

    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "cat > '$dest'" < "$local_path"
}

# Copy a directory's CONTENTS to a remote directory via a tar stream over ssh
# (busybox tar is enough; no scp/sftp needed). Creates remote_path if missing.
scp_dir_to_remote() {
    local_path="$1"
    remote_path="$2"
    ssh_opts=$(_ssh_opts)

    log_debug "Copy dir to remote (tar): $local_path -> $remote_path"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] tar -C '$local_path' -cf - . | ssh ${TARGET_USER}@${TARGET_HOST} 'tar -C $remote_path -xf -'"
        return 0
    fi

    # shellcheck disable=SC2086
    tar -C "$local_path" -cf - . \
        | ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "mkdir -p '$remote_path' && tar -C '$remote_path' -xf -"
}

# =============================================================================
# Connection Testing
# =============================================================================

# Test SSH connection
test_ssh_connection() {
    log_step "Testing SSH connection to ${TARGET_USER}@${TARGET_HOST}..."

    ssh_opts=$(_ssh_opts_no_batch)

    # First connection may prompt for password - use interactive mode
    # This also establishes the multiplexed connection for subsequent commands
    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "echo 'Connection successful'" >/dev/null; then
        die "Cannot connect to ${TARGET_USER}@${TARGET_HOST} on port ${SSH_PORT}. Check credentials and connectivity."
    fi

    log_info "SSH connection successful"
    announce_pinned_fingerprint
}

# Make the host-key trust decision visible (and enforce an out-of-band pin when
# one was supplied). With --ssh-fingerprint we verify the live key matches and
# abort on mismatch (MITM defence); otherwise we print the fingerprint so the
# operator can compare it against an out-of-band value and notice key changes.
# Best-effort: a missing ssh-keyscan only downgrades to a warning (unless a
# fingerprint was explicitly pinned and we cannot confirm it).
announce_pinned_fingerprint() {
    command_exists ssh-keyscan && command_exists ssh-keygen || {
        [ -n "$SSH_FINGERPRINT" ] && die "ssh-keyscan/ssh-keygen needed to verify --ssh-fingerprint"
        return 0
    }
    _apf_keys=$(ssh-keyscan -p "$SSH_PORT" -T 10 "$TARGET_HOST" 2>/dev/null) || true
    [ -n "$_apf_keys" ] || { log_warn "Could not read host key for fingerprint pinning"; return 0; }
    _apf_fp=$(printf '%s\n' "$_apf_keys" | ssh-keygen -lf - 2>/dev/null | sort -u)

    if [ -n "$SSH_FINGERPRINT" ]; then
        if printf '%s\n' "$_apf_fp" | grep -qF "$SSH_FINGERPRINT"; then
            log_info "Host-key fingerprint matches the pinned value ✓"
        else
            log_error "Pinned fingerprint NOT found among host keys:"
            printf '%s\n' "$_apf_fp" >&2
            die "Host-key fingerprint mismatch for ${TARGET_HOST} - possible MITM. Aborting."
        fi
    else
        log_info "Host-key fingerprint (pin this out-of-band to detect MITM):"
        printf '%s\n' "$_apf_fp" >&2
    fi
}

# Check if we have root or sudo access
check_root_access() {
    log_step "Checking root/sudo access..."

    # In dry-run mode, skip actual sudo check
    if [ "$DRY_RUN" = "true" ]; then
        log_info "Root access check skipped (dry-run mode)"
        return 0
    fi

    if [ "$TARGET_USER" = "root" ]; then
        log_info "Running as root"
        return 0
    fi

    # Test passwordless sudo first
    if ssh_exec_capture "sudo -n true" >/dev/null 2>&1; then
        log_info "Passwordless sudo available"
        return 0
    fi

    # Try interactive sudo - user will be prompted for password
    log_info "Sudo requires password - you may be prompted"
    if ssh_exec_interactive "sudo true"; then
        log_info "Sudo access confirmed"
        return 0
    fi

    die "Cannot get sudo access. Check your password or sudo configuration."
}

# =============================================================================
# SSH Key Detection
# =============================================================================

# Get authorized keys from remote host
get_remote_authorized_keys() {
    log_step "Retrieving SSH authorized keys..."

    keys=""

    # Try to get keys from current user
    keys=$(ssh_exec_capture "cat ~/.ssh/authorized_keys 2>/dev/null || true")

    # If user is not root, also try root's keys
    if [ "$TARGET_USER" != "root" ]; then
        root_keys=$(ssh_exec_capture "sudo -n cat /root/.ssh/authorized_keys 2>/dev/null || true")
        if [ -n "$root_keys" ]; then
            if [ -n "$keys" ]; then
                keys="${keys}
${root_keys}"
            else
                keys="$root_keys"
            fi
        fi
    fi

    # Remove duplicates and empty lines. Also drop the cloud-image
    # forced-command trap: many VPS Debian/Ubuntu images ship root's
    # authorized_keys with a `command="echo 'Please login as the user
    # \"...\" rather than the user \"root\".';..."` wrapper on the injected
    # key. Baked verbatim, dropbear matches it FIRST and refuses root SSH
    # (which `aa upgrade` needs) after the box reboots into the image. Keep
    # only clean key lines.
    keys=$(echo "$keys" | grep -v 'Please login as' | sort -u | grep -v '^$' || true)

    if [ -z "$keys" ]; then
        log_warn "No SSH authorized keys found on remote host!"
        if [ "$FORCE" != "true" ]; then
            die "No SSH keys found. You may lose access after reboot. Use --force to continue anyway."
        fi
    else
        key_count=$(echo "$keys" | wc -l | tr -d ' ')
        log_info "Found $key_count SSH key(s)"
    fi

    echo "$keys"
}

# =============================================================================
# Wait for Host
# =============================================================================

# Wait for host to come back online
wait_for_host() {
    timeout="${1:-180}"
    interval=5
    elapsed=0

    log_step "Waiting for host to come back online (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh_exec_capture "echo 'alive'" >/dev/null 2>&1; then
            log_info "Host is back online!"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
        log_debug "Still waiting... (${elapsed}s/${timeout}s)"
    done

    die "Host did not come back online within ${timeout} seconds. Check console for errors."
}

# Verify Alpine Linux is running
verify_alpine_boot() {
    log_step "Verifying Alpine Linux boot..."

    os_release=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null || true")

    if echo "$os_release" | grep -qi "alpine"; then
        log_info "Successfully booted into Alpine Linux!"
        return 0
    else
        die "Host is online but does not appear to be running Alpine Linux"
    fi
}
