#!/bin/sh
#
# test_update.sh -- tests for update.sh.
#
# Each test runs in a sandbox of its own: a throwaway repo that holds a copy of
# update.sh next to a few fake dotfiles, and a throwaway $HOME. Nothing reads
# or writes the real repo or the real $HOME. Nothing uses the network either:
# what `install` fetches is cloned from a local stand-in for it.
#
# usage: tests/test_update.sh [NAME...]
#
#   NAME               run only the tests whose name contains NAME
#
# environment:
#   UPDATE_SH          the script to test             (default: ../update.sh)
#   UPDATE_SH_SHELL    the shell that runs it, with any arguments it needs,
#                      e.g. 'busybox sh' or 'bash --posix'    (default: sh)
#
# A test is any function named test_*; writing one is all it takes to run it.
#
# Portability: POSIX sh only, like the script under test.

set -u

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1
UPDATE_SH=${UPDATE_SH:-$TESTS_DIR/../update.sh}
UPDATE_SH_SHELL=${UPDATE_SH_SHELL:-sh}

if [ ! -f "$UPDATE_SH" ]; then
    printf '%s: no such script: %s\n' "$0" "$UPDATE_SH" >&2
    exit 2
fi

# The per-machine files, as update.sh names them in HAND_COPY_FILES.
HAND_COPY=".bashrc.local .zshrc.local .gitconfig.local .gitconfig.signing"

# Where update.sh clones Oh my tmux! from. Read from the script, so that the
# `tmux` tests redirect the very URL it uses. The same for chemacs2 and for
# MEGA 2.0.
OMT_URL=$(sed -n 's/^OMT_URL="\(.*\)"$/\1/p' "$UPDATE_SH")
CHEMACS_URL=$(sed -n 's/^CHEMACS_URL="\(.*\)"$/\1/p' "$UPDATE_SH")
MEGA2_URL=$(sed -n 's/^MEGA2_URL="\(.*\)"$/\1/p' "$UPDATE_SH")

# mkdir, not mktemp: it is POSIX, and it fails rather than reuse a directory.
TEST_TMP="${TMPDIR:-/tmp}/update-sh-tests.$$"
(umask 077 && mkdir -- "$TEST_TMP") || exit 1
# Resolved, so that the paths update.sh prints are the ones compared against.
TEST_TMP=$(cd -- "$TEST_TMP" && pwd -P) || exit 1
trap 'rm -rf -- "$TEST_TMP"' EXIT
trap 'rm -rf -- "$TEST_TMP"; exit 130' INT
trap 'rm -rf -- "$TEST_TMP"; exit 143' TERM

# Keep the user's git configuration, and any repo the sandbox happens to sit
# inside, out of the tests.
LC_ALL=C
GIT_CONFIG_NOSYSTEM=1
GIT_CEILING_DIRECTORIES=$TEST_TMP
export LC_ALL GIT_CONFIG_NOSYSTEM GIT_CEILING_DIRECTORIES
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE
# update.sh clears old lists of its own away under the state directory, and
# what MEGA built under the cache directory: both must be the sandbox's, not
# yours.
unset XDG_STATE_HOME XDG_CACHE_HOME

# --- harness ----------------------------------------------------------------

# End the current test. Every test runs in a subshell, so `exit` stops only it.
fail() {
    printf '%s\n' "$*"
    exit 1
}

skip() {
    printf '%s\n' "$*"
    exit 77
}

need_git() {
    command -v git >/dev/null 2>&1 || skip "git is not installed"
}

# Write the single line $2 to the file $1, creating its directory.
put() {
    if ! mkdir -p -- "$(dirname -- "$1")" || ! printf '%s\n' "$2" > "$1"; then
        fail "cannot write: $1"
    fi
}

# Make the index of the sandbox repo match its working tree. Without git the
# repo stays a plain directory, which update.sh handles by scanning it.
track() {
    command -v git >/dev/null 2>&1 || return 0
    if ! git init -q "$REPO" 2>/dev/null || ! git -C "$REPO" add -A; then
        fail "cannot set up git in the sandbox"
    fi
}

# Build the sandbox of the test named $1.
sandbox() {
    SANDBOX="$TEST_TMP/$1"
    REPO="$SANDBOX/repo"
    HOME="$SANDBOX/home"
    TMPDIR="$SANDBOX/tmp"
    OUT="$SANDBOX/out"
    ERR="$SANDBOX/err"
    RC=0
    export HOME TMPDIR
    mkdir -p -- "$REPO" "$HOME" "$TMPDIR" || fail "cannot create the sandbox"
    cp -- "$UPDATE_SH" "$REPO/update.sh" || fail "cannot copy update.sh"

    # configuration: the four files update.sh is expected to manage
    put "$REPO/.rc" 'rc v1'
    put "$REPO/.config/app/conf" 'conf v1'
    put "$REPO/.app.d/init.el" 'init v1'
    put "$REPO/.local/bin/tool" '#!/bin/sh'
    chmod +x "$REPO/.local/bin/tool"

    # not configuration: update.sh must leave all of these alone
    put "$REPO/README.md" 'readme'
    put "$REPO/LICENSE" 'license'
    put "$REPO/.gitignore" '*.log'
    put "$REPO/tests/test_update.sh" 'a test'
    for stub in $HAND_COPY; do
        put "$REPO/$stub" "stub $stub"
    done
    track
}

# Run update.sh in the sandbox repo. Its stdout goes to $OUT, its stderr to
# $ERR and its exit code to $RC.
run() {
    run_in "$REPO" ./update.sh "$@"
}

# The same, from directory $1 and with the script named explicitly.
run_in() {
    run_dir=$1
    shift
    RC=0
    # shellcheck disable=SC2086  # the shell may come with arguments
    (cd -- "$run_dir" && exec $UPDATE_SH_SHELL "$@") > "$OUT" 2> "$ERR" || RC=$?
}

assert_exit() {
    [ "$RC" -eq "$1" ] || fail "exit code $RC, expected $1"
}

# stdout has each argument as a whole line.
assert_out() {
    for line do
        grep -F -x -q -e "$line" "$OUT" || fail "stdout lacks the line: $line"
    done
}

# The same for stderr.
assert_err() {
    for line do
        grep -F -x -q -e "$line" "$ERR" || fail "stderr lacks the line: $line"
    done
}

# stdout is the arguments, one per line, and nothing else.
assert_out_is() {
    printf '%s\n' "$@" | cmp -s - "$OUT" || fail "stdout is not exactly: $*"
}

# stdout contains / does not contain the text $1 anywhere.
assert_out_has() {
    grep -F -q -e "$1" "$OUT" || fail "stdout lacks: $1"
}

assert_no_out() {
    if grep -F -q -e "$1" "$OUT"; then
        fail "stdout should not mention: $1"
    fi
}

# $1 is a regular file, not a symlink, that holds exactly the line $2.
assert_holds() {
    if [ -L "$1" ] || [ ! -f "$1" ]; then
        fail "not a regular file: $1"
    fi
    [ "$(cat -- "$1")" = "$2" ] || fail "$1 holds '$(cat -- "$1")', not '$2'"
}

assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail "should not exist: $1"
    fi
}

assert_link() {
    [ -L "$1" ] || fail "not a symlink: $1"
    [ "$(readlink -- "$1")" = "$2" ] ||
        fail "$1 points at $(readlink -- "$1"), not at $2"
}

