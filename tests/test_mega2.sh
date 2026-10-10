#!/bin/sh
#
# test_mega2.sh -- tests for MEGA 2.0 (.mega2.d).
#
# Everything runs in a sandbox: $HOME and the XDG directories point into a
# throwaway directory, so no test reads or writes your real Emacs state.
# Nothing uses the network.  There are five stages, and a sixth that runs
# only when it is asked for by name:
#
#   lint      byte-compile every file, with warnings as errors
#   unit      the ERT suite in tests/mega2/, run against the real init files
#   boot      start MEGA in batch and check what startup did: no failed
#             module, no program run, no connection, within the time budget
#   bench     time what a person waits for (a keystroke, the completion
#             menu, a search, a save...) against what each is expected to
#             take; every time is printed, so a slowdown shows before it
#             fails.  The expected times, and the commit and reason behind
#             each, are in tests/mega2/mega-bench-history.eld, which also
#             says what to do when one is exceeded.
#   terminal  start it for real in a pseudo-terminal: directly, through
#             chemacs2 if you have it, and with a too-old Emacs if one exists
#
#   container start a real container with podman and use it: run, build and
#             debug in it.  Needs MEGA_REAL_IMAGE; makes one container, with
#             no network, and removes it.  See mega-container-probe.el.
#
# Afterwards the configuration directory must be exactly as it was: MEGA
# never writes into it.
#
# usage: tests/test_mega2.sh [STAGE...]
#
#   STAGE              run only these stages (default: the first five)
#
# environment:
#   EMACS              the Emacs under test                    (default: emacs)
#   EMACS_OLD          an Emacs older than MEGA supports, for the refusal
#                      test          (default: /usr/bin/emacs, if it is older)
#   MEGA_STARTUP_BUDGET_MS   startup budget for the boot stage  (default: 100)
#   MEGA_BENCH_ONLY    a regexp: time only the benchmarks whose names match
#   MEGA_BENCH_SCALE   multiply what the bench stage expects, for a
#                      slower machine                            (default: 1)
#   MEGA_BENCH_TOLERANCE  how many times the expected time fails  (default: 3)
#   MEGA_BENCH_SAVE    write the times of the bench stage to this file
#   MEGA_BENCH_COMPARE compare them with a file written that way as well,
#                      and fail on anything MEGA_BENCH_TOLERANCE times
#                      slower than it was                         (default: 2)
#   MEGA_REAL_IMAGE    for the container stage: an image that is on this
#                      machine already and holds a C compiler; gdb or lldb
#                      as well, for the debugger part.  Never downloaded.
#   MEGA_TEST_CONFIG   the configuration to test          (default: ../.mega2.d)
#   MEGA_TEST_ONLY     a regexp: run only the unit tests whose names match
#   MEGA_TEST_UNIT_SECONDS  how long the unit stage may take  (default: 300)
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

# What a program of yours needs to find its own files.  Kept for the one
# stage that runs one, the container stage; everything else never sees it.
export -p | grep -E '^(export|declare -x) (HOME|XDG_[A-Z_]+|TMPDIR)=' \
    > "$SANDBOX/real-environment"

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

# --- the compiled copy ------------------------------------------------------

