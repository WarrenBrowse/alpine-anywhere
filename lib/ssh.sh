#!/bin/bash
# ssh.sh - SSH connection and remote execution for alpine-anywhere

# =============================================================================
# SSH Configuration
# =============================================================================

# SSH multiplexing socket path
SSH_CONTROL_PATH=""

# Setup SSH multiplexing for connection reuse (enables sudo credential caching)
setup_ssh_multiplexing() {
    # Use short path to avoid macOS 104-byte socket path limit
    SSH_CONTROL_PATH="/tmp/aa-$$-%C"
    log_debug "SSH multiplexing enabled: $SSH_CONTROL_PATH"
}

# Close SSH multiplexing connection
close_ssh_multiplexing() {
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        local ssh_opts
        ssh_opts=$(_ssh_opts_no_batch)
        # shellcheck disable=SC2086
        ssh $ssh_opts -O exit "${TARGET_USER}@${TARGET_HOST}" 2>/dev/null || true
    fi
}

# Build SSH options as a string (bash 3 compatible) - batch mode
_ssh_opts() {
    local opts="-o BatchMode=yes"
    opts="$opts -o StrictHostKeyChecking=accept-new"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -o ServerAliveInterval=30"
    opts="$opts -o ServerAliveCountMax=3"
    opts="$opts -p $SSH_PORT"

    # Add multiplexing if enabled
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [[ -n "$SSH_IDENTITY" ]]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    echo "$opts"
}

# Build SSH options without batch mode (for interactive password prompts)
_ssh_opts_no_batch() {
    local opts="-o StrictHostKeyChecking=accept-new"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -o ServerAliveInterval=30"
    opts="$opts -o ServerAliveCountMax=3"
    opts="$opts -p $SSH_PORT"

    # Add multiplexing if enabled
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [[ -n "$SSH_IDENTITY" ]]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    echo "$opts"
}

# Build SCP options (uses -P for port instead of -p)
_scp_opts() {
    local opts="-o BatchMode=yes"
    opts="$opts -o StrictHostKeyChecking=accept-new"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -P $SSH_PORT"

    # Add multiplexing if enabled
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        opts="$opts -o ControlPath=$SSH_CONTROL_PATH"
        opts="$opts -o ControlMaster=auto"
        opts="$opts -o ControlPersist=300"
    fi

    if [[ -n "$SSH_IDENTITY" ]]; then
        opts="$opts -i $SSH_IDENTITY"
    fi

    echo "$opts"
}

# =============================================================================
# SSH Execution Functions
# =============================================================================

# Execute command on remote host
ssh_exec() {
    local command="$1"
    local ssh_opts
    ssh_opts=$(_ssh_opts)

    log_debug "SSH exec: $command"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] ssh $ssh_opts ${TARGET_USER}@${TARGET_HOST} '$command'"
        return 0
    fi

    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# Execute command on remote host with sudo if needed
ssh_exec_sudo() {
    local command="$1"

    if [[ "$TARGET_USER" == "root" ]]; then
        ssh_exec "$command"
    else
        # Use interactive mode with TTY for sudo password prompt if needed
        ssh_exec_interactive "sudo $command"
    fi
}

# Execute command and capture output (for dry-run, still runs to get real data)
ssh_exec_capture() {
    local command="$1"
    local ssh_opts
    ssh_opts=$(_ssh_opts)

    log_debug "SSH capture: $command"

    # shellcheck disable=SC2086
    ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# Execute command interactively (with TTY for password prompts)
ssh_exec_interactive() {
    local command="$1"
    local ssh_opts
    ssh_opts=$(_ssh_opts_no_batch)

    log_debug "SSH interactive: $command"

    # shellcheck disable=SC2086
    ssh -t $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "$command"
}

# =============================================================================
# SCP Functions
# =============================================================================

# Copy file to remote host
scp_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local scp_opts
    scp_opts=$(_scp_opts)

    log_debug "SCP to remote: $local_path -> $remote_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] scp $scp_opts '$local_path' '${TARGET_USER}@${TARGET_HOST}:$remote_path'"
        return 0
    fi

    # shellcheck disable=SC2086
    scp $scp_opts "$local_path" "${TARGET_USER}@${TARGET_HOST}:$remote_path"
}

# Copy directory to remote host
scp_dir_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local scp_opts
    scp_opts=$(_scp_opts)

    log_debug "SCP dir to remote: $local_path -> $remote_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] scp -r $scp_opts '$local_path' '${TARGET_USER}@${TARGET_HOST}:$remote_path'"
        return 0
    fi

    # shellcheck disable=SC2086
    scp -r $scp_opts "$local_path" "${TARGET_USER}@${TARGET_HOST}:$remote_path"
}

# =============================================================================
# Connection Testing
# =============================================================================

# Test SSH connection
test_ssh_connection() {
    log_step "Testing SSH connection to ${TARGET_USER}@${TARGET_HOST}..."

    local ssh_opts
    ssh_opts=$(_ssh_opts_no_batch)

    # First connection may prompt for password - use interactive mode
    # This also establishes the multiplexed connection for subsequent commands
    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "echo 'Connection successful'" >/dev/null; then
        die "Cannot connect to ${TARGET_USER}@${TARGET_HOST} on port ${SSH_PORT}. Check credentials and connectivity."
    fi

    log_info "SSH connection successful"
}

# Check if we have root or sudo access
check_root_access() {
    log_step "Checking root/sudo access..."

    # In dry-run mode, skip actual sudo check
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Root access check skipped (dry-run mode)"
        return 0
    fi

    if [[ "$TARGET_USER" == "root" ]]; then
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

    local keys=""

    # Try to get keys from current user
    keys=$(ssh_exec_capture "cat ~/.ssh/authorized_keys 2>/dev/null || true")

    # If user is not root, also try root's keys
    if [[ "$TARGET_USER" != "root" ]]; then
        local root_keys
        root_keys=$(ssh_exec_capture "sudo -n cat /root/.ssh/authorized_keys 2>/dev/null || true")
        if [[ -n "$root_keys" ]]; then
            if [[ -n "$keys" ]]; then
                keys="$keys"$'\n'"$root_keys"
            else
                keys="$root_keys"
            fi
        fi
    fi

    # Remove duplicates and empty lines
    keys=$(echo "$keys" | sort -u | grep -v '^$' || true)

    if [[ -z "$keys" ]]; then
        log_warn "No SSH authorized keys found on remote host!"
        if [[ "$FORCE" != "true" ]]; then
            die "No SSH keys found. You may lose access after reboot. Use --force to continue anyway."
        fi
    else
        local key_count
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
    local timeout="${1:-180}"
    local interval=5
    local elapsed=0

    log_step "Waiting for host to come back online (timeout: ${timeout}s)..."

    while ((elapsed < timeout)); do
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

    local os_release
    os_release=$(ssh_exec_capture "cat /etc/os-release 2>/dev/null || true")

    if echo "$os_release" | grep -qi "alpine"; then
        log_info "Successfully booted into Alpine Linux!"
        return 0
    else
        die "Host is online but does not appear to be running Alpine Linux"
    fi
}
