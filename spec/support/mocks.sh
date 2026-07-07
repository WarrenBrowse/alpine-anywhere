#!/bin/sh
# mocks.sh - Test helpers for alpine-anywhere

# Create an executable mock binary named NAME in $MOCK_BIN_DIR running SCRIPT.
# $MOCK_BIN_DIR must be created and prepended to PATH by the caller.
# Usage: make_mock_bin reboot 'echo "reboot $*" >> "$MOCK_LOG"'
make_mock_bin() {
    _mb_name="$1"; _mb_body="$2"
    : "${MOCK_BIN_DIR:?MOCK_BIN_DIR must be set}"
    mkdir -p "$MOCK_BIN_DIR"
    {
        echo '#!/bin/sh'
        echo "$_mb_body"
    } > "${MOCK_BIN_DIR}/${_mb_name}"
    chmod +x "${MOCK_BIN_DIR}/${_mb_name}"
}
