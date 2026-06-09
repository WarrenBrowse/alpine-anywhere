#!/bin/sh
# ssh_spec.sh - Tests for lib/ssh.sh host-key trust + injection-safe exec

Describe 'ssh.sh'
    Include lib/common.sh
    Include lib/ssh.sh

    Describe '_ssh_hostkey_opts()'
        It 'uses accept-new (TOFU) when no known-hosts file is pinned'
            BeforeCall 'SSH_KNOWN_HOSTS='
            When call _ssh_hostkey_opts
            The output should include "StrictHostKeyChecking=accept-new"
        End

        It 'enforces strict checking against the pinned known_hosts file'
            BeforeCall 'SSH_KNOWN_HOSTS=/tmp/kh'
            When call _ssh_hostkey_opts
            The output should include "StrictHostKeyChecking=yes"
            The output should include "UserKnownHostsFile=/tmp/kh"
        End
    End

    Describe '_ssh_opts() / _scp_opts() consistency'
        It 'both honour the pinned known_hosts file'
            BeforeCall 'SSH_KNOWN_HOSTS=/tmp/kh; SSH_PORT=22'
            When call _ssh_opts
            The output should include "UserKnownHostsFile=/tmp/kh"
            The output should include "StrictHostKeyChecking=yes"
        End

        It 'scp opts also honour the pin'
            BeforeCall 'SSH_KNOWN_HOSTS=/tmp/kh; SSH_PORT=22'
            When call _scp_opts
            The output should include "UserKnownHostsFile=/tmp/kh"
        End
    End

    Describe 'ssh_exec_script()'
        # Injection safety: data passed as positional args must not be eval'd by
        # the local shell. We stub ssh to echo the remote arg string so we can
        # inspect how the payload was quoted.
        It 'passes data as inert single-quoted positional args (dry-run)'
            BeforeCall 'DRY_RUN=true; TARGET_USER=root; TARGET_HOST=h; SSH_PORT=22'
            When call ssh_exec_script 'echo "$1"' '$(reboot)'
            The output should include "sh -s --"
            # the payload appears single-quoted, never as a bare $(...)
            The output should include "'\$(reboot)'"
            The stderr should be defined
        End
    End
End
