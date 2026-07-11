#!/bin/sh
# verity_sign_spec.sh - producer side of signature-authenticated dm-verity.
# Exercises verity_sig_for_hash (offline injection + inline signing + fail-closed
# verification) and the verity_assert_sig_or_die build guard, with minisign
# mocked (base64 is real, so the encode round-trips through aa-verity-open).

# shellspec `satisfy` pipes the subject on stdin (not as an argument).
is_single_line() {
    [ "$(wc -l | tr -d ' ')" = "0" ]
}

# The base64 stored in slots.meta must decode back byte-for-byte to the original
# detached minisig, so aa-verity-open reconstructs exactly what was signed. The
# subject (base64) arrives on stdin; $1 is the original minisig to compare to.
decodes_back() {
    _db_orig="$1"
    _db_tmp=$(mktemp)
    base64 -d > "$_db_tmp" 2>/dev/null || { rm -f "$_db_tmp"; return 1; }
    if cmp -s "$_db_orig" "$_db_tmp"; then rm -f "$_db_tmp"; return 0; fi
    rm -f "$_db_tmp"; return 1
}

Describe 'verity signing (common.sh)'
    Include lib/common.sh

    setup() {
        WORKD=$(mktemp -d)
        MOCK_BIN_DIR=$(mktemp -d)
        PATH="${MOCK_BIN_DIR}:$PATH"
        export MOCK_BIN_DIR
        # minisign mock: -S writes a fake 4-line minisig next to the message;
        # -V exits per MINISIGN_VERIFY_EXIT (default success).
        make_mock_bin minisign '
mode=""; for a in "$@"; do case "$a" in -S*) mode=S ;; -V*) mode=V ;; esac; done
if [ "$mode" = S ]; then
    f=""; prev=""
    for a in "$@"; do case "$prev" in -Sm|-m) f="$a" ;; esac; prev="$a"; done
    [ -n "$f" ] && printf "untrusted comment: x\nRWQfakesig\ntrusted comment: t\nRWQglobal\n" > "${f}.minisig"
    exit 0
fi
if [ "$mode" = V ]; then exit "${MINISIGN_VERIFY_EXIT:-0}"; fi
exit 0'
        # Clean slate: no signing/pubkey unless a test sets it.
        VERITY_SIG=""; VERITY_SIGN_KEY=""; VERITY_PUBKEY=""
    }
    cleanup() { rm -rf "$WORKD" "$MOCK_BIN_DIR"; }
    Before 'setup'
    After 'cleanup'

    Describe 'verity_sig_for_hash()'
        It 'produces nothing when signing is not configured'
            When call verity_sig_for_hash deadbeef
            The status should be success
            The output should equal ''
        End

        It 'produces nothing for an empty root hash'
            VERITY_SIG="${WORKD}/rh.minisig"
            printf 'untrusted comment: x\nRWQsig\n' > "$VERITY_SIG"
            When call verity_sig_for_hash ''
            The status should be success
            The output should equal ''
        End

        It 'base64-encodes an injected offline signature to a single line'
            VERITY_SIG="${WORKD}/rh.minisig"
            printf 'untrusted comment: x\nRWQsig\ntrusted comment: t\nRWQglobal\n' > "$VERITY_SIG"
            When call verity_sig_for_hash deadbeef
            The status should be success
            # Single line (slots.meta is line-based) and decodes back to the minisig.
            The output should satisfy is_single_line
            The output should satisfy decodes_back "$VERITY_SIG"
        End

        It 'signs inline with a dev key when VERITY_SIGN_KEY is set'
            VERITY_SIGN_KEY="${WORKD}/dev.key"
            printf 'RWQfakeseckey\n' > "$VERITY_SIGN_KEY"
            When call verity_sig_for_hash deadbeef
            The status should be success
            The output should not equal ''
        End

        It 'fails closed when the signature does not verify against the pubkey'
            VERITY_SIG="${WORKD}/rh.minisig"
            printf 'untrusted comment: x\nRWQsig\n' > "$VERITY_SIG"
            VERITY_PUBKEY="${WORKD}/verity.pub"
            printf 'untrusted comment: pk\nRWQpub\n' > "$VERITY_PUBKEY"
            export MINISIGN_VERIFY_EXIT=1
            When run verity_sig_for_hash deadbeef
            The status should be failure
            The stderr should be defined
        End

        It 'accepts an injected signature that verifies against the pubkey'
            VERITY_SIG="${WORKD}/rh.minisig"
            printf 'untrusted comment: x\nRWQsig\ntrusted comment: t\nRWQglobal\n' > "$VERITY_SIG"
            VERITY_PUBKEY="${WORKD}/verity.pub"
            printf 'untrusted comment: pk\nRWQpub\n' > "$VERITY_PUBKEY"
            export MINISIGN_VERIFY_EXIT=0
            When call verity_sig_for_hash deadbeef
            The status should be success
            The output should not equal ''
        End
    End

    Describe 'verity_assert_sig_or_die()'
        It 'passes when no pubkey is configured (plain verity)'
            When run verity_assert_sig_or_die ''
            The status should be success
        End

        It 'dies when a pubkey is embedded but no signature was produced'
            VERITY_PUBKEY="${WORKD}/verity.pub"
            printf 'untrusted comment: pk\nRWQpub\n' > "$VERITY_PUBKEY"
            When run verity_assert_sig_or_die ''
            The status should be failure
            The stderr should be defined
        End

        It 'passes when a pubkey is embedded and a signature is present'
            VERITY_PUBKEY="${WORKD}/verity.pub"
            printf 'untrusted comment: pk\nRWQpub\n' > "$VERITY_PUBKEY"
            When run verity_assert_sig_or_die 'c29tZXNpZw=='
            The status should be success
        End
    End
End
