#!/bin/sh
#
# update.sh -- sync this dotfiles repo with $HOME, in either direction.
#
# The managed file list is DISCOVERED, not hardcoded: it is the git index minus
# this script and the repo metadata. Track a new config and it is deployed on
# the next run -- there is no list here to keep in sync.
#
# Portability: POSIX sh only. No arrays, no [[ ]], no `local`, no `function`
# keyword, no `echo -e`, no `readlink -f`, no GNU-only flags. Verified with
# `shellcheck -s sh`. Runs under dash, ash, ksh, bash and zsh.

set -u

PROG=$(basename -- "$0")
REPO_DIR=$(cd -- "$(dirname -- "$0")" && pwd) || exit 1

DRY_RUN=0
NO_BACKUP=0
HAND_COPY=0
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
ERRORS=0
CHANGES=0

# Files that live in the repo but are not configuration to deploy.
# Space-separated, compared literally against the repo-relative path.
#
# The .local files are here as empty stubs to copy by hand. A plain command
# must never deploy or collect them: deploying would overwrite whatever that
# machine keeps in them, and collecting would push one machine's overrides to
# all the others. Only the `local` prefix reaches them, and only on request.
EXCLUDES="update.sh README.md LICENSE .gitignore"
HAND_COPY_FILES=".bashrc.local .zshrc.local .mega.d/local.el .gitconfig.local \
.gitconfig.signing"
EXCLUDES="$EXCLUDES $HAND_COPY_FILES"

# Oh my tmux!, the tmux config that the tracked .tmux.conf.local customizes.
OMT_URL="https://github.com/gpakosz/.tmux.git"
OMT_DIR="$HOME/.tmux"

usage() {
    cat <<EOF
usage: $PROG COMMAND [-n] [-f]
       $PROG local {user|repo|diff|list} [-n] [-f]

commands:
  user    install: repo -> \$HOME       (existing files are backed up first)
  repo    collect: \$HOME -> repo       (git is the backup, so none is made)
  link    symlink \$HOME entries at the repo instead of copying (opt-in)
  diff    show what differs between repo and \$HOME; changes nothing
  list    print the managed files and exit
  tmux    install Oh my tmux! into ~/.tmux, or update it
  local   prefix: run the next command on the per-machine files instead
  help    this text

options:
  -n      dry run: print what would happen, touch nothing
  -f      skip backups when overwriting (user/link/tmux only)

examples:
  ./$PROG user -n     preview an install
  ./$PROG diff        review drift before collecting
  ./$PROG repo        pull your live configs back into the repo
  ./$PROG local diff  compare this machine's .local files with the stubs

Backups go to \$HOME/.dotfiles-backup/<timestamp>/ mirroring the original
paths, so restoring is a plain copy back.

The per-machine files ('$PROG local list') differ from host to host on
purpose, so every command skips them unless it is prefixed with 'local'.
EOF
}

msg()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
fail() { warn "$*"; ERRORS=$((ERRORS + 1)); }

