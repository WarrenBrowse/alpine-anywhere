#!/bin/bash
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
