#!/bin/sh
#
# update.sh -- sync this dotfiles repo with $HOME, in either direction, and
# install or remove the programs it carries or knows where to fetch.
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
# Space-separated, compared literally against the repo-relative path. An entry
# that is a directory, like tests, leaves out everything below it.
#
# The .local files are here as empty stubs to copy by hand. A plain command
# must never deploy or collect them: deploying would overwrite whatever that
# machine keeps in them, and collecting would push one machine's overrides to
# all the others. Only the `local` prefix reaches them, and only on request.
EXCLUDES="update.sh tests README.md LICENSE .gitignore"
HAND_COPY_FILES=".bashrc.local .zshrc.local .gitconfig.local .gitconfig.signing"
EXCLUDES="$EXCLUDES $HAND_COPY_FILES"

# What `install` and `uninstall` know by name. Each is a clone of the
# repository it is published in, and they are the only thing here that uses
# the network.
KNOWN="mega2 tmux chemacs2"

# Oh my tmux!, the tmux config that the tracked .tmux.conf.local customizes.
OMT_URL="https://github.com/gpakosz/.tmux.git"
OMT_DIR="$HOME/.tmux"

# chemacs2, which starts Emacs on one of the profiles in ~/.emacs-profiles.el.
CHEMACS_URL="https://github.com/plexus/chemacs2.git"
CHEMACS_DIR="$HOME/.emacs.d"