have_git() {
    command -v git >/dev/null 2>&1 &&
        git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Drop repo metadata and editor debris from a list of paths on stdin.
filter_managed() {
    while IFS= read -r found; do
        found=${found#./}
        # An index entry whose file is gone (staged deletion) is not deployable.
        [ -f "$found" ] || continue
        skip=0
        for pattern in $EXCLUDES; do
            [ "$found" = "$pattern" ] && skip=1
        done
        [ "$skip" -eq 1 ] && continue
        case $found in
            *'~' | *.orig | *.rej | *.bak | *.swp) continue ;;
        esac
        printf '%s\n' "$found"
    done | sort
}

# Print every managed file, one repo-relative path per line.
#
# The git index is the source of truth: a config is deployed once it is
# tracked, so untracked scratch files are never installed into $HOME. Falls
# back to a filesystem scan when the repo is used outside git.
#
# Under `local` the list is the hand-copied files instead, and nothing else.
list_files() {
    if [ "$HAND_COPY" -eq 1 ]; then
        for found in $HAND_COPY_FILES; do
            [ -f "$found" ] || continue
            printf '%s\n' "$found"
        done
        return 0
    fi
    if have_git; then
        git ls-files -z | tr '\0' '\n'
    else
        find . -path ./.git -prune -o -type f -print 2>/dev/null
    fi | filter_managed
}

# A new config that was never `git add`ed would be skipped without a word.
# Say so once, rather than letting it look deployed.
hint_untracked() {
    [ "$HAND_COPY" -eq 0 ] || return 0
    have_git || return 0
    untracked=$(git ls-files --others --exclude-standard -z | tr '\0' '\n' |
        filter_managed | tr '\n' ' ')
    [ -n "$untracked" ] || return 0
    msg "note: untracked, so not deployed: $untracked"
    msg "      'git add' them to have update.sh manage them"
}

# Copy $1 to $2, creating parent directories. Honours dry run.
copy_file() {
    copy_src=$1
    copy_dst=$2
    copy_dir=$(dirname -- "$copy_dst")

    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi

    if [ ! -d "$copy_dir" ] && ! mkdir -p -- "$copy_dir"; then
        fail "cannot create directory: $copy_dir"
        return 1
    fi

    # Never write through a symlink: after `link`, that would copy the file
    # onto itself through the repo and silently corrupt the source.
    if [ -L "$copy_dst" ] && ! rm -f -- "$copy_dst"; then
        fail "cannot replace symlink: $copy_dst"
        return 1
    fi

    if ! cp -p -- "$copy_src" "$copy_dst"; then
        fail "cannot copy: $copy_src -> $copy_dst"
        return 1
    fi
    return 0
}

# Preserve an existing $HOME file before it is overwritten.
backup_file() {
    backup_src=$1
    backup_rel=$2

    [ "$NO_BACKUP" -eq 1 ] && return 0
    # A symlink holds no content of its own; there is nothing to lose.
    [ -L "$backup_src" ] && return 0
    [ -e "$backup_src" ] || return 0
    [ "$DRY_RUN" -eq 1 ] && return 0

    backup_dst="$BACKUP_DIR/$backup_rel"
    if ! mkdir -p -- "$(dirname -- "$backup_dst")"; then
        fail "cannot create backup directory for: $backup_rel"
        return 1
    fi
    if ! cp -p -- "$backup_src" "$backup_dst"; then
        fail "cannot back up: $backup_src"
        return 1
    fi
    return 0
}

cmd_user() {
    msg "Installing into $HOME"
    while IFS= read -r rel; do
        src="$REPO_DIR/$rel"
        dst="$HOME/$rel"

        if [ -e "$dst" ] && [ ! -L "$dst" ] && cmp -s -- "$src" "$dst"; then
            continue
        fi

        if [ -e "$dst" ] || [ -L "$dst" ]; then
            note "update  $rel"
        else
            note "create  $rel"
        fi

        backup_file "$dst" "$rel" || continue
        copy_file "$src" "$dst" || continue
        CHANGES=$((CHANGES + 1))
    done < "$FILE_LIST"
}

cmd_repo() {
    msg "Collecting from $HOME"
    while IFS= read -r rel; do
        src="$HOME/$rel"
        dst="$REPO_DIR/$rel"

        if [ ! -f "$src" ]; then
            note "absent  $rel  (not in \$HOME, skipped)"
            continue
        fi
        if cmp -s -- "$src" "$dst"; then
            continue
        fi

        note "update  $rel"
        copy_file "$src" "$dst" || continue
        CHANGES=$((CHANGES + 1))
    done < "$FILE_LIST"
}

cmd_link() {
    msg "Linking $HOME at $REPO_DIR"
    while IFS= read -r rel; do
        src="$REPO_DIR/$rel"
        dst="$HOME/$rel"
        dst_dir=$(dirname -- "$dst")

        note "link    $rel"
        [ "$DRY_RUN" -eq 1 ] && continue

        if [ ! -d "$dst_dir" ] && ! mkdir -p -- "$dst_dir"; then
            fail "cannot create directory: $dst_dir"
            continue
        fi
        backup_file "$dst" "$rel" || continue
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            rm -f -- "$dst" || { fail "cannot remove: $dst"; continue; }
        fi
        if ! ln -s -- "$src" "$dst"; then
            fail "cannot link: $dst"
            continue
        fi
        CHANGES=$((CHANGES + 1))
    done < "$FILE_LIST"
}

cmd_diff() {
    while IFS= read -r rel; do
        src="$REPO_DIR/$rel"
        dst="$HOME/$rel"

        if [ ! -e "$dst" ]; then
            msg "--- $rel: missing in \$HOME"
            CHANGES=$((CHANGES + 1))
            continue
        fi
        if cmp -s -- "$src" "$dst"; then
            continue
        fi
        msg "--- $rel"
        diff -u -- "$src" "$dst" || true
        CHANGES=$((CHANGES + 1))
    done < "$FILE_LIST"

    if [ "$CHANGES" -eq 0 ]; then
        msg "repo and \$HOME are identical"
    fi
}

# Install Oh my tmux! the way upstream documents for ~: a clone in ~/.tmux, and
# ~/.tmux.conf linked into it. Running it again updates the clone. Upstream's
# .tmux.conf.local template is not copied; `user` deploys this repo's instead.
cmd_tmux() {
    msg "Installing Oh my tmux! into $OMT_DIR"

    if ! command -v git >/dev/null 2>&1; then
        fail "git is required"
        return 1
    fi
    command -v tmux >/dev/null 2>&1 ||
        note "tmux is not installed; Oh my tmux! takes effect once it is"

    if [ -d "$OMT_DIR/.git" ]; then
        # A ~/.tmux clone of something else is not ours to pull.
        if ! grep -q 'gpakosz/\.tmux' "$OMT_DIR/.tmux.conf" 2>/dev/null; then
            fail "$OMT_DIR is a git clone, but not of Oh my tmux!"
            return 1
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            # Ask the remote rather than fetch: a dry run writes nothing.
            if ! tmux_remote=$(git -C "$OMT_DIR" ls-remote origin HEAD); then
                fail "cannot reach: $OMT_URL"
                return 1
            fi
            tmux_remote=$(printf '%s\n' "$tmux_remote" | cut -f1)
            if [ "$tmux_remote" != "$(git -C "$OMT_DIR" rev-parse HEAD)" ]; then
                note "update  $OMT_DIR"
                CHANGES=$((CHANGES + 1))
            fi
        else
            tmux_old=$(git -C "$OMT_DIR" rev-parse --short HEAD)
            if ! git -C "$OMT_DIR" pull --quiet --ff-only; then
                fail "cannot update: $OMT_DIR"
                return 1
            fi
            tmux_new=$(git -C "$OMT_DIR" rev-parse --short HEAD)
            if [ "$tmux_new" != "$tmux_old" ]; then
                note "update  $OMT_DIR  ($tmux_old..$tmux_new)"
                CHANGES=$((CHANGES + 1))
            fi
        fi
    elif [ -e "$OMT_DIR" ] || [ -L "$OMT_DIR" ]; then
        fail "$OMT_DIR exists and is not a git clone; move it aside first"
        return 1
    else
        note "clone   $OMT_URL"
        if [ "$DRY_RUN" -eq 0 ] &&
            ! git clone --quiet --single-branch -- "$OMT_URL" "$OMT_DIR"; then
            fail "cannot clone: $OMT_URL"
            return 1
        fi
        CHANGES=$((CHANGES + 1))
    fi

    tmux_conf="$HOME/.tmux.conf"
    tmux_link=$(readlink -- "$tmux_conf" 2>/dev/null) || tmux_link=
    case $tmux_link in
        # the second form is what upstream's manual install creates
        "$OMT_DIR/.tmux.conf" | .tmux/.tmux.conf) ;;
        *)
            note "link    .tmux.conf"
            backup_file "$tmux_conf" .tmux.conf || return 1
            if [ "$DRY_RUN" -eq 0 ]; then
                if [ -e "$tmux_conf" ] || [ -L "$tmux_conf" ]; then
                    rm -f -- "$tmux_conf" ||
                        { fail "cannot remove: $tmux_conf"; return 1; }
                fi
                if ! ln -s -- "$OMT_DIR/.tmux.conf" "$tmux_conf"; then
                    fail "cannot link: $tmux_conf"
                    return 1
                fi
            fi
            CHANGES=$((CHANGES + 1))
            ;;
    esac

    if [ ! -e "$HOME/.tmux.conf.local" ]; then
        note "no ~/.tmux.conf.local yet: '$PROG user' installs this repo's copy"
    fi
}

