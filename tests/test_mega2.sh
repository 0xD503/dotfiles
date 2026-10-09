#!/bin/sh
#
# test_mega2.sh -- tests for MEGA 2.0 (.mega2.d).
#
# Everything runs in a sandbox: $HOME and the XDG directories point into a
# throwaway directory, so no test reads or writes your real Emacs state.
# Nothing uses the network.  There are four stages:
#
#   lint      byte-compile every file, with warnings as errors
#   unit      the ERT suite in tests/mega2/, run against the real init files
#   boot      start MEGA in batch and check what startup did: no failed
#             module, no program run, no connection, within the time budget
#   terminal  start it for real in a pseudo-terminal: directly, through
#             chemacs2 if you have it, and with a too-old Emacs if one exists
#
# Afterwards the configuration directory must be exactly as it was: MEGA
# never writes into it.
#
# usage: tests/test_mega2.sh [STAGE...]
#
#   STAGE              run only these stages (default: all four)
#
# environment:
#   EMACS              the Emacs under test                    (default: emacs)
#   EMACS_OLD          an Emacs older than MEGA supports, for the refusal
#                      test          (default: /usr/bin/emacs, if it is older)
#   MEGA_STARTUP_BUDGET_MS   startup budget for the boot stage  (default: 100)
#   MEGA_TEST_CONFIG   the configuration to test          (default: ../.mega2.d)
#
# Portability: POSIX sh.  The terminal stage needs script(1) from util-linux
# and is skipped without it.

set -u

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd) || exit 1
CONFIG=${MEGA_TEST_CONFIG:-$REPO/.mega2.d}
TESTS="$REPO/tests/mega2"
EMACS=${EMACS:-emacs}
BUDGET=${MEGA_STARTUP_BUDGET_MS:-100}
REAL_HOME=$HOME

if ! command -v "$EMACS" >/dev/null 2>&1; then
    printf '%s: no such Emacs: %s\n' "$0" "$EMACS" >&2
    exit 2
fi
if ! "$EMACS" -Q --batch --eval \
        '(kill-emacs (if (version< emacs-version "31.1") 1 0))' 2>/dev/null; then
    printf '%s: MEGA 2.0 needs Emacs 31.1 or newer; %s is %s\n' "$0" "$EMACS" \
        "$("$EMACS" --version | sed -n 1p)" >&2
    exit 2
fi

# mkdir, not mktemp: it is POSIX, and it fails rather than reuse a directory.
SANDBOX="${TMPDIR:-/tmp}/mega2-tests.$$"
(umask 077 && mkdir -- "$SANDBOX") || exit 1
SANDBOX=$(cd -- "$SANDBOX" && pwd -P) || exit 1
trap 'rm -rf -- "$SANDBOX"' EXIT
trap 'rm -rf -- "$SANDBOX"; exit 130' INT
trap 'rm -rf -- "$SANDBOX"; exit 143' TERM

mkdir -- "$SANDBOX/home" "$SANDBOX/tmp" "$SANDBOX/elc"
HOME="$SANDBOX/home"
XDG_CACHE_HOME="$SANDBOX/cache"
XDG_STATE_HOME="$SANDBOX/state"
XDG_DATA_HOME="$SANDBOX/data"
XDG_CONFIG_HOME="$SANDBOX/config"
TMPDIR="$SANDBOX/tmp"
MEGA_TEST_SANDBOX=$SANDBOX
MEGA_TEST_CONFIG=$CONFIG
export HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME TMPDIR
export MEGA_TEST_SANDBOX MEGA_TEST_CONFIG

failed=0
skipped=0