# MEGA's Lisp runs as source the first time and from a compiled copy after
# that, so unit, boot and terminal look at both.  This makes the copy, once,
# the way a session makes it: with another Emacs, told where to put it.  It
# ends up under $SANDBOX/compiled/cache, to be used as, or copied to, a
# cache directory.
compiled_cache() {
    [ ! -f "$SANDBOX/compiled/made" ] || return 0
    mkdir -p -- "$SANDBOX/compiled" || return 1
    MEGA_TEST_TARGET=$(XDG_CACHE_HOME="$SANDBOX/compiled/cache" "$EMACS" -Q --batch \
        -l "$CONFIG/early-init.el" --eval '(princ mega-compiled-dir)' 2>/dev/null) || return 1
    MEGA_TEST_TARGET=$MEGA_TEST_TARGET MEGA_SOURCE=1 \
        XDG_CACHE_HOME="$SANDBOX/compiled/scratch/cache" \
        XDG_STATE_HOME="$SANDBOX/compiled/scratch/state" \
        XDG_DATA_HOME="$SANDBOX/compiled/scratch/data" \
        "$EMACS" -Q --batch -l "$CONFIG/early-init.el" --eval \
        '(progn (require (quote mega-compile))
                (mega-compile-batch (directory-file-name (getenv "MEGA_TEST_TARGET"))))' \
        > "$SANDBOX/compiled/log" 2>&1 || return 1
    : > "$SANDBOX/compiled/made"
}

# --- unit -------------------------------------------------------------------

# Run the ERT suite once.  $1 is the form of MEGA's Lisp this pass is about,
# "source" or "compiled"; the directories it runs in are the caller's.
unit_pass() {
    form=$1
    set --
    for file in "$TESTS"/*-test.el; do
        set -- "$@" -l "$file"
    done
    # No input: a test that asks a question nobody stubbed must fail at
    # once, not wait for an answer.  And a limit on the whole stage: a test
    # that waits for something that never comes must not wait for ever.
    limit=${MEGA_TEST_UNIT_SECONDS:-300}
    if command -v timeout >/dev/null 2>&1; then
        set -- timeout --signal=KILL "$limit" "$EMACS" -Q --batch -L "$TESTS" \
            -l mega-test-helper "$@"
    else
        set -- "$EMACS" -Q --batch -L "$TESTS" -l mega-test-helper "$@"
    fi
    # Before that limit, Emacs is asked to say where it is waiting.
    watchdog=
    [ "$limit" -le 20 ] || watchdog=$((limit - 10))
    # MEGA_TEST_ONLY, a regexp, runs the tests whose names match it.
    out=$(MEGA_TEST_ONLY=${MEGA_TEST_ONLY-} MEGA_TEST_WATCHDOG=$watchdog \
          MEGA_TEST_FORM=$form "$@" --eval \
        '(ert-run-tests-batch-and-exit
          (let ((only (getenv "MEGA_TEST_ONLY")))
            (if (member only (list nil "")) t only)))' 2>&1 < /dev/null)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "unit  $form: $(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]* tests\), \([0-9]* results as expected\).*/\1, \2/p')"
        # A test that did not run is not a test that passed: say which.
        printf '%s\n' "$out" | sed -n 's/^ *SKIPPED *\([^ ]*\).*/skipped: \1/p' | sort -u | detail
    else
        bad "unit  $form"
        # A batch Emacs can end without a word: an error in a process
        # sentinel does it, and so does writing to a program that has
        # closed its input (signal 13).  Say so, and where it got to.
        if ! printf '%s\n' "$out" | grep -q '^Ran [0-9]* tests'; then
            last=$(printf '%s\n' "$out" |
                sed -n 's/^ *passed *[0-9]*\/[0-9]* *\([^ ]*\).*/\1/p' | tail -n 1)
            how="exit $rc"
            [ "$rc" -le 128 ] || how="killed by signal $((rc - 128))"
            [ "$rc" -ne 137 ] || how="stopped after $limit seconds: a test hangs"
            [ "$rc" -ne 124 ] || how="a test waited too long: see where, below"
            printf 'Emacs ended before the tests did (%s); the last test to pass was %s\n' \
                "$how" "${last:-none}" | detail
        fi
        # What failed and why.  Passing tests and backtraces are noise here.
        printf '%s\n' "$out" |
            awk '/^Test .* backtrace:$/ { skip = 1; next }
                 /^Test .* condition:$/ { skip = 0 }
                 !skip' |
            grep -v '^   passed' | cut -c1-400 | detail
    fi
}