# MEGA 2.0, the Emacs configuration that ~/.emacs-profiles.el names as the
# default profile. A clone of it is told from a clone of something else by
# the file MEGA2_FILE in it, which holds the text MEGA2_MARK.
MEGA2_URL="https://github.com/0xD503/mega2.git"
MEGA2_DIR="$HOME/.mega2.d"
MEGA2_FILE=lisp/mega-lib.el
MEGA2_MARK="(provide 'mega-lib)"
# Where MEGA keeps what it builds, and what it remembers.
case ${XDG_CACHE_HOME-} in
    /*) MEGA2_CACHE="$XDG_CACHE_HOME/mega2" ;;
    *)  MEGA2_CACHE="$HOME/.cache/mega2" ;;
esac
case ${XDG_STATE_HOME-} in
    /*) MEGA2_STATE="$XDG_STATE_HOME/mega2" ;;
    *)  MEGA2_STATE="$HOME/.local/state/mega2" ;;
esac

# Until MEGA 2.0 had a repository of its own it was a directory of this one:
# `install mega2` copied it file by file, and kept a list of what it had
# copied in here. Nothing is written here any more; what is found is cleared
# away by `install mega2` and `uninstall mega2`.
case ${XDG_STATE_HOME-} in
    /*) OLD_LISTS="$XDG_STATE_HOME/dotfiles" ;;
    *)  OLD_LISTS="$HOME/.local/state/dotfiles" ;;
esac

# A clone that is being made, to clear away if the script is stopped.
HALF_MADE=

usage() {
    cat <<EOF
usage: $PROG COMMAND [-n] [-f]
       $PROG install NAME... [-n] [-f]
       $PROG uninstall NAME... [-n] [-f]
       $PROG local {user|repo|diff|list} [-n] [-f]

commands:
  user       deploy: repo -> \$HOME      (existing files are backed up first)
  repo       collect: \$HOME -> repo     (git is the backup, so none is made)
  link       symlink \$HOME entries at the repo instead of copying (opt-in)
  diff       show what differs between repo and \$HOME; changes nothing
  list       print the managed files and exit
  install    install what is named, or bring it up to date
  uninstall  remove what is named
  local      prefix: run the next command on the per-machine files instead
  help       this text

what install and uninstall know, each fetched from where it is published:
  mega2      MEGA 2.0, the Emacs configuration, cloned into ~/.mega2.d
  chemacs2   the Emacs profile switcher, cloned into ~/.emacs.d
  tmux       Oh my tmux!, cloned into ~/.tmux, with ~/.tmux.conf linked to it

options:
  -n      dry run: print what would happen, touch nothing
  -f      skip backups when overwriting or removing

examples:
  ./$PROG user -n            preview a deploy
  ./$PROG install mega2      install MEGA 2.0, or update it
  ./$PROG uninstall mega2    remove it; your local.el stays
  ./$PROG diff               review drift before collecting
  ./$PROG repo               pull your live configs back into the repo
  ./$PROG local diff         compare this machine's .local files with the stubs

Backups go to \$HOME/.dotfiles-backup/<timestamp>/ mirroring the original
paths, so restoring is a plain copy back. That holds for what an uninstall
removes as well: it is moved there, not deleted.

'user' deploys what this repo tracks, and removes nothing from \$HOME. What
'install' knows is not in this repo: it is fetched, and only when it is
asked for by name.

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
            case $found in
                "$pattern" | "$pattern"/*) skip=1 ;;
            esac
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

# Deploy the managed file $1 into $HOME: back up what is there, copy, count.
install_file() {
    rel=$1
    src="$REPO_DIR/$rel"
    dst="$HOME/$rel"

    if [ -e "$dst" ] && [ ! -L "$dst" ] && cmp -s -- "$src" "$dst"; then
        return 0
    fi

    if [ -e "$dst" ] || [ -L "$dst" ]; then
        note "update  $rel"
    else
        note "create  $rel"
    fi

    backup_file "$dst" "$rel" || return 1
    copy_file "$src" "$dst" || return 1
    CHANGES=$((CHANGES + 1))
}

cmd_user() {
    msg "Installing into $HOME"
    while IFS= read -r rel; do
        install_file "$rel"
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

# --- install and uninstall: clones of what is published elsewhere ----------------

# Print where in $BACKUP_DIR the directory named $1 can be moved to: under its
# own name, or, should something of that name have been moved there within
# the same second, under that name and a number.
backup_place() {
    bp_to="$BACKUP_DIR/$1"
    bp_n=1
    while [ -e "$bp_to" ] || [ -L "$bp_to" ]; do
        bp_n=$((bp_n + 1))
        bp_to="$BACKUP_DIR/$1.$bp_n"
    done
    printf '%s\n' "$bp_to"
}

# Clone $2 into $3, or bring the clone that is there up to date. $1 names the
# thing for a person. A clone of it is told from a clone of something else by
# the file $4 in it, which holds the text $5.
clone_or_pull() {
    cop_what=$1 cop_url=$2 cop_dir=$3 cop_file=$4 cop_mark=$5

    if ! command -v git >/dev/null 2>&1; then
        fail "git is required"
        return 1
    fi

    if [ -d "$cop_dir/.git" ]; then
        # A clone of something else is not ours to pull.
        if ! grep -q -e "$cop_mark" "$cop_dir/$cop_file" 2>/dev/null; then
            fail "$cop_dir is a git clone, but not of $cop_what"
            return 1
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            # Ask the remote rather than fetch: a dry run writes nothing.
            if ! cop_remote=$(git -C "$cop_dir" ls-remote origin HEAD); then
                fail "cannot reach: $cop_url"
                return 1
            fi
            cop_remote=$(printf '%s\n' "$cop_remote" | cut -f1)
            if [ "$cop_remote" != "$(git -C "$cop_dir" rev-parse HEAD)" ]; then
                note "update  $cop_dir"
                CHANGES=$((CHANGES + 1))
            fi
        else
            cop_old=$(git -C "$cop_dir" rev-parse --short HEAD)
            if ! git -C "$cop_dir" pull --quiet --ff-only; then
                fail "cannot update: $cop_dir"
                return 1
            fi
            cop_new=$(git -C "$cop_dir" rev-parse --short HEAD)
            if [ "$cop_new" != "$cop_old" ]; then
                note "update  $cop_dir  ($cop_old..$cop_new)"
                CHANGES=$((CHANGES + 1))
            fi
        fi
    elif [ -e "$cop_dir" ] || [ -L "$cop_dir" ]; then
        fail "$cop_dir exists and is not a git clone; move it aside first"
        return 1
    else
        note "clone   $cop_url"
        if [ "$DRY_RUN" -eq 0 ] &&
            ! git clone --quiet --single-branch -- "$cop_url" "$cop_dir"; then
            fail "cannot clone: $cop_url"
            return 1
        fi
        CHANGES=$((CHANGES + 1))
    fi
    return 0
}

# Take the clone of $1 in $2 away again; $3 and $4 tell it from a clone of
# something else, as for clone_or_pull. It is moved to where backups go, with
# whatever was put into it since, unless backups were declined. Fails, having
# said why, if what is there is not that clone; returns 2 if nothing is there.
clone_remove() {
    cr_what=$1 cr_dir=$2 cr_file=$3 cr_mark=$4

    if [ ! -e "$cr_dir" ] && [ ! -L "$cr_dir" ]; then
        return 2
    fi
    if [ ! -d "$cr_dir/.git" ] ||
        ! grep -q -e "$cr_mark" "$cr_dir/$cr_file" 2>/dev/null; then
        fail "$cr_dir is not a clone of $cr_what; it is left alone"
        return 1
    fi
    note "remove  $cr_dir"
    CHANGES=$((CHANGES + 1))
    [ "$DRY_RUN" -eq 1 ] && return 0
    if [ "$NO_BACKUP" -eq 1 ]; then
        rm -rf -- "$cr_dir" || { fail "cannot remove: $cr_dir"; return 1; }
    else
        cr_kept=$(backup_place "$(basename -- "$cr_dir")")
        if ! mkdir -p -- "$BACKUP_DIR" || ! mv -- "$cr_dir" "$cr_kept"; then
            fail "cannot move $cr_dir to $cr_kept"
            return 1
        fi
    fi
    return 0
}

# Install Oh my tmux! the way upstream documents for ~: a clone in ~/.tmux, and
# ~/.tmux.conf linked into it. Running it again updates the clone. Upstream's
# .tmux.conf.local template is not copied; `user` deploys this repo's instead.
cmd_install_tmux() {
    msg "Installing Oh my tmux! into $OMT_DIR"

    command -v git >/dev/null 2>&1 || { fail "git is required"; return 1; }
    command -v tmux >/dev/null 2>&1 ||
        note "tmux is not installed; Oh my tmux! takes effect once it is"

    clone_or_pull "Oh my tmux!" "$OMT_URL" "$OMT_DIR" .tmux.conf 'gpakosz/\.tmux' ||
        return 1

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

# The clone goes, and the link into it. ~/.tmux.conf.local is this repo's
# file, deployed by `user`, and stays.
cmd_uninstall_tmux() {
    msg "Removing Oh my tmux! from $OMT_DIR"

    tmux_conf="$HOME/.tmux.conf"
    tmux_link=$(readlink -- "$tmux_conf" 2>/dev/null) || tmux_link=
    clone_remove "Oh my tmux!" "$OMT_DIR" .tmux.conf 'gpakosz/\.tmux'
    case $? in
        0) ;;
        2) note "nothing at $OMT_DIR" ;;
        *) return 1 ;;
    esac
    case $tmux_link in
        "$OMT_DIR/.tmux.conf" | .tmux/.tmux.conf)
            note "remove  .tmux.conf"
            CHANGES=$((CHANGES + 1))
            if [ "$DRY_RUN" -eq 0 ] && ! rm -f -- "$tmux_conf"; then
                fail "cannot remove: $tmux_conf"
                return 1
            fi
            ;;
    esac
}

# chemacs2 is ~/.emacs.d itself: Emacs starts it, and it starts the profile
# that ~/.emacs-profiles.el names. An ~/.emacs.d that is something else, a
# configuration of yours, is never touched.
cmd_install_chemacs2() {
    msg "Installing chemacs2 into $CHEMACS_DIR"

    clone_or_pull chemacs2 "$CHEMACS_URL" "$CHEMACS_DIR" chemacs.el chemacs ||
        return 1

    if [ ! -e "$HOME/.emacs-profiles.el" ]; then
        note "no ~/.emacs-profiles.el yet: '$PROG user' installs this repo's copy"
    fi
}

cmd_uninstall_chemacs2() {
    msg "Removing chemacs2 from $CHEMACS_DIR"

    clone_remove chemacs2 "$CHEMACS_DIR" chemacs.el chemacs
    case $? in
        0) ;;
        2) note "nothing at $CHEMACS_DIR"; return 0 ;;
        *) return 1 ;;
    esac
    note "~/.emacs-profiles.el is this repo's file and stays; without chemacs2,"
    note "start a profile yourself:  emacs --init-directory $MEGA2_DIR"
}

# --- MEGA 2.0 ------------------------------------------------------------------

# Say what is at $MEGA2_DIR:
#   nothing
#   clone    a clone of MEGA 2.0
#   copy     a directory that is no clone: MEGA as this script copied it when
#            it was a directory of this repo, or what an uninstall left of
#            it, or what an Emacs wrote there that chemacs2 started on the
#            profile while MEGA was away
#   other    anything else: a link, a file, a clone of something else
mega2_found() {
    if [ -L "$MEGA2_DIR" ]; then
        printf 'other\n'
    elif [ ! -e "$MEGA2_DIR" ]; then
        printf 'nothing\n'
    elif [ ! -d "$MEGA2_DIR" ]; then
        printf 'other\n'
    elif [ ! -e "$MEGA2_DIR/.git" ]; then
        printf 'copy\n'
    elif [ -d "$MEGA2_DIR/.git" ] &&
        grep -q -e "$MEGA2_MARK" "$MEGA2_DIR/$MEGA2_FILE" 2>/dev/null; then
        printf 'clone\n'
    else
        printf 'other\n'
    fi
}

mega2_has_local() {
    [ -e "$MEGA2_DIR/local.el" ] || [ -L "$MEGA2_DIR/local.el" ]
}

# Succeed if nothing is in $MEGA2_DIR, or nothing but local.el.
mega2_bare() {
    [ -z "$(ls -A -- "$MEGA2_DIR" 2>/dev/null | grep -v -x -F -e local.el)" ]
}

# Move $MEGA2_DIR out of the way: to where backups go, with whatever was put
# into it, or to nowhere if backups were declined. Its local.el is yours and
# does not go along: it waits in $MEGA2_KEPT, beside the directory, for
# mega2_put_back.
mega2_put_aside() {
    MEGA2_KEPT=
    if mega2_has_local; then
        MEGA2_KEPT="$MEGA2_DIR.local.el.$$"
        if ! mv -- "$MEGA2_DIR/local.el" "$MEGA2_KEPT"; then
            fail "cannot move: $MEGA2_DIR/local.el"
            MEGA2_KEPT=
            return 1
        fi
    fi
    # Nothing else in it: there is nothing to keep.
    rmdir -- "$MEGA2_DIR" 2>/dev/null && return 0
    if [ "$NO_BACKUP" -eq 1 ]; then
        if ! rm -rf -- "$MEGA2_DIR"; then
            fail "cannot remove: $MEGA2_DIR"
            mega2_put_back
            return 1
        fi
    else
        mpa_to=$(backup_place "$(basename -- "$MEGA2_DIR")")
        if ! mkdir -p -- "$BACKUP_DIR" || ! mv -- "$MEGA2_DIR" "$mpa_to"; then
            fail "cannot move $MEGA2_DIR to $mpa_to"
            mega2_put_back
            return 1
        fi
    fi
    return 0
}

# Put the local.el that mega2_put_aside kept into $MEGA2_DIR.
mega2_put_back() {
    [ -n "$MEGA2_KEPT" ] || return 0
    if ! mkdir -p -- "$MEGA2_DIR" ||
        ! mv -- "$MEGA2_KEPT" "$MEGA2_DIR/local.el"; then
        fail "cannot put your local.el back into $MEGA2_DIR; it is at $MEGA2_KEPT"
        return 1
    fi
    MEGA2_KEPT=
    return 0
}

# Clear away the list that was kept of a copy, and the mark of its uninstall.
mega2_forget_lists() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    rm -f -- "$OLD_LISTS/mega2.files" "$OLD_LISTS/mega2.removed"
    rmdir -- "$OLD_LISTS" 2>/dev/null
    return 0
}

# Put a clone where a copy is. The clone is made first, beside it, so that a
# network that is down leaves the copy as it was.
mega2_replace_copy() {
    if ! command -v git >/dev/null 2>&1; then
        fail "git is required"
        return 1
    fi

    if ! mega2_bare; then
        note "replace $MEGA2_DIR  (not a clone; one takes its place)"
        CHANGES=$((CHANGES + 1))
    fi
    note "clone   $MEGA2_URL"
    CHANGES=$((CHANGES + 1))
    mega2_has_local && note "kept    $MEGA2_DIR/local.el  (yours)"
    [ "$DRY_RUN" -eq 1 ] && return 0

    HALF_MADE="$MEGA2_DIR.new.$$"
    if ! git clone --quiet --single-branch -- "$MEGA2_URL" "$HALF_MADE"; then
        rm -rf -- "$HALF_MADE"
        HALF_MADE=
        fail "cannot clone: $MEGA2_URL; $MEGA2_DIR is as it was"
        return 1
    fi
    if ! mega2_put_aside; then
        rm -rf -- "$HALF_MADE"
        HALF_MADE=
        return 1
    fi
    if ! mv -- "$HALF_MADE" "$MEGA2_DIR"; then
        fail "cannot move $HALF_MADE to $MEGA2_DIR"
        [ -n "$MEGA2_KEPT" ] && warn "your local.el is at $MEGA2_KEPT"
        HALF_MADE=
        return 1
    fi
    HALF_MADE=
    mega2_put_back
}

# MEGA 2.0 is ~/.mega2.d itself: a clone, which Emacs is pointed at by
# chemacs2 or by --init-directory. Running this again updates the clone. Its
# git ignores local.el, which is yours, so an update never touches that.
#
# A ~/.mega2.d that is not a clone is replaced by one; see mega2_found for
# what that may be. What was there is moved to where backups go, and its
# local.el is carried over.
cmd_install_mega2() {
    msg "Installing MEGA 2.0 into $MEGA2_DIR"
    cim_before=$CHANGES
    cim_found=$(mega2_found)
    # Nothing of MEGA is there yet: at most a local.el that waited for it.
    cim_new=0
    if [ "$cim_found" = nothing ] || { [ "$cim_found" = copy ] && mega2_bare; }; then
        cim_new=1
    fi

    if [ -L "$MEGA2_DIR" ]; then
        fail "$MEGA2_DIR is a link; what it points at is yours to update"
        return 1
    fi
    if [ "$cim_found" = copy ]; then
        mega2_replace_copy || return 1
    else
        # This refuses what is neither nothing nor a clone of MEGA.
        clone_or_pull "MEGA 2.0" "$MEGA2_URL" "$MEGA2_DIR" \
            "$MEGA2_FILE" "$MEGA2_MARK" || return 1
    fi
    mega2_forget_lists

    [ "$CHANGES" -gt "$cim_before" ] || return 0
    [ "$DRY_RUN" -eq 0 ] || return 0
    if [ "$cim_new" -eq 1 ]; then
        if [ -f "$CHEMACS_DIR/chemacs.el" ]; then
            [ -e "$HOME/.emacs-profiles.el" ] ||
                note "no ~/.emacs-profiles.el yet: '$PROG user' installs this repo's copy"
        else
            note "start it with:  emacs --init-directory $MEGA2_DIR"
            note "or have plain 'emacs' start it:  $PROG install chemacs2"
        fi
    else
        note "an Emacs that is running goes on with what it loaded: restart it"
    fi
}

# The directory goes, to where backups go, with whatever was put into it;
# your local.el stays where it is. What MEGA built for itself goes too, and
# is built again when needed. What it remembers stays: your history, your
# undo, and its backups of your files are yours to delete.
cmd_uninstall_mega2() {
    msg "Removing MEGA 2.0 from $MEGA2_DIR"

    if [ -L "$MEGA2_DIR" ]; then
        fail "$MEGA2_DIR is a link; what it points at is yours to remove"
        return 1
    fi
    case $(mega2_found) in
        nothing)
            note "nothing at $MEGA2_DIR"
            ;;
        other)
            fail "$MEGA2_DIR is not a clone of MEGA 2.0; it is left alone"
            return 1
            ;;
        *)
            if mega2_bare; then
                if mega2_has_local; then
                    note "nothing at $MEGA2_DIR but your local.el"
                else
                    note "nothing at $MEGA2_DIR"
                    [ "$DRY_RUN" -eq 1 ] || rmdir -- "$MEGA2_DIR" 2>/dev/null
                fi
            else
                note "remove  $MEGA2_DIR"
                CHANGES=$((CHANGES + 1))
                mega2_has_local && note "kept    $MEGA2_DIR/local.el  (yours)"
                if [ "$DRY_RUN" -eq 0 ]; then
                    mega2_put_aside || return 1
                    mega2_put_back || return 1
                fi
            fi
            ;;
    esac

    for cum_built in compiled eln; do
        [ -d "$MEGA2_CACHE/$cum_built" ] || continue
        note "remove  $MEGA2_CACHE/$cum_built  (built by MEGA, which builds it again)"
        CHANGES=$((CHANGES + 1))
        if [ "$DRY_RUN" -eq 0 ] && ! rm -rf -- "$MEGA2_CACHE/$cum_built"; then
            fail "cannot remove: $MEGA2_CACHE/$cum_built"
        fi
    done
    mega2_forget_lists

    if [ -d "$MEGA2_STATE" ] || [ -d "$MEGA2_CACHE" ]; then
        note "kept    what MEGA remembers, and its backups of your files:"
        note "        $MEGA2_STATE  $MEGA2_CACHE"
    fi
    # chemacs2 would go on starting Emacs there, without a configuration.
    if grep -F -q -e "/$(basename -- "$MEGA2_DIR")\"" "$HOME/.emacs-profiles.el" 2>/dev/null; then
        note "~/.emacs-profiles.el still names ~/$(basename -- "$MEGA2_DIR") as a profile"
    fi
}

# MEGA 2.0 used to be deployed by `user`, as a directory of this repo. A copy
# from then is brought up to date by nothing any more: say what does it.
mega2_hint_copy() {
    [ "$HAND_COPY" -eq 0 ] || return 0
    [ "$(mega2_found)" = copy ] || return 0
    [ -f "$MEGA2_DIR/$MEGA2_FILE" ] || return 0
    msg "note: $MEGA2_DIR is a copy from when MEGA 2.0 was part of this repo;"
    msg "      '$PROG install mega2' replaces it by a clone, which can be updated"
}

# Print the names `install` and `uninstall` take.
names() {
    printf '%s\n' "$KNOWN"
}

known_name() {
    for kn_name in $KNOWN; do
        [ "$kn_name" = "$1" ] && return 0
    done
    return 1
}

cmd_install() {
    for ci_name in $NAMES; do
        case $ci_name in
            mega2)    cmd_install_mega2 ;;
            tmux)     cmd_install_tmux ;;
            chemacs2) cmd_install_chemacs2 ;;
        esac
    done
}

cmd_uninstall() {
    for ci_name in $NAMES; do
        case $ci_name in
            mega2)    cmd_uninstall_mega2 ;;
            tmux)     cmd_uninstall_tmux ;;
            chemacs2) cmd_uninstall_chemacs2 ;;
        esac
    done
}

# --- argument parsing -------------------------------------------------------

[ $# -ge 1 ] || { warn "no command given"; usage >&2; exit 2; }

COMMAND=$1
shift
NAMES=

# The old name of `install tmux`.
if [ "$COMMAND" = tmux ]; then
    COMMAND=install
    NAMES=tmux
fi

# `install` and `uninstall` take the names of what to act on.
if { [ "$COMMAND" = install ] || [ "$COMMAND" = uninstall ]; } && [ -z "$NAMES" ]; then
    while [ $# -gt 0 ]; do
        case $1 in
            -*) break ;;
        esac
        if ! known_name "$1"; then
            warn "$COMMAND knows nothing called '$1'; it knows: $(names)"
            exit 2
        fi
        NAMES="$NAMES $1"
        shift
    done
    if [ -z "$NAMES" ]; then
        warn "$COMMAND what? One or more of: $(names)"
        exit 2
    fi
fi

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
    user | repo | link | diff | list | install | uninstall) ;;
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
cleanup() {
    rm -f -- "$FILE_LIST" "$FILE_LIST".*
    if [ -n "$HALF_MADE" ]; then
        rm -rf -- "$HALF_MADE"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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
    user)      cmd_user ;;
    repo)      cmd_repo ;;
    link)      cmd_link ;;
    diff)      cmd_diff ;;
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
esac

if [ "$COMMAND" = user ] || [ "$COMMAND" = link ]; then
    hint_untracked
    mega2_hint_copy
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