# The backup taken of $HOME/$1 holds the line $2. The directory in between is
# a timestamp, hence the glob; when nothing matches, assert_holds says so.
assert_backup() {
    for backup in "$HOME"/.dotfiles-backup/*/"$1"; do
        assert_holds "$backup" "$2"
        return 0
    done
}

assert_no_backup() {
    assert_absent "$HOME/.dotfiles-backup"
}

# Stand in for Oh my tmux!: a local repo that git is told to use in place of
# the real URL, so `tmux` clones and pulls for real, without the network.
fake_oh_my_tmux() {
    need_git
    [ -n "$OMT_URL" ] || fail "cannot find OMT_URL in $UPDATE_SH"
    UPSTREAM="$SANDBOX/oh-my-tmux"
    git init -q "$UPSTREAM" 2>/dev/null || fail "cannot create the upstream"
    put "$UPSTREAM/.tmux.conf" '# https://github.com/gpakosz/.tmux'
    git -C "$UPSTREAM" add .tmux.conf
    upstream_commit 'first'
    git config --file "$HOME/.gitconfig" "url.$UPSTREAM.insteadOf" "$OMT_URL"
    # Should the redirect ever stop applying, fail instead of going online.
    GIT_ALLOW_PROTOCOL=file
    export GIT_ALLOW_PROTOCOL
}

upstream_commit() {
    git -C "$UPSTREAM" -c user.name=test -c user.email=test@example.com \
        commit -q --allow-empty -m "$1" || fail "cannot commit upstream"
}

# The same for chemacs2: a local repo that holds a chemacs.el.
fake_chemacs2() {
    need_git
    [ -n "$CHEMACS_URL" ] || fail "cannot find CHEMACS_URL in $UPDATE_SH"
    UPSTREAM="$SANDBOX/chemacs2"
    git init -q "$UPSTREAM" 2>/dev/null || fail "cannot create the upstream"
    put "$UPSTREAM/chemacs.el" ';;; chemacs.el --- a stand-in'
    put "$UPSTREAM/init.el" '(load "chemacs")'
    git -C "$UPSTREAM" add chemacs.el init.el
    upstream_commit 'first'
    git config --file "$HOME/.gitconfig" "url.$UPSTREAM.insteadOf" "$CHEMACS_URL"
    GIT_ALLOW_PROTOCOL=file
    export GIT_ALLOW_PROTOCOL
}

# The same for MEGA 2.0: a local repo with the file update.sh knows it by,
# and a .gitignore that leaves local.el to the machine, as the real one has.
fake_mega2() {
    need_git
    [ -n "$MEGA2_URL" ] || fail "cannot find MEGA2_URL in $UPDATE_SH"
    UPSTREAM="$SANDBOX/mega2"
    git init -q "$UPSTREAM" 2>/dev/null || fail "cannot create the upstream"
    put "$UPSTREAM/init.el" 'init v1'
    put "$UPSTREAM/lisp/mega-lib.el" "(provide 'mega-lib)"
    put "$UPSTREAM/lisp/b.el" 'b v1'
    put "$UPSTREAM/.gitignore" '/local.el'
    git -C "$UPSTREAM" add -A
    upstream_commit 'first'
    git config --file "$HOME/.gitconfig" "url.$UPSTREAM.insteadOf" "$MEGA2_URL"
    GIT_ALLOW_PROTOCOL=file
    export GIT_ALLOW_PROTOCOL
}

# MEGA 2.0 as update.sh installed it when it was a directory of the dotfiles:
# plain files, one of them from a version long gone, and the list that was
# kept of them. And what an Emacs without a configuration wrote there once.
copy_of_mega2() {
    put "$HOME/.mega2.d/init.el" 'init v0'
    put "$HOME/.mega2.d/lisp/mega-lib.el" "(provide 'mega-lib) ; v0"
    put "$HOME/.mega2.d/lisp/stale.el" 'from a version long gone'
    put "$HOME/.mega2.d/eln-cache/31.1/xterm.eln" 'built by a plain Emacs'
    put "$HOME/.local/state/dotfiles/mega2.files" '.mega2.d/init.el'
}

# Nothing was left beside ~/.mega2.d by a clone that was being made, or by
# a local.el that was being carried over.
assert_nothing_beside_mega2() {
    for beside in "$HOME"/.mega2.d.*; do
        if [ -e "$beside" ] || [ -L "$beside" ]; then
            fail "left behind: $beside"
        fi
    done
}

# --- command line -----------------------------------------------------------

test_no_command_is_a_usage_error() {
    run
    assert_exit 2
    assert_err "update.sh: no command given"
    grep -q '^usage: ' "$ERR" || fail "no usage on stderr"
    [ ! -s "$OUT" ] || fail "a usage error wrote to stdout"
}

test_unknown_command_is_a_usage_error() {
    run frobnicate
    assert_exit 2
    assert_err "update.sh: unknown command: frobnicate"
}

test_unknown_option_is_a_usage_error() {
    run user -x
    assert_exit 2
    assert_err "update.sh: unknown option: -x"
    assert_absent "$HOME/.rc"
}

test_stray_argument_is_a_usage_error() {
    run user extra
    assert_exit 2
    assert_err "update.sh: unexpected argument: extra"
    assert_absent "$HOME/.rc"
}

test_help_prints_the_usage_and_succeeds() {
    for arg in help -h --help; do
        run "$arg"
        assert_exit 0
        grep -q '^usage: ' "$OUT" || fail "$arg: no usage on stdout"
        [ ! -s "$ERR" ] || fail "$arg: wrote to stderr"
    done
    run user --help
    assert_exit 0
    assert_absent "$HOME/.rc"
}

test_long_options_work_like_the_short_ones() {
    put "$HOME/.rc" 'rc local'
    run user --dry-run
    assert_out "(dry run -- nothing will be written)"
    assert_holds "$HOME/.rc" 'rc local'
    run user --force
    assert_holds "$HOME/.rc" 'rc v1'
    assert_no_backup
}

test_runs_from_any_directory() {
    run_in / "$REPO/update.sh" user
    assert_exit 0
    assert_holds "$HOME/.rc" 'rc v1'
}

test_leaves_no_temporary_file_behind() {
    run user
    run diff
    run local repo
    [ -z "$(ls -A "$TMPDIR")" ] || fail "left behind: $(ls -A "$TMPDIR")"
}

# --- the managed file list --------------------------------------------------

test_list_prints_the_managed_files_sorted() {
    run list
    assert_exit 0
    assert_out_is .app.d/init.el .config/app/conf .local/bin/tool .rc
}

test_the_tests_directory_is_not_managed() {
    put "$REPO/tests/data/deep/file" 'a fixture'
    put "$REPO/tests.conf" 'only looks like the directory'
    put "$REPO/.config/tests/conf" 'a tests directory further down'
    track
    put "$REPO/tests/scratch" 'untracked'
    run list
    assert_out_is .app.d/init.el .config/app/conf .config/tests/conf \
        .local/bin/tool .rc tests.conf
    run user
    assert_exit 0
    assert_absent "$HOME/tests"
    assert_holds "$HOME/tests.conf" 'only looks like the directory'
    assert_holds "$HOME/.config/tests/conf" 'a tests directory further down'
    assert_no_out "note: untracked"
}

test_editor_debris_is_not_managed() {
    for debris in '.rc~' .rc.orig .rc.rej .rc.bak .rc.swp; do
        put "$REPO/$debris" 'debris'
    done
    track
    run list
    assert_out_is .app.d/init.el .config/app/conf .local/bin/tool .rc
}

test_an_untracked_file_is_not_managed_and_is_pointed_out() {
    need_git
    put "$REPO/.newrc" 'new'
    put "$REPO/debug.log" 'ignored by the .gitignore of the sandbox'
    run list
    assert_out .rc
    assert_out_has "note: untracked, so not deployed: .newrc"
    assert_no_out "debug.log"
    run user
    assert_absent "$HOME/.newrc"
    assert_out_has "note: untracked, so not deployed: .newrc"
}

test_a_tracked_file_that_is_gone_is_not_managed() {
    need_git
    rm -- "$REPO/.rc"
    run list
    assert_out_is .app.d/init.el .config/app/conf .local/bin/tool
    run user
    assert_exit 0
    assert_absent "$HOME/.rc"
}

test_outside_git_every_file_in_the_directory_is_managed() {
    rm -rf -- "$REPO/.git"
    put "$REPO/.newrc" 'new'
    run list
    assert_out_is .app.d/init.el .config/app/conf .local/bin/tool .newrc .rc
    run user
    assert_exit 0
    assert_holds "$HOME/.newrc" 'new'
    assert_absent "$HOME/tests"
    assert_absent "$HOME/.bashrc.local"
    assert_no_out "note: untracked"
}

test_a_repo_without_managed_files_is_an_error() {
    rm -- "$REPO/.rc" "$REPO/.config/app/conf" "$REPO/.app.d/init.el" \
        "$REPO/.local/bin/tool"
    track
    run user
    assert_exit 1
    assert_err "update.sh: no managed files found in $REPO"
}

# --- user: repo -> $HOME ----------------------------------------------------

test_user_installs_into_an_empty_home() {
    run user
    assert_exit 0
    assert_out_is "Installing into $HOME" \
        "  create  .app.d/init.el" \
        "  create  .config/app/conf" \
        "  create  .local/bin/tool" \
        "  create  .rc" \
        "Done: 4 file(s) changed."
    assert_holds "$HOME/.rc" 'rc v1'
    assert_holds "$HOME/.config/app/conf" 'conf v1'
    [ -x "$HOME/.local/bin/tool" ] || fail "the executable bit was lost"
    assert_no_backup
}

test_user_leaves_out_what_is_not_configuration() {
    run user
    for path in update.sh README.md LICENSE .gitignore tests $HAND_COPY; do
        assert_absent "$HOME/$path"
    done
}

test_user_twice_changes_nothing() {
    run user
    run user
    assert_exit 0
    assert_out_is "Installing into $HOME" "Already up to date."
}

test_user_overwrites_a_changed_file_and_backs_it_up() {
    put "$HOME/.rc" 'rc local'
    put "$HOME/unrelated" 'mine'
    run user
    assert_exit 0
    assert_out "  update  .rc" "Done: 4 file(s) changed."
    assert_out_has "Backup: $HOME/.dotfiles-backup/"
    assert_holds "$HOME/.rc" 'rc v1'
    assert_backup .rc 'rc local'
    assert_holds "$HOME/unrelated" 'mine'
}

test_user_force_skips_the_backup() {
    put "$HOME/.rc" 'rc local'
    run user -f
    assert_exit 0
    assert_holds "$HOME/.rc" 'rc v1'
    assert_no_backup
    assert_no_out "Backup:"
}

test_user_dry_run_writes_nothing() {
    put "$HOME/.rc" 'rc local'
    run user -n
    assert_exit 0
    assert_out "(dry run -- nothing will be written)" \
        "  update  .rc" \
        "  create  .config/app/conf" \
        "Done: 4 file(s) would change."
    assert_holds "$HOME/.rc" 'rc local'
    assert_absent "$HOME/.config"
    assert_no_backup
}

# After `link`, $HOME holds symlinks. Copying through one would write the file
# onto itself, or onto whatever else the link points at.
test_user_replaces_a_symlink_without_writing_through_it() {
    put "$HOME/elsewhere" 'not a dotfile'
    ln -s "$HOME/elsewhere" "$HOME/.rc"
    run user
    assert_exit 0
    assert_holds "$HOME/.rc" 'rc v1'
    assert_holds "$HOME/elsewhere" 'not a dotfile'
    assert_no_backup
}

test_user_handles_awkward_file_names() {
    put "$REPO/.config/my app/has space.conf" 'spaced'
    put "$REPO/-dash" 'dashed'
    track
    run user
    assert_exit 0
    assert_holds "$HOME/.config/my app/has space.conf" 'spaced'
    assert_holds "$HOME/-dash" 'dashed'
}

test_user_reports_a_failure_and_carries_on() {
    put "$HOME/.config" 'a file where a directory has to go'
    run user
    assert_exit 1
    assert_err "update.sh: cannot create directory: $HOME/.config/app" \
        "update.sh: 1 error(s)"
    assert_out "Done: 3 file(s) changed."
    assert_holds "$HOME/.rc" 'rc v1'
    assert_holds "$HOME/.config" 'a file where a directory has to go'
}

# --- repo: $HOME -> repo ----------------------------------------------------

test_repo_collects_a_changed_file() {
    run user
    put "$HOME/.rc" 'rc edited'
    run repo
    assert_exit 0
    assert_out_is "Collecting from $HOME" \
        "  update  .rc" \
        "Done: 1 file(s) changed."
    assert_holds "$REPO/.rc" 'rc edited'
    assert_no_backup
}

test_repo_keeps_a_file_that_home_lacks() {
    put "$HOME/.rc" 'rc edited'
    run repo
    assert_exit 0
    # shellcheck disable=SC2016  # update.sh prints a literal $HOME here
    assert_out '  absent  .config/app/conf  (not in $HOME, skipped)' \
        "  update  .rc" \
        "Done: 1 file(s) changed."
    assert_holds "$REPO/.config/app/conf" 'conf v1'
    assert_holds "$REPO/.rc" 'rc edited'
}

test_repo_dry_run_writes_nothing() {
    run user
    put "$HOME/.rc" 'rc edited'
    run repo -n
    assert_exit 0
    assert_out "  update  .rc" "Done: 1 file(s) would change."
    assert_holds "$REPO/.rc" 'rc v1'
}

test_repo_ignores_what_it_does_not_manage() {
    run user
    put "$HOME/.bashrc.local" 'this machine only'
    put "$HOME/.stranger" 'never tracked'
    put "$HOME/README.md" 'not the readme of the repo'
    run repo
    assert_exit 0
    assert_out_is "Collecting from $HOME" "Already up to date."
    assert_holds "$REPO/.bashrc.local" 'stub .bashrc.local'
    assert_holds "$REPO/README.md" 'readme'
    assert_absent "$REPO/.stranger"
}

# --- link -------------------------------------------------------------------

test_link_points_home_at_the_repo() {
    run link
    assert_exit 0
    assert_out "Linking $HOME at $REPO" "  link    .rc" \
        "Done: 4 file(s) changed."
    assert_link "$HOME/.rc" "$REPO/.rc"
    assert_link "$HOME/.config/app/conf" "$REPO/.config/app/conf"
    assert_absent "$HOME/.bashrc.local"
    assert_absent "$HOME/tests"
}

test_link_backs_up_the_file_it_replaces() {
    put "$HOME/.rc" 'rc local'
    run link
    assert_exit 0
    assert_link "$HOME/.rc" "$REPO/.rc"
    assert_backup .rc 'rc local'
}

test_link_force_skips_the_backup() {
    put "$HOME/.rc" 'rc local'
    run link -f
    assert_exit 0
    assert_link "$HOME/.rc" "$REPO/.rc"
    assert_no_backup
}

test_link_dry_run_writes_nothing() {
    put "$HOME/.rc" 'rc local'
    run link -n
    assert_exit 0
    assert_out "  link    .rc"
    assert_holds "$HOME/.rc" 'rc local'
    assert_absent "$HOME/.config"
    assert_no_backup
}

test_link_then_repo_and_user_leave_the_repo_intact() {
    run link
    run repo
    assert_out_is "Collecting from $HOME" "Already up to date."
    run user
    assert_exit 0
    assert_holds "$HOME/.rc" 'rc v1'
    assert_holds "$REPO/.rc" 'rc v1'
    assert_no_backup
}

# --- diff -------------------------------------------------------------------

test_diff_of_identical_trees_says_so() {
    run user
    put "$HOME/.bashrc.local" 'this machine only'
    run diff
    assert_exit 0
    # shellcheck disable=SC2016  # update.sh prints a literal $HOME here
    assert_out_is 'repo and $HOME are identical'
}

test_diff_shows_what_differs_and_changes_nothing() {
    run user
    put "$HOME/.rc" 'rc edited'
    rm -- "$HOME/.config/app/conf"
    run diff
    assert_exit 0
    # shellcheck disable=SC2016  # update.sh prints a literal $HOME here
    assert_out '--- .rc' '-rc v1' '+rc edited' \
        '--- .config/app/conf: missing in $HOME'
    assert_no_out "identical"
    assert_holds "$HOME/.rc" 'rc edited'
    assert_holds "$REPO/.rc" 'rc v1'
    assert_absent "$HOME/.config/app/conf"
}

# --- local: the per-machine files -------------------------------------------

test_local_list_prints_the_per_machine_files() {
    run local list
    assert_exit 0
    for stub in $HAND_COPY; do
        assert_out "$stub"
    done
    [ "$(wc -l < "$OUT")" -eq 4 ] || fail "stdout lists something else too"
}

test_local_list_skips_a_stub_the_repo_lacks() {
    rm -- "$REPO/.zshrc.local"
    run local list
    assert_exit 0
    assert_out .bashrc.local
    assert_no_out ".zshrc.local"
}

test_local_user_installs_the_per_machine_files_only() {
    run local user
    assert_exit 0
    assert_out "  create  .gitconfig.local" "  create  .bashrc.local" \
        "Done: 4 file(s) changed."
    assert_holds "$HOME/.gitconfig.local" 'stub .gitconfig.local'
    assert_holds "$HOME/.gitconfig.signing" 'stub .gitconfig.signing'
    assert_absent "$HOME/.rc"
    assert_absent "$HOME/.app.d/init.el"
}

test_local_user_overwrites_a_changed_file_and_backs_it_up() {
    put "$HOME/.gitconfig.signing" 'this machine only'
    run local user
    assert_exit 0
    assert_out "  update  .gitconfig.signing"
    assert_holds "$HOME/.gitconfig.signing" 'stub .gitconfig.signing'
    assert_backup .gitconfig.signing 'this machine only'
}

test_local_user_dry_run_writes_nothing() {
    put "$HOME/.gitconfig.signing" 'this machine only'
    run local user -n
    assert_exit 0
    assert_out "  update  .gitconfig.signing" "Done: 4 file(s) would change."
    assert_holds "$HOME/.gitconfig.signing" 'this machine only'
    assert_absent "$HOME/.bashrc.local"
    assert_no_backup
}

test_local_repo_collects_the_per_machine_files_only() {
    run user
    run local user
    put "$HOME/.bashrc.local" 'this machine only'
    put "$HOME/.rc" 'rc edited'
    run local repo
    assert_exit 0
    assert_out_is "Collecting from $HOME" \
        "  update  .bashrc.local" \
        "Done: 1 file(s) changed."
    assert_holds "$REPO/.bashrc.local" 'this machine only'
    assert_holds "$REPO/.rc" 'rc v1'
}

test_local_diff_compares_the_per_machine_files_only() {
    run local user
    put "$HOME/.bashrc.local" 'this machine only'
    run local diff
    assert_exit 0
    assert_out '--- .bashrc.local' '-stub .bashrc.local' '+this machine only'
    # the configuration is not in this $HOME, and that is not reported
    assert_no_out "missing in"
    assert_holds "$REPO/.bashrc.local" 'stub .bashrc.local'
}

test_local_needs_a_command_it_supports() {
    for arg in '' link tmux frobnicate -n; do
        # shellcheck disable=SC2086  # unquoted, so the empty one vanishes
        run local $arg
        assert_exit 2
        assert_err "update.sh: local takes one of: user, repo, diff, list"
    done
    assert_absent "$HOME/.bashrc.local"
}

test_local_does_not_point_out_untracked_files() {
    need_git
    put "$REPO/.newrc" 'new'
    run local list
    assert_no_out "note: untracked"
    run local user
    assert_no_out "note: untracked"
}

# --- tmux -------------------------------------------------------------------

test_tmux_installs_oh_my_tmux() {
    fake_oh_my_tmux
    run tmux
    assert_exit 0
    assert_out "Installing Oh my tmux! into $HOME/.tmux" \
        "  clone   $OMT_URL" \
        "  link    .tmux.conf" \
        "Done: 2 file(s) changed."
    assert_holds "$HOME/.tmux/.tmux.conf" '# https://github.com/gpakosz/.tmux'
    assert_link "$HOME/.tmux.conf" "$HOME/.tmux/.tmux.conf"
    assert_absent "$HOME/.rc"
    assert_no_backup
}

test_tmux_dry_run_writes_nothing() {
    fake_oh_my_tmux
    run tmux -n
    assert_exit 0
    assert_out "  clone   $OMT_URL" \
        "  link    .tmux.conf" \
        "Done: 2 file(s) would change."
    assert_absent "$HOME/.tmux"
    assert_absent "$HOME/.tmux.conf"
}

test_tmux_twice_changes_nothing() {
    fake_oh_my_tmux
    run tmux
    run tmux
    assert_exit 0
    assert_out "Already up to date."
    assert_no_out "  clone   "
    assert_no_out "  link    "
}

test_tmux_pulls_what_upstream_added() {
    fake_oh_my_tmux
    run tmux
    old=$(git -C "$HOME/.tmux" rev-parse HEAD)
    upstream_commit 'second'
    new=$(git -C "$UPSTREAM" rev-parse HEAD)

    run tmux -n
    assert_exit 0
    assert_out "  update  $HOME/.tmux" "Done: 1 file(s) would change."
    [ "$(git -C "$HOME/.tmux" rev-parse HEAD)" = "$old" ] ||
        fail "the dry run moved HEAD"
    if git -C "$HOME/.tmux" cat-file -e "$new" 2>/dev/null; then
        fail "the dry run fetched"
    fi

    run tmux
    assert_exit 0
    assert_out "Done: 1 file(s) changed."
    [ "$(git -C "$HOME/.tmux" rev-parse HEAD)" = "$new" ] ||
        fail "the clone was not updated"
}

test_tmux_backs_up_the_tmux_conf_it_replaces() {
    fake_oh_my_tmux
    put "$HOME/.tmux.conf" 'set -g mouse on'
    run tmux
    assert_exit 0
    assert_link "$HOME/.tmux.conf" "$HOME/.tmux/.tmux.conf"
    assert_backup .tmux.conf 'set -g mouse on'
}

test_tmux_force_skips_the_backup() {
    fake_oh_my_tmux
    put "$HOME/.tmux.conf" 'set -g mouse on'
    run tmux -f
    assert_exit 0
    assert_link "$HOME/.tmux.conf" "$HOME/.tmux/.tmux.conf"
    assert_no_backup
}

# Upstream's own instructions create this link, relative to $HOME.
test_tmux_accepts_the_relative_link_upstream_documents() {
    fake_oh_my_tmux
    run tmux
    rm -- "$HOME/.tmux.conf"
    ln -s .tmux/.tmux.conf "$HOME/.tmux.conf"
    run tmux
    assert_exit 0
    assert_out "Already up to date."
    assert_link "$HOME/.tmux.conf" .tmux/.tmux.conf
}

test_tmux_points_at_a_missing_tmux_conf_local() {
    fake_oh_my_tmux
    run tmux
    assert_out_has "no ~/.tmux.conf.local yet"
    put "$HOME/.tmux.conf.local" 'installed by user'
    run tmux
    assert_no_out "no ~/.tmux.conf.local yet"
}

test_tmux_refuses_a_directory_that_is_not_a_clone() {
    fake_oh_my_tmux
    put "$HOME/.tmux/plugins/tpm" 'mine'
    run tmux
    assert_exit 1
    assert_err \
        "update.sh: $HOME/.tmux exists and is not a git clone; move it aside first" \
        "update.sh: 1 error(s)"
    assert_no_out "Already up to date."
    assert_holds "$HOME/.tmux/plugins/tpm" 'mine'
    assert_absent "$HOME/.tmux.conf"
}

test_tmux_refuses_a_clone_of_something_else() {
    fake_oh_my_tmux
    git init -q "$HOME/.tmux" 2>/dev/null || fail "cannot create the clone"
    put "$HOME/.tmux/.tmux.conf" '# my own tmux configuration'
    run tmux
    assert_exit 1
    assert_err "update.sh: $HOME/.tmux is a git clone, but not of Oh my tmux!"
    assert_holds "$HOME/.tmux/.tmux.conf" '# my own tmux configuration'
    assert_absent "$HOME/.tmux.conf"
}

# --- install and uninstall: the command line ---------------------------------

test_install_needs_a_name() {
    run install
    assert_exit 2
    assert_err "update.sh: install what? One or more of: mega2 tmux chemacs2"
    run uninstall -n
    assert_exit 2
    assert_err "update.sh: uninstall what? One or more of: mega2 tmux chemacs2"
}

test_install_refuses_a_name_it_does_not_know() {
    run install emacs
    assert_exit 2
    assert_err "update.sh: install knows nothing called 'emacs'; it knows: mega2 tmux chemacs2"
    run uninstall mega
    assert_exit 2
    assert_err "update.sh: uninstall knows nothing called 'mega'; it knows: mega2 tmux chemacs2"
    assert_absent "$HOME/.rc"
    # One wrong name among right ones: nothing at all is done.
    fake_mega2
    run install mega2 vim
    assert_exit 2
    assert_absent "$HOME/.mega2.d"
}

test_help_names_what_can_be_installed() {
    run help
    assert_exit 0
    assert_out_has "install NAME..."
    assert_out_has "uninstall NAME..."
    for name in mega2 chemacs2 tmux; do
        grep -q "^  $name  " "$OUT" || fail "the help does not list: $name"
    done
}

# --- user: what it no longer does ---------------------------------------------

test_user_never_removes_what_the_repo_no_longer_tracks() {
    run user
    rm -f -- "$REPO/.rc"
    track
    run user
    assert_exit 0
    # The repo no longer tracking a dotfile does not mean you no longer want
    # the one you have.
    assert_holds "$HOME/.rc" 'rc v1'
    assert_no_backup
}

test_user_leaves_mega2_alone_and_points_out_a_copy() {
    copy_of_mega2
    run user
    assert_exit 0
    assert_out "note: $HOME/.mega2.d is a copy from when MEGA 2.0 was part of this repo;" \
        "      'update.sh install mega2' replaces it by a clone, which can be updated"
    assert_holds "$HOME/.mega2.d/init.el" 'init v0'
    assert_holds "$HOME/.mega2.d/lisp/stale.el" 'from a version long gone'
    [ -f "$HOME/.local/state/dotfiles/mega2.files" ] || fail "'user' removed the list"
    # The per-machine files are another matter altogether.
    run local user
    assert_no_out "note: $HOME/.mega2.d"
    # And a clone is nothing to point out.
    fake_mega2
    run install mega2
    run user
    assert_exit 0
    assert_no_out "note: $HOME/.mega2.d"
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
}

# --- install and uninstall: mega2 ---------------------------------------------

test_install_mega2_clones_it_and_nothing_else() {
    fake_mega2
    run install mega2
    assert_exit 0
    assert_out_is "Installing MEGA 2.0 into $HOME/.mega2.d" \
        "  clone   $MEGA2_URL" \
        "  start it with:  emacs --init-directory $HOME/.mega2.d" \
        "  or have plain 'emacs' start it:  update.sh install chemacs2" \
        "Done: 1 file(s) changed."
    [ -d "$HOME/.mega2.d/.git" ] || fail "what was installed is not a clone"
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.mega2.d/lisp/mega-lib.el" "(provide 'mega-lib)"
    # Nothing of this repo comes along, and nothing is written beside it.
    assert_absent "$HOME/.rc"
    assert_absent "$HOME/.app.d"
    assert_absent "$HOME/.local"
    assert_nothing_beside_mega2
    assert_no_backup
}

test_install_mega2_says_what_chemacs2_still_lacks() {
    fake_mega2
    put "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a stand-in'
    run install mega2
    assert_exit 0
    assert_out "  no ~/.emacs-profiles.el yet: 'update.sh user' installs this repo's copy"
    assert_no_out "--init-directory"
    # With the profiles there as well, there is nothing to add.
    rm -rf -- "$HOME/.mega2.d"
    put "$HOME/.emacs-profiles.el" '(("default" . ((user-emacs-directory . "~/.mega2.d"))))'
    run install mega2
    assert_exit 0
    assert_out_is "Installing MEGA 2.0 into $HOME/.mega2.d" \
        "  clone   $MEGA2_URL" \
        "Done: 1 file(s) changed."
}

test_install_mega2_twice_changes_nothing_and_then_pulls() {
    fake_mega2
    run install mega2
    run install mega2
    assert_exit 0
    assert_out_is "Installing MEGA 2.0 into $HOME/.mega2.d" "Already up to date."
    # A new version: a file changed, a file added, a file gone.
    put "$UPSTREAM/init.el" 'init v2'
    put "$UPSTREAM/lisp/c.el" 'c v2'
    rm -f -- "$UPSTREAM/lisp/b.el"
    git -C "$UPSTREAM" add -A
    upstream_commit 'second'
    # And what is yours, which its .gitignore leaves to you.
    put "$HOME/.mega2.d/local.el" 'my settings'
    run install mega2 -n
    assert_exit 0
    assert_out "  update  $HOME/.mega2.d" "Done: 1 file(s) would change."
    assert_no_out "restart it"
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    run install mega2
    assert_exit 0
    assert_out "  an Emacs that is running goes on with what it loaded: restart it" \
        "Done: 1 file(s) changed."
    assert_holds "$HOME/.mega2.d/init.el" 'init v2'
    assert_holds "$HOME/.mega2.d/lisp/c.el" 'c v2'
    # Nothing stale is left behind, and nothing of yours is touched.
    assert_absent "$HOME/.mega2.d/lisp/b.el"
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_no_backup
}

test_install_takes_several_names() {
    fake_mega2
    fake_chemacs2
    run install mega2 chemacs2
    assert_exit 0
    assert_out "Installing MEGA 2.0 into $HOME/.mega2.d" \
        "Installing chemacs2 into $HOME/.emacs.d" \
        "Done: 2 file(s) changed."
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a stand-in'
}

test_install_mega2_dry_run_writes_nothing() {
    fake_mega2
    run install mega2 -n
    assert_exit 0
    assert_out_is "(dry run -- nothing will be written)" \
        "Installing MEGA 2.0 into $HOME/.mega2.d" \
        "  clone   $MEGA2_URL" \
        "Done: 1 file(s) would change."
    assert_absent "$HOME/.mega2.d"
    assert_no_backup
}

# --- install mega2: where a copy is, from before MEGA had a repository --------

test_install_mega2_puts_a_clone_where_a_copy_is() {
    fake_mega2
    copy_of_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    run install mega2
    assert_exit 0
    assert_out "Installing MEGA 2.0 into $HOME/.mega2.d" \
        "  replace $HOME/.mega2.d  (not a clone; one takes its place)" \
        "  clone   $MEGA2_URL" \
        "  kept    $HOME/.mega2.d/local.el  (yours)" \
        "  an Emacs that is running goes on with what it loaded: restart it" \
        "Done: 2 file(s) changed."
    assert_out_has "Backup: $HOME/.dotfiles-backup/"
    [ -d "$HOME/.mega2.d/.git" ] || fail "the copy was not replaced by a clone"
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_absent "$HOME/.mega2.d/lisp/stale.el"
    assert_absent "$HOME/.mega2.d/eln-cache"
    # What was there is where backups go, all of it.
    assert_backup .mega2.d/init.el 'init v0'
    assert_backup .mega2.d/lisp/stale.el 'from a version long gone'
    assert_backup .mega2.d/eln-cache/31.1/xterm.eln 'built by a plain Emacs'
    # The list that was kept of the copy has nothing left to say.
    assert_absent "$HOME/.local/state/dotfiles"
    assert_nothing_beside_mega2
    # From here on it is a clone like any other.
    run install mega2
    assert_exit 0
    assert_out_is "Installing MEGA 2.0 into $HOME/.mega2.d" "Already up to date."
}

test_putting_a_clone_where_a_copy_is_dry_run_writes_nothing() {
    fake_mega2
    copy_of_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    run install mega2 -n
    assert_exit 0
    assert_out "  replace $HOME/.mega2.d  (not a clone; one takes its place)" \
        "  clone   $MEGA2_URL" \
        "  kept    $HOME/.mega2.d/local.el  (yours)" \
        "Done: 2 file(s) would change."
    assert_holds "$HOME/.mega2.d/init.el" 'init v0'
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_absent "$HOME/.mega2.d/.git"
    [ -f "$HOME/.local/state/dotfiles/mega2.files" ] || fail "a dry run removed the list"
    assert_nothing_beside_mega2
    assert_no_backup
}

test_putting_a_clone_where_a_copy_is_with_force_still_keeps_local_el() {
    fake_mega2
    copy_of_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    run install mega2 -f
    assert_exit 0
    [ -d "$HOME/.mega2.d/.git" ] || fail "the copy was not replaced by a clone"
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_absent "$HOME/.mega2.d/lisp/stale.el"
    assert_nothing_beside_mega2
    assert_no_backup
}

test_a_copy_is_as_it_was_when_the_clone_cannot_be_made() {
    need_git
    copy_of_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    # Nowhere to clone from, and git is told not to go looking online.
    GIT_ALLOW_PROTOCOL=file
    export GIT_ALLOW_PROTOCOL
    run install mega2
    assert_exit 1
    assert_err "update.sh: cannot clone: $MEGA2_URL; $HOME/.mega2.d is as it was"
    assert_holds "$HOME/.mega2.d/init.el" 'init v0'
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_holds "$HOME/.mega2.d/lisp/stale.el" 'from a version long gone'
    assert_absent "$HOME/.mega2.d/.git"
    [ -f "$HOME/.local/state/dotfiles/mega2.files" ] || fail "the list went all the same"
    assert_nothing_beside_mega2
    assert_no_backup
}

test_install_mega2_where_only_leftovers_are() {
    fake_mega2
    # What an uninstall of the copy left, with its mark; and what an Emacs
    # wrote that chemacs2 started on the profile while MEGA was away.
    put "$HOME/.mega2.d/local.el" 'my settings'
    put "$HOME/.mega2.d/eln-cache/31.1/xterm.eln" 'built by a plain Emacs'
    put "$HOME/.local/state/dotfiles/mega2.removed" ''
    run install mega2
    assert_exit 0
    [ -d "$HOME/.mega2.d/.git" ] || fail "no clone was made"
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_absent "$HOME/.mega2.d/eln-cache"
    assert_backup .mega2.d/eln-cache/31.1/xterm.eln 'built by a plain Emacs'
    assert_absent "$HOME/.local/state/dotfiles"
    assert_nothing_beside_mega2
}

test_install_mega2_where_only_local_el_is_has_nothing_to_back_up() {
    fake_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    run install mega2
    assert_exit 0
    assert_out "  clone   $MEGA2_URL" \
        "  kept    $HOME/.mega2.d/local.el  (yours)" \
        "  start it with:  emacs --init-directory $HOME/.mega2.d" \
        "Done: 1 file(s) changed."
    assert_no_out "  replace "
    assert_no_out "restart it"
    [ -d "$HOME/.mega2.d/.git" ] || fail "no clone was made"
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_nothing_beside_mega2
    assert_no_backup
}

test_mega2_refuses_what_is_not_its_to_replace() {
    fake_mega2
    # A clone of something else.
    git init -q "$HOME/.mega2.d" 2>/dev/null || fail "cannot create the clone"
    put "$HOME/.mega2.d/init.el" 'somebody else has this name too'
    run install mega2
    assert_exit 1
    assert_err "update.sh: $HOME/.mega2.d is a git clone, but not of MEGA 2.0"
    run uninstall mega2
    assert_exit 1
    assert_err "update.sh: $HOME/.mega2.d is not a clone of MEGA 2.0; it is left alone"
    assert_holds "$HOME/.mega2.d/init.el" 'somebody else has this name too'
    # A link: to a checkout of yours, say, that you work on MEGA in.
    rm -rf -- "$HOME/.mega2.d"
    git clone -q "$UPSTREAM" "$SANDBOX/checkout" 2>/dev/null || fail "cannot clone"
    put "$SANDBOX/checkout/local.el" 'my settings'
    ln -s "$SANDBOX/checkout" "$HOME/.mega2.d" || fail "cannot link"
    put "$UPSTREAM/init.el" 'init v2'
    git -C "$UPSTREAM" add -A
    upstream_commit 'second'
    run install mega2
    assert_exit 1
    assert_err "update.sh: $HOME/.mega2.d is a link; what it points at is yours to update"
    run uninstall mega2
    assert_exit 1
    assert_err "update.sh: $HOME/.mega2.d is a link; what it points at is yours to remove"
    assert_link "$HOME/.mega2.d" "$SANDBOX/checkout"
    assert_holds "$SANDBOX/checkout/init.el" 'init v1'
    assert_holds "$SANDBOX/checkout/local.el" 'my settings'
    assert_no_backup
}

test_the_old_lists_are_looked_for_where_the_state_directory_is() {
    fake_mega2
    XDG_STATE_HOME="$SANDBOX/state"
    export XDG_STATE_HOME
    put "$SANDBOX/state/dotfiles/mega2.files" '.mega2.d/init.el'
    put "$HOME/.local/state/dotfiles/mega2.files" 'not the one in use'
    run install mega2
    assert_exit 0
    assert_absent "$SANDBOX/state/dotfiles"
    assert_holds "$HOME/.local/state/dotfiles/mega2.files" 'not the one in use'
}

# --- uninstall mega2 ----------------------------------------------------------

test_uninstall_mega2_moves_it_to_the_backups_and_keeps_what_is_yours() {
    fake_mega2
    run install mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    put "$HOME/.mega2.d/lisp/mine.el" 'my module'
    put "$HOME/.cache/mega2/compiled/abc/mega-lib.elc" 'built'
    put "$HOME/.cache/mega2/eln/x.eln" 'built'
    put "$HOME/.cache/mega2/backup/file" 'a backup of your work'
    put "$HOME/.local/state/mega2/history" 'your history'
    run uninstall mega2
    assert_exit 0
    assert_out "Removing MEGA 2.0 from $HOME/.mega2.d" \
        "  remove  $HOME/.mega2.d" \
        "  kept    $HOME/.mega2.d/local.el  (yours)" \
        "  remove  $HOME/.cache/mega2/compiled  (built by MEGA, which builds it again)" \
        "  remove  $HOME/.cache/mega2/eln  (built by MEGA, which builds it again)" \
        "  kept    what MEGA remembers, and its backups of your files:" \
        "          $HOME/.local/state/mega2  $HOME/.cache/mega2" \
        "Done: 3 file(s) changed."
    assert_absent "$HOME/.mega2.d/init.el"
    assert_absent "$HOME/.mega2.d/lisp"
    assert_absent "$HOME/.mega2.d/.git"
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    # What you put into it went with it, to where backups go.
    assert_backup .mega2.d/init.el 'init v1'
    assert_backup .mega2.d/lisp/mine.el 'my module'
    assert_absent "$HOME/.cache/mega2/compiled"
    assert_absent "$HOME/.cache/mega2/eln"
    assert_holds "$HOME/.cache/mega2/backup/file" 'a backup of your work'
    assert_holds "$HOME/.local/state/mega2/history" 'your history'
    assert_nothing_beside_mega2
    # And back again: the clone, with your settings in it.
    run install mega2
    assert_exit 0
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
}

test_uninstall_mega2_says_so_when_a_profile_still_points_at_it() {
    fake_mega2
    run install mega2
    printf '%s\n' '(("default" . ((user-emacs-directory . "~/.mega2.d")))' \
        ' ("legacy" . ((user-emacs-directory . "~/.emacs.d"))))' > "$HOME/.emacs-profiles.el"
    run uninstall mega2
    assert_exit 0
    assert_out "  ~/.emacs-profiles.el still names ~/.mega2.d as a profile"
    # A directory that merely begins the same way is another one.
    run install mega2
    printf '%s\n' '(("default" . ((user-emacs-directory . "~/.mega2.d.old"))))' \
        > "$HOME/.emacs-profiles.el"
    run uninstall mega2
    assert_exit 0
    assert_no_out "still names"
}

test_uninstall_mega2_dry_run_and_force() {
    fake_mega2
    run install mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    put "$HOME/.cache/mega2/compiled/abc/mega-lib.elc" 'built'
    run uninstall mega2 -n
    assert_exit 0
    assert_out "  remove  $HOME/.mega2.d" \
        "  kept    $HOME/.mega2.d/local.el  (yours)" \
        "Done: 2 file(s) would change."
    assert_holds "$HOME/.mega2.d/init.el" 'init v1'
    assert_holds "$HOME/.cache/mega2/compiled/abc/mega-lib.elc" 'built'
    assert_no_backup
    run uninstall mega2 -f
    assert_exit 0
    assert_absent "$HOME/.mega2.d/init.el"
    assert_absent "$HOME/.mega2.d/.git"
    # Declining backups is not asking for your settings to be deleted.
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_nothing_beside_mega2
    assert_no_backup
    # And once more, with nothing of MEGA there: said, and no error.
    run uninstall mega2
    assert_exit 0
    assert_out "  nothing at $HOME/.mega2.d but your local.el"
    assert_no_out "  remove  "
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    rm -f -- "$HOME/.mega2.d/local.el"
    run uninstall mega2
    assert_exit 0
    assert_out "  nothing at $HOME/.mega2.d"
    assert_absent "$HOME/.mega2.d"
    run uninstall mega2
    assert_exit 0
    assert_out "  nothing at $HOME/.mega2.d"
}

test_two_removals_within_a_second_do_not_end_up_in_one_another() {
    fake_mega2
    run install mega2
    put "$HOME/.mega2.d/first" 'the first time'
    run uninstall mega2
    assert_exit 0
    run install mega2
    put "$HOME/.mega2.d/second" 'the second time'
    run uninstall mega2
    assert_exit 0
    # Whether or not the clock moved on in between, each is whole, on its own.
    found=0
    for kept in "$HOME"/.dotfiles-backup/*/.mega2.d*; do
        [ -d "$kept/.git" ] || fail "not a whole clone: $kept"
        [ ! -e "$kept/.mega2.d" ] || fail "one removal ended up inside the other: $kept"
        found=$((found + 1))
    done
    [ "$found" -eq 2 ] || fail "$found removals were kept, not 2"
}

