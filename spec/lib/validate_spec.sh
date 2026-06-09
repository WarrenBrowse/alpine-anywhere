#!/bin/sh
# validate_spec.sh - Tests for lib/validate.sh input sanitization

Describe 'validate.sh'
    Include lib/common.sh
    Include lib/validate.sh

    Describe 'assert_safe_token()'
        It 'accepts a plain hostname'
            When call assert_safe_token "hostname" "web-server-01"
            The status should be success
        End

        It 'accepts a mirror URL (slashes, colon, dots allowed)'
            When call assert_safe_token "mirror" "https://dl-cdn.alpinelinux.org/alpine"
            The status should be success
        End

        It 'accepts an empty value'
            When call assert_safe_token "optional" ""
            The status should be success
        End

        It 'rejects command substitution'
            When run assert_safe_token "hostname" '$(touch /tmp/pwned)'
            The status should be failure
            The stderr should include "unsafe characters"
        End

        It 'rejects a semicolon'
            When run assert_safe_token "hostname" 'a;reboot'
            The status should be failure
            The stderr should include "unsafe characters"
        End

        It 'rejects spaces'
            When run assert_safe_token "iface" 'eth0 evil'
            The status should be failure
            The stderr should include "unsafe characters"
        End

        It 'rejects single quotes (heredoc breakout)'
            When run assert_safe_token "hostname" "a'b"
            The status should be failure
            The stderr should include "unsafe characters"
        End

        It 'rejects backticks'
            When run assert_safe_token "hostname" 'a`id`'
            The status should be failure
            The stderr should include "unsafe characters"
        End
    End

    Describe 'validate_safe_inputs()'
        It 'rejects a non-numeric SSH port'
            BeforeRun 'SSH_PORT=22abc'
            When run validate_safe_inputs
            The status should be failure
            The stderr should include "numeric"
        End

        It 'rejects a target disk that is not a /dev path'
            BeforeRun 'TARGET_DISK=/etc/passwd; SSH_PORT=22'
            When run validate_safe_inputs
            The status should be failure
            The stderr should include "/dev path"
        End

        It 'passes with clean defaults'
            When call validate_safe_inputs
            The status should be success
        End
    End
End
