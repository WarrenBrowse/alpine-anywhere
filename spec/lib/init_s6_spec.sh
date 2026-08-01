#!/bin/sh
# init_s6_spec.sh - s6 init wiring (docker longrun wrapper, cgroup v2 mount).

Describe 's6 init'
    Include lib/common.sh
    Include lib/init_s6.sh

    Describe 'install_s6_docker_run()'
        setup() { HD=$(mktemp -d); }
        cleanup_dir() { rm -rf "$HD"; }
        BeforeEach 'setup'
        AfterEach 'cleanup_dir'

        It 'writes a valid POSIX sh wrapper'
            install_s6_docker_run "$HD"
            When call sh -n "$HD/docker-run"
            The status should be success
        End

        It 'waits for the aa-data ready marker before starting dockerd'
            install_s6_docker_run "$HD"
            When call cat "$HD/docker-run"
            The output should include "/run/aa-data-ready"
            The output should include "/var/lib/docker"
            The output should include "exec /usr/bin/dockerd --data-root=/var/lib/docker"
        End
    End

    Describe 'boot-time mounts'
        # Regression guard: dockerd cannot start without a cgroup hierarchy, and
        # only mounts-up provides one on the s6 path (OpenRC has its own service).
        It 'mounts-up provides cgroup v2'
            When call cat lib/init_s6.sh
            The output should include "mount -t cgroup2"
        End
    End
End