test_uninstall_mega2_removes_a_copy_as_well() {
    copy_of_mega2
    put "$HOME/.mega2.d/local.el" 'my settings'
    run uninstall mega2
    assert_exit 0
    assert_out "  remove  $HOME/.mega2.d" "  kept    $HOME/.mega2.d/local.el  (yours)"
    assert_absent "$HOME/.mega2.d/init.el"
    assert_absent "$HOME/.mega2.d/eln-cache"
    assert_holds "$HOME/.mega2.d/local.el" 'my settings'
    assert_backup .mega2.d/lisp/stale.el 'from a version long gone'
    assert_absent "$HOME/.local/state/dotfiles"
}

# --- what is deployed beside it -----------------------------------------------

# chemacs2 is told where MEGA 2.0 is by a file this repo deploys, and
# update.sh puts MEGA 2.0 where its MEGA2_DIR says: the two must agree.
test_the_default_emacs_profile_is_where_mega2_is_installed() {
    profiles="$(dirname -- "$UPDATE_SH")/.emacs-profiles.el"
    [ -f "$profiles" ] || skip "no .emacs-profiles.el beside the script under test"
    dir=$(sed -n 's/^MEGA2_DIR="\$HOME\/\(.*\)"$/\1/p' "$UPDATE_SH")
    [ -n "$dir" ] || fail "cannot find MEGA2_DIR in $UPDATE_SH"
    grep -F -q -e "(\"default\" . ((user-emacs-directory . \"~/$dir\")))" "$profiles" ||
        fail "the default profile in $profiles is not ~/$dir"
}