# --- argument parsing -------------------------------------------------------

[ $# -ge 1 ] || { warn "no command given"; usage >&2; exit 2; }

COMMAND=$1
shift

# `local` is a prefix: the command after it acts on HAND_COPY_FILES instead.
if [ "$COMMAND" = local ]; then
    HAND_COPY=1
    COMMAND=${1-}
    [ $# -gt 0 ] && shift
    case $COMMAND in
        user | repo | diff | list) ;;
        *) warn "local takes one of: user, repo, diff, list"; usage >&2; exit 2 ;;
    esac
fi

while [ $# -gt 0 ]; do
    case $1 in
        -n | --dry-run) DRY_RUN=1 ;;
        -f | --force)   NO_BACKUP=1 ;;
        -h | --help)    usage; exit 0 ;;
        --)             shift; break ;;
        -*)             warn "unknown option: $1"; usage >&2; exit 2 ;;
        *)              warn "unexpected argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
done

case $COMMAND in
    user | repo | link | diff | list | tmux) ;;
    -h | --help | help) usage; exit 0 ;;
    *) warn "unknown command: $COMMAND"; usage >&2; exit 2 ;;
esac

# --- run --------------------------------------------------------------------

cd -- "$REPO_DIR" || { warn "cannot enter repo: $REPO_DIR"; exit 1; }

