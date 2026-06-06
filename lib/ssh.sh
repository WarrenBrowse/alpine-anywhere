#!/bin/bash
# ssh.sh - SSH connection and remote execution for alpine-anywhere

# =============================================================================
# SSH Configuration
# =============================================================================

# Build SSH options as a string (bash 3 compatible)
_ssh_opts() {
    local opts="-o BatchMode=yes"
    opts="$opts -o StrictHostKeyChecking=accept-new"
    opts="$opts -o ConnectTimeout=10"
    opts="$opts -o ServerAliveInterval=30"
    opts="$opts -o ServerAliveCountMax=3"
    opts="$opts -p $SSH_PORT"

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
        ssh_exec "sudo -n $command"
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

# =============================================================================
# SCP Functions
# =============================================================================

# Copy file to remote host
scp_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local ssh_opts
    ssh_opts=$(_ssh_opts)

    log_debug "SCP to remote: $local_path -> $remote_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] scp $ssh_opts '$local_path' '${TARGET_USER}@${TARGET_HOST}:$remote_path'"
        return 0
    fi

    # shellcheck disable=SC2086
    scp $ssh_opts "$local_path" "${TARGET_USER}@${TARGET_HOST}:$remote_path"
}

# Copy directory to remote host
scp_dir_to_remote() {
    local local_path="$1"
    local remote_path="$2"
    local ssh_opts
    ssh_opts=$(_ssh_opts)

    log_debug "SCP dir to remote: $local_path -> $remote_path"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] scp -r $ssh_opts '$local_path' '${TARGET_USER}@${TARGET_HOST}:$remote_path'"
        return 0
    fi

    # shellcheck disable=SC2086
    scp -r $ssh_opts "$local_path" "${TARGET_USER}@${TARGET_HOST}:$remote_path"
}

# =============================================================================
# Connection Testing
# =============================================================================

# Test SSH connection
test_ssh_connection() {
    log_step "Testing SSH connection to ${TARGET_USER}@${TARGET_HOST}..."

    local ssh_opts
    ssh_opts=$(_ssh_opts)

    # shellcheck disable=SC2086
    if ! ssh $ssh_opts "${TARGET_USER}@${TARGET_HOST}" "echo 'Connection successful'" >/dev/null 2>&1; then
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

    local can_root=false

    if [[ "$TARGET_USER" == "root" ]]; then
        can_root=true
    else
        # Test sudo access
        if ssh_exec_capture "sudo -n true" >/dev/null 2>&1; then
            can_root=true
        fi
    fi

    if [[ "$can_root" != "true" ]]; then
        die "Cannot get root access. Either login as root or ensure passwordless sudo is configured."
    fi

    log_info "Root access confirmed"
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