# --- install and uninstall: chemacs2 ------------------------------------------

test_install_chemacs2_clones_it_into_emacs_d() {
    fake_chemacs2
    run install chemacs2
    assert_exit 0
    assert_out "Installing chemacs2 into $HOME/.emacs.d" \
        "  clone   $CHEMACS_URL" \
        "  no ~/.emacs-profiles.el yet: 'update.sh user' installs this repo's copy" \
        "Done: 1 file(s) changed."
    assert_holds "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a stand-in'
    assert_absent "$HOME/.rc"
}

test_install_chemacs2_twice_changes_nothing_and_then_pulls() {
    fake_chemacs2
    run install chemacs2
    run install chemacs2
    assert_exit 0
    assert_out "Already up to date."
    put "$UPSTREAM/chemacs.el" ';;; chemacs.el --- a newer stand-in'
    git -C "$UPSTREAM" add chemacs.el
    upstream_commit 'second'
    run install chemacs2 -n
    assert_exit 0
    assert_out "  update  $HOME/.emacs.d" "Done: 1 file(s) would change."
    assert_holds "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a stand-in'
    run install chemacs2
    assert_exit 0
    assert_holds "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a newer stand-in'
}

test_install_chemacs2_never_touches_a_configuration_of_yours() {
    fake_chemacs2
    put "$HOME/.emacs.d/init.el" 'my own Emacs configuration'
    run install chemacs2
    assert_exit 1
    assert_err "update.sh: $HOME/.emacs.d exists and is not a git clone; move it aside first"
    assert_holds "$HOME/.emacs.d/init.el" 'my own Emacs configuration'
    # Nor one that is kept in git.
    git init -q "$HOME/.emacs.d" 2>/dev/null || fail "cannot create the clone"
    run install chemacs2
    assert_exit 1
    assert_err "update.sh: $HOME/.emacs.d is a git clone, but not of chemacs2"
    assert_holds "$HOME/.emacs.d/init.el" 'my own Emacs configuration'
    run uninstall chemacs2
    assert_exit 1
    assert_err "update.sh: $HOME/.emacs.d is not a clone of chemacs2; it is left alone"
    assert_holds "$HOME/.emacs.d/init.el" 'my own Emacs configuration'
}