stage_unit() {
    unit_pass source
    # The same tests again, on what every start after the first runs: in
    # directories of their own, as a session would have them, with the
    # compiled copy in its cache.
    if compiled_cache; then
        mkdir -p -- "$SANDBOX/unit2"
        cp -R -- "$SANDBOX/compiled/cache" "$SANDBOX/unit2/cache"
        (
            XDG_CACHE_HOME="$SANDBOX/unit2/cache"
            XDG_STATE_HOME="$SANDBOX/unit2/state"
            XDG_DATA_HOME="$SANDBOX/unit2/data"
            export XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME
            unit_pass compiled
            exit "$failed"
        )
        failed=$?
    else
        bad "unit  compiled: MEGA's Lisp did not compile"
        cut -c1-400 "$SANDBOX/compiled/log" | tail -n 20 | detail
    fi
}

# --- boot -------------------------------------------------------------------

# Start MEGA in batch three times and keep the best.  $1 is "source" or
# "compiled"; sets boot_ms, boot_how.  Fails the stage, and returns 1, if a
# start did anything it must not.
boot_pass() {
    form=$1
    best=
    for run in 1 2 3; do
        out=$(MEGA_TEST_FORM=$form "$EMACS" -Q --batch -l "$TESTS/mega-boot-probe.el" 2>&1)
        rc=$?
        ms=$(printf '%s\n' "$out" | sed -n 's/^load-ms=//p')
        after=$(printf '%s\n' "$out" | sed -n 's/^after-ms=//p')
        # The probe must say so itself.  A clean exit proves nothing: a probe
        # that never got as far as checking exits cleanly too.
        if [ "$rc" -ne 0 ] || [ -z "$ms" ] || [ -z "$after" ] ||
            ! printf '%s\n' "$out" | grep -q '^verdict=ok$'; then
            bad "boot  $form (run $run, exit $rc)"
            printf '%s\n' "$out" | cut -c1-400 | detail
            return 1
        fi
        # What is waited for is both: the init files, and what they put off
        # until Emacs has started.
        total=$(LC_ALL=C awk "BEGIN { printf \"%.1f\", $ms + $after }")
        if [ -z "$best" ] || awk "BEGIN { exit !($total < $best) }"; then
            best=$total best_load=$ms best_after=$after
        fi
    done
    boot_ms=$best
    boot_how="$best_load ms for the init files, $best_after ms for what they put off"
}

stage_boot() {
    boot_pass source || return
    ok "boot  no failed module, no program run, no connection opened"
    if awk "BEGIN { exit !($boot_ms <= $BUDGET) }"; then
        ok "boot  from source, MEGA starts in $boot_ms ms: $boot_how (budget $BUDGET ms, best of 3)"
    else
        bad "boot  from source, MEGA starts in $boot_ms ms, over the $BUDGET ms budget: $boot_how"
    fi
    # And as every start after the first is: from the compiled copy.
    if ! compiled_cache; then
        bad "boot  compiled: MEGA's Lisp did not compile"
        cut -c1-400 "$SANDBOX/compiled/log" | tail -n 20 | detail
        return
    fi
    mkdir -p -- "$SANDBOX/boot2"
    cp -R -- "$SANDBOX/compiled/cache" "$SANDBOX/boot2/cache"
    if (
        XDG_CACHE_HOME="$SANDBOX/boot2/cache"
        XDG_STATE_HOME="$SANDBOX/boot2/state"
        XDG_DATA_HOME="$SANDBOX/boot2/data"
        export XDG_CACHE_HOME XDG_STATE_HOME XDG_DATA_HOME
        boot_pass compiled || exit 1
        printf '%s\n%s\n' "$boot_ms" "$boot_how" > "$SANDBOX/boot2/result"
    ); then
        boot_ms=$(sed -n 1p "$SANDBOX/boot2/result")
        boot_how=$(sed -n 2p "$SANDBOX/boot2/result")
        if awk "BEGIN { exit !($boot_ms <= $BUDGET) }"; then
            ok "boot  from its compiled copy, in $boot_ms ms: $boot_how"
        else
            bad "boot  from its compiled copy, in $boot_ms ms, over the $BUDGET ms budget: $boot_how"
        fi
    else
        # The subshell said what was wrong; its count of failures is lost.
        failed=$((failed + 1))
    fi
}