ok()   { printf 'ok    %s\n' "$*"; }
skip() { printf 'skip  %s\n' "$*"; skipped=$((skipped + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }

# Print stdin indented, as the detail under a FAIL line.
detail() { sed 's/^/      /'; }

# A fingerprint of every file in the configuration directory.
fingerprint() {
    (cd -- "$CONFIG" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s\n' "$(cksum < "$f")" "$f"
    done)
}

# --- lint -------------------------------------------------------------------

stage_lint() {
    for file in "$CONFIG"/early-init.el "$CONFIG"/init.el "$CONFIG"/lisp/*.el; do
        name=${file#"$CONFIG"/}
        # Compiled output goes to the sandbox, never next to the source.
        if out=$("$EMACS" -Q --batch -L "$CONFIG/lisp" --eval "
(setq byte-compile-error-on-warn t
      byte-compile-dest-file-function
      (lambda (source)
        (expand-file-name (concat (file-name-nondirectory source) \"c\")
                          \"$SANDBOX/elc\")))" \
                --eval "(unless (byte-compile-file \"$file\") (kill-emacs 1))" 2>&1)
        then
            ok "lint  $name"
        else
            bad "lint  $name"
            printf '%s\n' "$out" | grep -v '^$' | detail
        fi
    done
}

# --- unit -------------------------------------------------------------------

stage_unit() {
    set --
    for file in "$TESTS"/*-test.el; do
        set -- "$@" -l "$file"
    done
    if out=$("$EMACS" -Q --batch -L "$TESTS" -l mega-test-helper "$@" \
                -f ert-run-tests-batch-and-exit 2>&1); then
        ok "unit  $(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]* tests\), \([0-9]* results as expected\).*/\1, \2/p')"
    else
        bad "unit"
        # What failed and why.  Passing tests and backtraces are noise here.
        printf '%s\n' "$out" |
            awk '/^Test .* backtrace:$/ { skip = 1; next }
                 /^Test .* condition:$/ { skip = 0 }
                 !skip' |
            grep -v '^   passed' | cut -c1-400 | detail
    fi
}

# --- boot -------------------------------------------------------------------

stage_boot() {
    best=
    for run in 1 2 3; do
        out=$("$EMACS" -Q --batch -l "$TESTS/mega-boot-probe.el" 2>&1)
        rc=$?
        ms=$(printf '%s\n' "$out" | sed -n 's/^load-ms=//p')
        # The probe must say so itself.  A clean exit proves nothing: a probe
        # that never got as far as checking exits cleanly too.
        if [ "$rc" -ne 0 ] || [ -z "$ms" ] ||
            ! printf '%s\n' "$out" | grep -q '^verdict=ok$'; then
            bad "boot  (run $run, exit $rc)"
            printf '%s\n' "$out" | cut -c1-400 | detail
            return
        fi
        if [ -z "$best" ] || awk "BEGIN { exit !($ms < $best) }"; then
            best=$ms
        fi
    done
    ok "boot  no failed module, no program run, no connection opened"
    if awk "BEGIN { exit !($best <= $BUDGET) }"; then
        ok "boot  init files load in $best ms (budget $BUDGET ms, best of 3)"
    else
        bad "boot  init files load in $best ms, over the $BUDGET ms budget"
    fi
}

# --- terminal ---------------------------------------------------------------

# Start "$1" (an Emacs) in a 40x120 pseudo-terminal of type $2 that offers $3
# colours, expecting $4 ("supported" or "refused"); $5 is "chemacs" to go
# through the profile switcher instead of --init-directory.  The verdict is
# the probe's report.
terminal_run() {
    T_EMACS=$1 T_TERM=$2 MEGA_TEST_COLOURS=$3 T_EXPECT=$4 T_LAUNCHER=${5-}
    MEGA_TEST_REPORT="$SANDBOX/report"
    MEGA_TEST_EXPECT=$T_EXPECT
    MEGA_TEST_LAUNCHER=$T_LAUNCHER
    T_PROBE="$TESTS/mega-terminal-probe.el"
    export T_EMACS T_PROBE MEGA_TEST_REPORT MEGA_TEST_EXPECT MEGA_TEST_LAUNCHER
    export MEGA_TEST_COLOURS
    rm -f -- "$MEGA_TEST_REPORT"
    label="terminal  Emacs $("$T_EMACS" --version | sed -n '1s/^GNU Emacs //p'), TERM=$T_TERM${T_LAUNCHER:+, via $T_LAUNCHER}"

    # 24-bit colour is announced by COLORTERM, not by the terminal type.
    if [ "$MEGA_TEST_COLOURS" = 16777216 ]; then
        COLORTERM=truecolor; export COLORTERM
    else
        unset COLORTERM
    fi

    if [ "$T_LAUNCHER" = chemacs ]; then
        launch='exec "$T_EMACS" -nw -l "$T_PROBE"'
    else
        launch='exec "$T_EMACS" -nw --init-directory "$MEGA_TEST_CONFIG" -l "$T_PROBE"'
    fi
    printf '#!/bin/sh\nstty rows 40 cols 120\n%s\n' "$launch" > "$SANDBOX/launch.sh"

    # A session that never exits (a prompt, a hang) must fail, not block.
    limit=
    command -v timeout >/dev/null 2>&1 && limit='timeout 120'
    TERM=$T_TERM $limit \
        script -qec "sh '$SANDBOX/launch.sh'" /dev/null > /dev/null 2>&1 < /dev/null
    rc=$?

    if [ ! -f "$MEGA_TEST_REPORT" ]; then
        bad "$label: no report (exit $rc); Emacs did not finish starting"
    elif [ "$rc" -ne 0 ] || ! grep -q '^verdict=ok$' "$MEGA_TEST_REPORT"; then
        bad "$label"
        cut -c1-400 "$MEGA_TEST_REPORT" | detail
    else
        ok "$label: $T_EXPECT, $(sed -n 's/^colours=//p' "$MEGA_TEST_REPORT") colours, init $(sed -n 's/^init-ms=//p' "$MEGA_TEST_REPORT") ms"
    fi
}

stage_terminal() {
    if ! command -v script >/dev/null 2>&1; then
        skip "terminal  (script(1) is not installed)"
        return
    fi

    # Directly, in the two terminal types that matter: plain and under tmux.
    terminal_run "$EMACS" xterm-256color 16777216 supported
    if infocmp tmux-256color >/dev/null 2>&1; then
        terminal_run "$EMACS" tmux-256color 16777216 supported
    else
        skip "terminal  TERM=tmux-256color (no such terminal description)"
    fi

    # With fewer colours: 256 gets an approximated theme, 8 gets none.
    terminal_run "$EMACS" xterm-256color 256 supported
    terminal_run "$EMACS" xterm 8 supported

    # Through chemacs2, as the default profile.  A copy of the real one is
    # put in the sandbox home; its profile list points at this checkout.
    if [ -f "$REAL_HOME/.emacs.d/chemacs.el" ]; then
        mkdir -p -- "$HOME/.emacs.d"
        cp -- "$REAL_HOME/.emacs.d/chemacs.el" "$REAL_HOME/.emacs.d/init.el" \
            "$REAL_HOME/.emacs.d/early-init.el" "$HOME/.emacs.d/"
        printf '(("default" . ((user-emacs-directory . "%s"))))\n' "$CONFIG" \
            > "$HOME/.emacs-profiles.el"
        terminal_run "$EMACS" xterm-256color 16777216 supported chemacs
    else
        skip "terminal  via chemacs2 (not installed in ~/.emacs.d)"
    fi

    # An Emacs that is too old must be left plain and told why.
    old=${EMACS_OLD:-/usr/bin/emacs}
    if command -v "$old" >/dev/null 2>&1 &&
        "$old" -Q --batch --eval \
            '(kill-emacs (if (and (version< emacs-version "31.1") (not (version< emacs-version "29.1"))) 0 1))' 2>/dev/null
    then
        terminal_run "$old" xterm-256color 16777216 refused
    else
        skip "terminal  refusing an old Emacs (none found; set EMACS_OLD)"
    fi
}

# --- run --------------------------------------------------------------------

[ $# -gt 0 ] || set -- lint unit boot terminal

for stage do
    case $stage in
        lint | unit | boot | terminal) ;;
        *) printf '%s: unknown stage: %s\n' "$0" "$stage" >&2; exit 2 ;;
    esac
done

fingerprint > "$SANDBOX/config.before"

for stage do
    "stage_$stage"
done

fingerprint > "$SANDBOX/config.after"
if cmp -s "$SANDBOX/config.before" "$SANDBOX/config.after"; then
    ok "the configuration directory is exactly as it was"
else
    bad "the configuration directory was modified"
    diff "$SANDBOX/config.before" "$SANDBOX/config.after" | detail
fi

printf '\n%d failed, %d skipped  (%s)\n' "$failed" "$skipped" \
    "$("$EMACS" --version | sed -n 1p)"
[ "$failed" -eq 0 ]