if [ "$COMMAND" = list ]; then
    list_files
    hint_untracked
    exit 0
fi

# The file list goes through a temp file, not a pipe: a piped `while` loop runs
# in a subshell, where the change and error counters would be lost.
FILE_LIST="${TMPDIR:-/tmp}/.dotfiles-list.$$"
trap 'rm -f -- "$FILE_LIST"' EXIT
trap 'rm -f -- "$FILE_LIST"; exit 130' INT
trap 'rm -f -- "$FILE_LIST"; exit 143' TERM

set -C  # refuse to clobber an existing file, in case /tmp is hostile
if ! list_files > "$FILE_LIST"; then
    warn "cannot build file list at $FILE_LIST"
    exit 1
fi
set +C

if [ ! -s "$FILE_LIST" ]; then
    warn "no managed files found in $REPO_DIR"
    exit 1
fi

[ "$DRY_RUN" -eq 1 ] && msg "(dry run -- nothing will be written)"

case $COMMAND in
    user) cmd_user ;;
    repo) cmd_repo ;;
    link) cmd_link ;;
    diff) cmd_diff ;;
    tmux) cmd_tmux ;;
esac

if [ "$COMMAND" = user ] || [ "$COMMAND" = link ]; then
    hint_untracked
fi

if [ "$COMMAND" != diff ]; then
    if [ "$CHANGES" -eq 0 ]; then
        [ "$ERRORS" -eq 0 ] && msg "Already up to date."
    elif [ "$DRY_RUN" -eq 1 ]; then
        msg "Done: $CHANGES file(s) would change."
    else
        msg "Done: $CHANGES file(s) changed."
        if [ "$COMMAND" != repo ] && [ "$NO_BACKUP" -eq 0 ] && [ -d "$BACKUP_DIR" ]; then
            msg "Backup: $BACKUP_DIR"
        fi
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    warn "$ERRORS error(s)"
    exit 1
fi
exit 0