test_uninstall_chemacs2_moves_it_to_the_backups() {
    fake_chemacs2
    run install chemacs2
    # What Emacs wrote into it since: yours, and kept with it.
    put "$HOME/.emacs.d/history" 'typed over the years'
    run uninstall chemacs2
    assert_exit 0
    assert_out "Removing chemacs2 from $HOME/.emacs.d" "  remove  $HOME/.emacs.d"
    assert_absent "$HOME/.emacs.d"
    assert_backup .emacs.d/history 'typed over the years'
    assert_backup .emacs.d/chemacs.el ';;; chemacs.el --- a stand-in'
}

test_uninstall_chemacs2_with_force_and_dry_run() {
    fake_chemacs2
    run install chemacs2
    run uninstall chemacs2 -n
    assert_exit 0
    assert_out "  remove  $HOME/.emacs.d" "Done: 1 file(s) would change."
    assert_holds "$HOME/.emacs.d/chemacs.el" ';;; chemacs.el --- a stand-in'
    run uninstall chemacs2 -f
    assert_exit 0
    assert_absent "$HOME/.emacs.d"
    assert_no_backup
    # And once more, with nothing there: said, and no error.
    run uninstall chemacs2
    assert_exit 0
    assert_out "  nothing at $HOME/.emacs.d" "Already up to date."
}

