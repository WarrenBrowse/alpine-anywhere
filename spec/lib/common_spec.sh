#!/bin/bash
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
End
