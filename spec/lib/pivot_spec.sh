#!/bin/sh
# Tests for pivot.sh - Real pivot_root implementation

Describe 'pivot.sh'
    Include lib/common.sh
    Include lib/pivot.sh

    Describe 'detect_init_system()'
        # Note: This is difficult to test without mocking /proc/1/comm
        # We test the parsing logic instead

        It 'defines PIVOT_DIR constant'
            The variable PIVOT_DIR should equal "/mnt/alpine"
        End

        It 'defines OLD_ROOT constant'
            The variable OLD_ROOT should equal "/mnt/oldroot"
        End

        # Mock the PID 1 probes (cat /proc/1/comm, readlink -f /proc/1/exe).
        It 'detects s6 when PID 1 is s6-svscan'
            cat() { echo "s6-svscan"; }
            readlink() { echo "/bin/s6-svscan"; }
            When call detect_init_system
            The output should equal "s6"
        End

        It 'detects s6 when PID 1 is s6-linux-init'
            cat() { echo "s6-linux-init"; }
            readlink() { echo "/usr/bin/s6-linux-init"; }
            When call detect_init_system
            The output should equal "s6"
        End

        It 'still detects systemd'
            cat() { echo "systemd"; }
            readlink() { echo "/usr/lib/systemd/systemd"; }
            When call detect_init_system
            The output should equal "systemd"
        End
    End

    Describe 'Constants'
        It 'sets PIVOT_DIR to /mnt/alpine'
            The variable PIVOT_DIR should equal "/mnt/alpine"
        End

        It 'sets OLD_ROOT to /mnt/oldroot'
            The variable OLD_ROOT should equal "/mnt/oldroot"
        End
    End
End
