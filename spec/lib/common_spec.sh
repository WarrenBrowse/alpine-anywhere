#!/bin/sh
# common_spec.sh - Tests for lib/common.sh

Describe 'common.sh'
    Include lib/common.sh

    Describe 'cidr_to_netmask()'
        It 'converts /32 to 255.255.255.255'
            When call cidr_to_netmask 32
            The output should equal '255.255.255.255'
        End

        It 'converts /24 to 255.255.255.0'
            When call cidr_to_netmask 24
            The output should equal '255.255.255.0'
        End

        It 'converts /16 to 255.255.0.0'
            When call cidr_to_netmask 16
            The output should equal '255.255.0.0'
        End

        It 'converts /8 to 255.0.0.0'
            When call cidr_to_netmask 8
            The output should equal '255.0.0.0'
        End

        It 'converts /0 to 0.0.0.0'
            When call cidr_to_netmask 0
            The output should equal '0.0.0.0'
        End

        It 'converts /25 to 255.255.255.128'
            When call cidr_to_netmask 25
            The output should equal '255.255.255.128'
        End

        It 'converts /22 to 255.255.252.0'
            When call cidr_to_netmask 22
            The output should equal '255.255.252.0'
        End
    End

    Describe 'netmask_to_cidr()'
        It 'converts 255.255.255.255 to 32'
            When call netmask_to_cidr '255.255.255.255'
            The output should equal '32'
        End

        It 'converts 255.255.255.0 to 24'
            When call netmask_to_cidr '255.255.255.0'
            The output should equal '24'
        End

        It 'converts 255.255.0.0 to 16'
            When call netmask_to_cidr '255.255.0.0'
            The output should equal '16'
        End

        It 'converts 255.0.0.0 to 8'
            When call netmask_to_cidr '255.0.0.0'
            The output should equal '8'
        End

        It 'converts 255.255.255.128 to 25'
            When call netmask_to_cidr '255.255.255.128'
            The output should equal '25'
        End
    End

    Describe 'is_valid_ip()'
        It 'returns success for valid IP 192.168.1.1'
            When call is_valid_ip '192.168.1.1'
            The status should be success
        End

        It 'returns success for valid IP 10.0.0.1'
            When call is_valid_ip '10.0.0.1'
            The status should be success
        End

        It 'returns success for valid IP 255.255.255.255'
            When call is_valid_ip '255.255.255.255'
            The status should be success
        End

        It 'returns success for valid IP 0.0.0.0'
            When call is_valid_ip '0.0.0.0'
            The status should be success
        End

        It 'returns failure for invalid IP with too many octets'
            When call is_valid_ip '192.168.1.1.1'
            The status should be failure
        End

        It 'returns failure for invalid IP with letters'
            When call is_valid_ip '192.168.1.abc'
            The status should be failure
        End

        It 'returns failure for invalid IP with octet > 255'
            When call is_valid_ip '192.168.1.256'
            The status should be failure
        End

        It 'returns failure for empty string'
            When call is_valid_ip ''
            The status should be failure
        End
    End

    Describe 'parse_target()'
        setup() {
            TARGET_USER=""
            TARGET_HOST=""
        }
        Before 'setup'

        It 'parses user@host format'
            When call parse_target 'testuser@192.168.1.100'
            The variable TARGET_USER should equal 'testuser'
            The variable TARGET_HOST should equal '192.168.1.100'
        End

        It 'parses root@hostname format'
            When call parse_target 'root@myserver.local'
            The variable TARGET_USER should equal 'root'
            The variable TARGET_HOST should equal 'myserver.local'
        End

        It 'defaults to root user when no @ present'
            When call parse_target '192.168.1.100'
            The variable TARGET_USER should equal 'root'
            The variable TARGET_HOST should equal '192.168.1.100'
        End
    End

    Describe 'command_exists()'
        It 'returns success for existing command (bash)'
            When call command_exists 'bash'
            The status should be success
        End

        It 'returns failure for non-existing command'
            When call command_exists 'nonexistent_command_xyz123'
            The status should be failure
        End
    End

    Describe 'log functions'
        It 'log_info outputs to stderr'
            When call log_info 'test message'
            The stderr should include 'INFO'
            The stderr should include 'test message'
        End

        It 'log_warn outputs to stderr'
            When call log_warn 'warning message'
            The stderr should include 'WARN'
            The stderr should include 'warning message'
        End

        It 'log_error outputs to stderr'
            When call log_error 'error message'
            The stderr should include 'ERROR'
            The stderr should include 'error message'
        End

        Context 'when VERBOSE is false'
            setup() { VERBOSE=false; }
            Before 'setup'

            It 'log_debug outputs nothing'
                When call log_debug 'debug message'
                The stderr should equal ''
            End
        End

        Context 'when VERBOSE is true'
            setup() { VERBOSE=true; }
            Before 'setup'

            It 'log_debug outputs to stderr'
                When call log_debug 'debug message'
                The stderr should include 'DEBUG'
                The stderr should include 'debug message'
            End
        End
    End

    Describe 'parse_arguments() - new options'
        setup() {
            # Reset all variables
            INSTALL_MODE=false
            UPGRADE_MODE=false
            KEEP_EXISTING=false
            OVERLAY_DEVICE=""
            LOCAL_MODE=false
            TARGET_USER=""
            TARGET_HOST=""
            HOSTNAME_OVERRIDE=""
        }
        Before 'setup'

        It 'parses --install flag'
            When call parse_arguments --install --local
            The variable INSTALL_MODE should equal "true"
        End

        It 'parses --overlay with device'
            When call parse_arguments --overlay /dev/sda3 --local
            The variable OVERLAY_DEVICE should equal "/dev/sda3"
        End

        It 'parses --overlay= format'
            When call parse_arguments --overlay=/dev/nvme0n1p3 --local
            The variable OVERLAY_DEVICE should equal "/dev/nvme0n1p3"
        End

        It 'parses upgrade command'
            When call parse_arguments upgrade --local
            The variable UPGRADE_MODE should equal "true"
        End

        It 'parses combined install options'
            When call parse_arguments --install --overlay /dev/sda3 --slot B --local
            The variable INSTALL_MODE should equal "true"
            The variable OVERLAY_DEVICE should equal "/dev/sda3"
            The variable TARGET_SLOT should equal "B"
        End

        It 'parses --hostname with value'
            When call parse_arguments --hostname exit-sg-sin1 --local
            The variable HOSTNAME_OVERRIDE should equal "exit-sg-sin1"
        End

        It 'parses --hostname= format'
            When call parse_arguments --hostname=exit-de-kas1 --local
            The variable HOSTNAME_OVERRIDE should equal "exit-de-kas1"
        End
    End

    Describe 'Default variables'
        It 'INSTALL_MODE defaults to false'
            The variable INSTALL_MODE should equal "false"
        End

        It 'UPGRADE_MODE defaults to false'
            The variable UPGRADE_MODE should equal "false"
        End

        It 'OVERLAY_DEVICE defaults to empty'
            The variable OVERLAY_DEVICE should equal ""
        End
    End

    Describe '--kernel-pkg / --verity parsing'
        It 'parses --kernel-pkg space form'
            When call parse_arguments --kernel-pkg linux-edge --install --local
            The variable KERNEL_PKG should equal "linux-edge"
        End

        It 'parses --kernel-pkg= form'
            When call parse_arguments --kernel-pkg=linux-lts --install --local
            The variable KERNEL_PKG should equal "linux-lts"
        End

        It 'parses --verity / --no-verity'
            When call parse_arguments --no-verity --install --local
            The variable VERITY_MODE should equal "off"
        End
    End

    Describe 'shell_quote()'
        # The contract: the output, when eval'd by a POSIX shell, must
        # reproduce the original value byte-for-byte (minus trailing newlines).
        roundtrip() {
            # shellcheck disable=SC2046
            eval "set -- $(shell_quote "$1")"
            printf '%s' "$1"
        }

        It 'preserves a plain value'
            When call roundtrip "hello-world"
            The output should equal "hello-world"
        End

        It 'neutralizes command substitution'
            When call roundtrip '$(touch /tmp/pwned)'
            The output should equal '$(touch /tmp/pwned)'
        End

        It 'neutralizes single quotes'
            When call roundtrip "it's a trap"
            The output should equal "it's a trap"
        End

        It 'neutralizes mixed metacharacters'
            When call roundtrip 'a"b;c|d&e`f$g'
            The output should equal 'a"b;c|d&e`f$g'
        End

        It 'neutralizes spaces and globs'
            When call roundtrip 'a b *.sh ?x'
            The output should equal 'a b *.sh ?x'
        End
    End

    Describe 'require() / try_warn()'
        It 'require succeeds silently on a passing command'
            When call require true
            The status should be success
        End

        It 'require aborts on a failing command'
            When run require false
            The status should be failure
            The stderr should include "command failed"
        End

        It 'try_warn returns the failing status but does not abort'
            When run try_warn false
            The status should be failure
            The stderr should include "non-fatal"
        End
    End

    Describe 'atomic_write() / sed_inplace_checked()'
        setup() { TESTDIR=$(mktemp -d); }
        cleanup_dir() { rm -rf "$TESTDIR"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'atomic_write replaces file content and leaves no temp file'
            write_it() { printf 'NEW\n' | atomic_write "$TESTDIR/f"; }
            When call write_it
            The status should be success
            The contents of file "$TESTDIR/f" should equal "NEW"
            The path "$TESTDIR/f.aatmp.$$" should not be exist
        End

        It 'sed_inplace_checked applies the edit when the expected state appears'
            do_edit() {
                printf 'kernel=vmlinuz-A\n' > "$TESTDIR/c"
                sed_inplace_checked "$TESTDIR/c" '^kernel=vmlinuz-B$' -e 's|^kernel=vmlinuz-[AB]$|kernel=vmlinuz-B|'
            }
            When call do_edit
            The status should be success
            The contents of file "$TESTDIR/c" should equal "kernel=vmlinuz-B"
        End

        It 'sed_inplace_checked aborts when the expected state never appears (no-op edit)'
            do_edit() {
                printf 'kernel=vmlinuz-A\n' > "$TESTDIR/c"
                sed_inplace_checked "$TESTDIR/c" '^kernel=vmlinuz-B$' -e 's|^nomatch$|x|'
            }
            When run do_edit
            The status should be failure
            The stderr should include "expected state"
            # Original file must be left untouched
            The contents of file "$TESTDIR/c" should equal "kernel=vmlinuz-A"
        End
    End
End
