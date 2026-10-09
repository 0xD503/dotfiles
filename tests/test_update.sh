#!/bin/sh
#
# test_update.sh -- tests for update.sh.
#
# Each test runs in a sandbox of its own: a throwaway repo that holds a copy of
# update.sh next to a few fake dotfiles, and a throwaway $HOME. Nothing reads
# or writes the real repo or the real $HOME. Nothing uses the network either:
# the `tmux` tests clone a local stand-in for Oh my tmux!.
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
HAND_COPY=".bashrc.local .zshrc.local .mega.d/local.el .gitconfig.local
.gitconfig.signing"

# Where update.sh clones Oh my tmux! from. Read from the script, so that the
# `tmux` tests redirect the very URL it uses.
OMT_URL=$(sed -n 's/^OMT_URL="\(.*\)"$/\1/p' "$UPDATE_SH")

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
    put "$REPO/.mega.d/init.el" 'init v1'
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
    assert_out_is .config/app/conf .local/bin/tool .mega.d/init.el .rc
}

test_the_tests_directory_is_not_managed() {
    put "$REPO/tests/data/deep/file" 'a fixture'
    put "$REPO/tests.conf" 'only looks like the directory'
    put "$REPO/.config/tests/conf" 'a tests directory further down'
    track
    put "$REPO/tests/scratch" 'untracked'
    run list
    assert_out_is .config/app/conf .config/tests/conf .local/bin/tool \
        .mega.d/init.el .rc tests.conf
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
    assert_out_is .config/app/conf .local/bin/tool .mega.d/init.el .rc
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
    assert_out_is .config/app/conf .local/bin/tool .mega.d/init.el
    run user
    assert_exit 0
    assert_absent "$HOME/.rc"
}

test_outside_git_every_file_in_the_directory_is_managed() {
    rm -rf -- "$REPO/.git"
    put "$REPO/.newrc" 'new'
    run list
    assert_out_is .config/app/conf .local/bin/tool .mega.d/init.el .newrc .rc
    run user
    assert_exit 0
    assert_holds "$HOME/.newrc" 'new'
    assert_absent "$HOME/tests"
    assert_absent "$HOME/.bashrc.local"
    assert_no_out "note: untracked"
}

test_a_repo_without_managed_files_is_an_error() {
    rm -- "$REPO/.rc" "$REPO/.config/app/conf" "$REPO/.mega.d/init.el" \
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
        "  create  .config/app/conf" \
        "  create  .local/bin/tool" \
        "  create  .mega.d/init.el" \
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
    [ "$(wc -l < "$OUT")" -eq 5 ] || fail "stdout lists something else too"
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
    assert_out "  create  .mega.d/local.el" "Done: 5 file(s) changed."
    assert_holds "$HOME/.mega.d/local.el" 'stub .mega.d/local.el'
    assert_holds "$HOME/.gitconfig.signing" 'stub .gitconfig.signing'
    assert_absent "$HOME/.rc"
    assert_absent "$HOME/.mega.d/init.el"
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
    assert_out "  update  .gitconfig.signing" "Done: 5 file(s) would change."
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