# --- install and uninstall: tmux ----------------------------------------------

test_install_tmux_is_what_the_tmux_command_was() {
    fake_oh_my_tmux
    run install tmux
    assert_exit 0
    assert_out "Installing Oh my tmux! into $HOME/.tmux" \
        "  clone   $OMT_URL" \
        "  link    .tmux.conf" \
        "Done: 2 file(s) changed."
    assert_link "$HOME/.tmux.conf" "$HOME/.tmux/.tmux.conf"
}

test_uninstall_tmux_removes_the_clone_and_the_link() {
    fake_oh_my_tmux
    run install tmux
    put "$HOME/.tmux.conf.local" 'this repo'"'"'s settings'
    run uninstall tmux
    assert_exit 0
    assert_out "Removing Oh my tmux! from $HOME/.tmux" \
        "  remove  $HOME/.tmux" \
        "  remove  .tmux.conf" \
        "Done: 2 file(s) changed."
    assert_absent "$HOME/.tmux"
    assert_absent "$HOME/.tmux.conf"
    assert_holds "$HOME/.tmux.conf.local" 'this repo'"'"'s settings'
    assert_backup .tmux/.tmux.conf '# https://github.com/gpakosz/.tmux'
}

test_uninstall_tmux_leaves_a_tmux_conf_of_yours() {
    fake_oh_my_tmux
    run install tmux
    rm -f -- "$HOME/.tmux.conf"
    put "$HOME/.tmux.conf" 'my own tmux configuration'
    run uninstall tmux
    assert_exit 0
    assert_no_out "  remove  .tmux.conf"
    assert_holds "$HOME/.tmux.conf" 'my own tmux configuration'
    assert_absent "$HOME/.tmux"
}