# --- bench ------------------------------------------------------------------

stage_bench() {
    tab=$(printf '\t')
    out=$("$EMACS" -Q --batch -L "$TESTS" -l mega-test-helper \
              -l "$TESTS/mega-bench.el" -f mega-bench-run 2> "$SANDBOX/bench.err")
    rc=$?
    measured=0
    # A here-document, not a pipe: the loop must run in this shell to count.
    while IFS=$tab read -r verdict text; do
        case $verdict in
            ok)   ok "bench  $text"; measured=$((measured + 1)) ;;
            slow) printf 'SLOW  bench  %s\n' "$text"
                  measured=$((measured + 1)); slow=$((slow + 1)) ;;
            bad)  bad "bench  $text"; measured=$((measured + 1)) ;;
            note) printf '      %s\n' "$text" ;;
        esac
    done <<BENCH_RESULTS
$out
BENCH_RESULTS
    if [ "$measured" -eq 0 ]; then
        bad "bench  nothing was measured (exit $rc)"
        cut -c1-400 "$SANDBOX/bench.err" | tail -n 20 | detail
    fi
}
slow=0

# --- terminal ---------------------------------------------------------------

# Start "$1" (an Emacs) in a 40x120 pseudo-terminal of type $2 that offers $3
# colours, expecting $4 ("supported" or "refused"); $5 is "chemacs" to go
# through the profile switcher instead of --init-directory.  The verdict is
# the probe's report.
terminal_run() {
    T_EMACS=$1 T_TERM=$2 MEGA_TEST_COLOURS=$3 T_EXPECT=$4 T_LAUNCHER=${5-}
    # MEGA_TEST_FORM, when set by the caller: "make" for a session that is to
    # make the compiled copy of MEGA's Lisp, "compiled" for one that is to
    # run from it, "native-wait" and "native" for what Emacs makes of that.
    # Otherwise the session runs the source and makes nothing.
    MEGA_TEST_FORM=${MEGA_TEST_FORM-}
    export MEGA_TEST_FORM
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

    # MEGA_TEST_FILE, when set by the caller, is a file to start Emacs on.
    MEGA_TEST_FILE=${MEGA_TEST_FILE-}
    export MEGA_TEST_FILE
    [ -z "$MEGA_TEST_FILE" ] || label="$label, given a file"
    case $MEGA_TEST_FORM in
        make)        label="$label, making its compiled copy" ;;
        compiled)    label="$label, from the compiled copy" ;;
        native-wait) label="$label, while Emacs compiles that to native code" ;;
        native)      label="$label, as native code" ;;
    esac
    if [ "$T_LAUNCHER" = chemacs ]; then
        launch='exec "$T_EMACS" -nw -l "$T_PROBE" ${MEGA_TEST_FILE:+"$MEGA_TEST_FILE"}'
    else
        launch='exec "$T_EMACS" -nw --init-directory "$MEGA_TEST_CONFIG" -l "$T_PROBE" ${MEGA_TEST_FILE:+"$MEGA_TEST_FILE"}'
    fi
    printf '#!/bin/sh\nstty rows 40 cols 120\n%s\n' "$launch" > "$SANDBOX/launch.sh"

    # A session that never exits (a prompt, a hang) must fail, not block.
    limit=
    command -v timeout >/dev/null 2>&1 && limit="timeout ${T_LIMIT:-120}"
    # What the terminal was sent is kept: it is the only proof that a popup
    # was really drawn, not merely created.  The probe completes "megapr" and
    # takes megaprobealpha; "bebeta" is the tail of the candidate it did not
    # take, so it can only have come from the menu.  (The start of each
    # candidate is drawn in another colour, which splits it on the wire.)
    TERM=$T_TERM $limit \
        script -qec "sh '$SANDBOX/launch.sh'" "$SANDBOX/screen" > /dev/null 2>&1 < /dev/null
    rc=$?
    if [ "$T_EXPECT" = supported ] && [ -f "$MEGA_TEST_REPORT" ] &&
        ! grep -q 'bebeta' "$SANDBOX/screen"; then
        printf 'problem: the completion menu was never drawn on the terminal\n' \
            >> "$MEGA_TEST_REPORT"
        rc=1
    fi

    # Likewise the undo tree: three changes draw as four states in a row,
    # with box-drawing lines where the terminal has them.
    if [ "$T_EXPECT" = supported ] && [ -f "$MEGA_TEST_REPORT" ] &&
        ! grep -q -e 'o──o──o' -e 'o--o--o' "$SANDBOX/screen"; then
        printf 'problem: the undo tree was never drawn on the terminal\n' \
            >> "$MEGA_TEST_REPORT"
        rc=1
    fi

    if [ ! -f "$MEGA_TEST_REPORT" ]; then
        bad "$label: no report (exit $rc); Emacs did not finish starting"
    elif [ "$rc" -ne 0 ] || ! grep -q '^verdict=ok$' "$MEGA_TEST_REPORT" ||
        grep -q '^problem:' "$MEGA_TEST_REPORT"; then
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

    # Started on a file: the file is shown, the home page stays away.
    printf 'given on the command line\n' > "$SANDBOX/given.txt"
    MEGA_TEST_FILE="$SANDBOX/given.txt"
    terminal_run "$EMACS" xterm-256color 16777216 supported
    MEGA_TEST_FILE=

    # What you do after an update, in two starts.  The first finds no
    # compiled copy of MEGA's Lisp, runs the source, and makes one while it
    # sits idle; the second runs from what the first left.  With a cache
    # directory of their own, so that no other run finds a copy.
    (
        XDG_CACHE_HOME="$SANDBOX/twice/cache"
        export XDG_CACHE_HOME
        MEGA_TEST_FORM=make
        terminal_run "$EMACS" xterm-256color 16777216 supported
        MEGA_TEST_FORM=compiled
        terminal_run "$EMACS" xterm-256color 16777216 supported
        # From there Emacs goes on by itself: what it loads compiled, it
        # compiles to native code in the background.  One start is given
        # the time for that; the one after must be native from the first
        # moment, and everything the probe tries then runs as native code.
        if "$EMACS" -Q --batch --eval \
            '(kill-emacs (if (and (fboundp (quote native-comp-available-p))
                                  (native-comp-available-p)) 0 1))' 2>/dev/null; then
            MEGA_TEST_FORM=native-wait
            T_LIMIT=400 terminal_run "$EMACS" xterm-256color 16777216 supported
            MEGA_TEST_FORM=native
            terminal_run "$EMACS" xterm-256color 16777216 supported
        else
            skip "terminal  as native code (this Emacs cannot compile to it)"
        fi
        exit "$failed"
    )
    failed=$?
    MEGA_TEST_FORM=

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

