#!/bin/sh
# custom_files_spec.sh - --custom-files staging + custom-services init hook
# (the generic extension points used by external deploy scripts, e.g. warren).

Describe 'custom files & custom services'
    Include lib/common.sh
    Include lib/validate.sh
    Include lib/install.sh
    Include lib/init_s6.sh

    Describe 'flag parsing'
        It '--custom-files PATH sets CUSTOM_FILES'
            When call parse_arguments --install --custom-files /tmp/x --local
            The variable CUSTOM_FILES should equal "/tmp/x"
        End

        It '--custom-files=PATH (= form) sets CUSTOM_FILES'
            When call parse_arguments --install --custom-files=/tmp/y --local
            The variable CUSTOM_FILES should equal "/tmp/y"
        End
    End

    Describe 'validation'
        It 'rejects a missing --custom-files path'
            BeforeRun 'CUSTOM_FILES=/nonexistent/path/aa'
            When run validate_safe_inputs
            The status should be failure
            The stderr should include "custom files path not found"
        End

        It 'accepts an existing --custom-files path'
            BeforeRun 'CUSTOM_FILES=/tmp'
            When run validate_safe_inputs
            The status should be success
        End
    End

    Describe 'run_custom_script staging'
        setup() {
            ROOT=$(mktemp -d); mkdir -p "$ROOT/tmp"
            FILES=$(mktemp -d); printf 'payload-content' > "$FILES/payload.txt"
            EVID=$(mktemp -d)
            SCRIPT=$(mktemp); printf '#!/bin/sh\ntrue\n' > "$SCRIPT"
            CUSTOM_SCRIPT="$SCRIPT"; CUSTOM_FILES="$FILES"
            # Mock the chroot: capture its args + prove the staged file is present
            # at the moment the hook would run (before run_custom_script cleans up).
            chroot() {
                printf '%s\n' "$*" > "$EVID/args"
                cp "$1/tmp/aa-custom-files/payload.txt" "$EVID/staged" 2>/dev/null
                return 0
            }
        }
        cleanup() { rm -rf "$ROOT" "$FILES" "$EVID" "$SCRIPT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup'

        It 'stages --custom-files into the chroot and exposes AA_CUSTOM_FILES_DIR'
            When call run_custom_script "$ROOT"
            The status should be success
            The contents of file "$EVID/staged" should equal "payload-content"
            The contents of file "$EVID/args" should include "AA_CUSTOM_FILES_DIR=/tmp/aa-custom-files"
            The stderr should be present
        End

        It 'removes the staging dir after the hook'
            When call run_custom_script "$ROOT"
            The status should be success
            The path "$ROOT/tmp/aa-custom-files" should not be exist
            The stderr should be present
        End
    End

    Describe 'wire_custom_openrc_services'
        setup() {
            ROOT=$(mktemp -d)
            mkdir -p "$ROOT/etc/init.d" "$ROOT/etc/aa/custom-services.d" "$ROOT/sbin"
            printf '#!/sbin/openrc-run\ncommand=/usr/local/bin/warren-exit-launch\n' \
                > "$ROOT/etc/aa/custom-services.d/warren-exit.openrc"
            # rc-update is invoked via chroot; mock it to a no-op success.
            chroot() { return 0; }
        }
        cleanup() { rm -rf "$ROOT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup'

        It 'installs a .openrc service into /etc/init.d as executable'
            When call wire_custom_openrc_services "$ROOT"
            The status should be success
            The path "$ROOT/etc/init.d/warren-exit" should be exist
            The path "$ROOT/etc/init.d/warren-exit" should be executable
            The stderr should be present
        End
    End

    Describe 's6 custom-services slurp'
        setup() {
            ROOT=$(mktemp -d)
            # A raw s6-rc longrun definition dropped by a custom-script.
            svc="$ROOT/etc/aa/custom-services.d/warren-exit"
            mkdir -p "$svc/dependencies.d"
            printf 'longrun' > "$svc/type"
            printf '#!/bin/sh\nexec /usr/local/bin/warren-exit-launch\n' > "$svc/run"
            touch "$svc/dependencies.d/network"
            # Globals setup_s6_init reads:
            NETWORK_IS_DHCP=true; DETECTED_INTERFACE=eth0
            DETECTED_IP_ADDRESS=""; DETECTED_NETMASK=""; DETECTED_GATEWAY=""
            HARDENED_MODE=true; PERSIST_DATA=false
            # s6-rc-compile / s6-linux-init-maker run via chroot; mock them away.
            chroot() { return 0; }
        }
        cleanup() { rm -rf "$ROOT"; }
        BeforeEach 'setup'
        AfterEach 'cleanup'

        It 'copies the service into the s6-rc source and adds it to the default bundle'
            When call setup_s6_init "$ROOT"
            The status should be success
            The path "$ROOT/etc/s6-rc/source/warren-exit/type" should be exist
            The path "$ROOT/etc/s6-rc/source/default/contents.d/warren-exit" should be exist
            # s6 has no hostname service: rc.init must apply /etc/hostname itself,
            # else the kernel hostname stays "(none)".
            The contents of file "$ROOT/etc/s6-linux-init/skel/rc.init" should include "hostname"
            The stderr should be present
        End
    End
End