test_uninstall_tmux_refuses_what_is_not_oh_my_tmux() {
    need_git
    git init -q "$HOME/.tmux" 2>/dev/null || fail "cannot create the clone"
    put "$HOME/.tmux/.tmux.conf" '# something else entirely'
    run uninstall tmux
    assert_exit 1
    assert_err "update.sh: $HOME/.tmux is not a clone of Oh my tmux!; it is left alone"
    assert_holds "$HOME/.tmux/.tmux.conf" '# something else entirely'
}

# --- runner -----------------------------------------------------------------

passed=0
failed=0
skipped=0

for test in $(sed -n 's/^\(test_[A-Za-z0-9_]*\)().*/\1/p' "$0"); do
    name=${test#test_}
    if [ $# -gt 0 ]; then
        wanted=0
        for filter do
            case $name in
                *"$filter"*) wanted=1 ;;
            esac
        done
        [ "$wanted" -eq 1 ] || continue
    fi

    # A test fails by calling fail, and passes by reaching its end.
    (sandbox "$name" && "$test"; exit 0) > "$TEST_TMP/log" 2>&1
    case $? in
        0)
            passed=$((passed + 1))
            printf 'ok    %s\n' "$name"
            ;;
        77)
            skipped=$((skipped + 1))
            printf 'skip  %s  (%s)\n' "$name" "$(cat "$TEST_TMP/log")"
            ;;
        *)
            failed=$((failed + 1))
            printf 'FAIL  %s\n' "$name"
            sed 's/^/      /' "$TEST_TMP/log"
            for stream in out err; do
                [ -s "$TEST_TMP/$name/$stream" ] || continue
                printf '      --- std%s of the last run\n' "$stream"
                sed 's/^/      | /' "$TEST_TMP/$name/$stream"
            done
            ;;
    esac
done

printf '\n%d passed, %d failed, %d skipped  (update.sh run by: %s)\n' \
    "$passed" "$failed" "$skipped" "$UPDATE_SH_SHELL"

if [ $((passed + failed + skipped)) -eq 0 ]; then
    printf '%s: no test matches: %s\n' "$0" "$*" >&2
    exit 2
fi
[ "$failed" -eq 0 ]