# --- container (only when asked for) ----------------------------------------

# MEGA against a real container program and real debuggers, where the unit
# tests have stand-ins: tests/mega2/mega-container-probe.el says what and why.
stage_container() {
    image=${MEGA_REAL_IMAGE-}
    if [ -z "$image" ]; then
        skip "container  set MEGA_REAL_IMAGE to an image on this machine that holds a C compiler"
        return
    fi
    if ! engine=$(command -v podman 2>/dev/null); then
        skip "container  podman is not installed"
        return
    fi
    # The Emacs under test keeps its sandbox.  podman is given back your own
    # home and settings, which is where its images are.
    mkdir -p -- "$SANDBOX/bin" "$SANDBOX/probe"
    {
        printf '#!/bin/sh\n'
        printf 'unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME TMPDIR\n'
        printf '. "%s"\n' "$SANDBOX/real-environment"
        printf 'exec "%s" "$@"\n' "$engine"
    } > "$SANDBOX/bin/podman"
    chmod +x "$SANDBOX/bin/podman"
    # A tripwire: this stage plays a person, and a person can be talked into
    # a download.  A git that would fetch something is refused and noted.
    if realgit=$(command -v git 2>/dev/null); then
        {
            printf '#!/bin/sh\n'
            printf 'for word do\n'
            printf '    case $word in\n'
            printf '        clone | fetch | pull | submodule | ls-remote)\n'
            printf '            printf "git %%s\\n" "$*" >> "%s"\n' "$SANDBOX/fetch-attempts"
            printf '            exit 1 ;;\n'
            printf '    esac\n'
            printf 'done\n'
            printf 'exec "%s" "$@"\n' "$realgit"
        } > "$SANDBOX/bin/git"
        chmod +x "$SANDBOX/bin/git"
    fi
    # Nothing is downloaded: the image is here already, or the stage stops.
    if ! "$SANDBOX/bin/podman" image exists "$image" 2>/dev/null; then
        bad "container  no image called $image on this machine (none is ever fetched)"
        return
    fi
    limit=${MEGA_TEST_CONTAINER_SECONDS:-600}
    set -- "$EMACS" -Q --batch -L "$TESTS" -l "$TESTS/mega-container-probe.el" \
        -f mega-container-probe-run
    if command -v timeout >/dev/null 2>&1; then
        set -- timeout --signal=KILL "$limit" "$@"
    fi
    out=$(PATH="$SANDBOX/bin:$PATH" MEGA_PROBE_PROJECT="$SANDBOX/probe" \
              MEGA_REAL_IMAGE="$image" "$@" 2> "$SANDBOX/container.err" < /dev/null)
    rc=$?
    # Whatever happened in there: the container this stage made is removed,
    # found by the folder it is labelled with.  No other is looked at.
    for id in $("$SANDBOX/bin/podman" ps -a --format '{{.ID}}' \
                    --filter "label=devcontainer.local_folder=$SANDBOX/probe" 2>/dev/null); do
        "$SANDBOX/bin/podman" rm -f "$id" >/dev/null 2>&1
    done
    tab=$(printf '\t')
    checked=0
    while IFS=$tab read -r verdict text; do
        case $verdict in
            ok)   ok "container  $text"; checked=$((checked + 1)) ;;
            bad)  bad "container  $text"; checked=$((checked + 1)) ;;
            skip) skip "container  $text" ;;
            note) printf '      %s\n' "$text" ;;
        esac
    done <<CONTAINER_RESULTS
$out
CONTAINER_RESULTS
    if [ "$checked" -eq 0 ] || { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; }; then
        bad "container  the probe did not finish (exit $rc)"
        cut -c1-400 "$SANDBOX/container.err" | tail -n 20 | detail
    fi
    if [ -s "$SANDBOX/fetch-attempts" ]; then
        bad "container  something tried to download, and was stopped"
        cut -c1-400 "$SANDBOX/fetch-attempts" | detail
    else
        ok "container  nothing tried to download anything"
    fi
}

# --- run --------------------------------------------------------------------

[ $# -gt 0 ] || set -- lint unit boot bench terminal

for stage do
    case $stage in
        lint | unit | boot | bench | terminal | container) ;;
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

[ "$slow" -eq 0 ] ||
    printf '\n%d slower than expected: not a failure yet, and worth a look\n' "$slow"
printf '\n%d failed, %d skipped  (%s)\n' "$failed" "$skipped" \
    "$("$EMACS" --version | sed -n 1p)"
[ "$failed" -eq 0 ]
