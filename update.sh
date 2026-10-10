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
HAND_COPY_FILES=".bashrc.local .zshrc.local .mega.d/local.el .mega2.d/local.el \
.gitconfig.local .gitconfig.signing"
EXCLUDES="$EXCLUDES $HAND_COPY_FILES"

# Oh my tmux!, the tmux config that the tracked .tmux.conf.local customizes.
OMT_URL="https://github.com/gpakosz/.tmux.git"
OMT_DIR="$HOME/.tmux"

# chemacs2, which starts Emacs on one of the profiles in ~/.emacs-profiles.el.
CHEMACS_URL="https://github.com/plexus/chemacs2.git"
CHEMACS_DIR="$HOME/.emacs.d"

# What `install` and `uninstall` know by name.
#
# A tree is a program that is a directory of this repo, as NAME:DIRECTORY.
# Installing one makes the directory in $HOME hold these files and no file
# that an earlier version of it left behind; so, per tree, the list of what
# was installed is kept in $STATE_DIR/NAME.files. A tree that was uninstalled
# is marked by $STATE_DIR/NAME.removed, and `user` then leaves it alone.
#
# A clone is fetched from where it is published, and is the only thing here
# that uses the network.
TREES="mega2:.mega2.d mega:.mega.d"
CLONES="tmux chemacs2"
case ${XDG_STATE_HOME-} in
    /*) STATE_DIR="$XDG_STATE_HOME/dotfiles" ;;
    *)  STATE_DIR="$HOME/.local/state/dotfiles" ;;
esac

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

what install and uninstall know:
  mega2      MEGA 2.0, in ~/.mega2.d: exactly the files of this repo
  mega       MEGA 1, in ~/.mega.d, likewise
  chemacs2   the Emacs profile switcher, cloned into ~/.emacs.d
  tmux       Oh my tmux!, cloned into ~/.tmux, with ~/.tmux.conf linked to it

options:
  -n      dry run: print what would happen, touch nothing
  -f      skip backups when overwriting or removing

examples:
  ./$PROG user -n            preview a deploy
  ./$PROG install mega2      install MEGA 2.0, or update it, and nothing else
  ./$PROG uninstall mega2    remove it; 'user' then leaves it alone
  ./$PROG diff               review drift before collecting
  ./$PROG repo               pull your live configs back into the repo
  ./$PROG local diff         compare this machine's .local files with the stubs

Backups go to \$HOME/.dotfiles-backup/<timestamp>/ mirroring the original
paths, so restoring is a plain copy back. That holds for what an update or
an uninstall removes as well.

'user' deploys everything the repo tracks, mega2 and mega included, unless
one was uninstalled. For those two it also removes the files an earlier
version installed and this one no longer has, so an update leaves nothing
stale behind; nothing else in \$HOME is ever removed by it.

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

# --- trees: programs that are a directory of this repo -----------------------

# Print the directory of the tree named $1; fail if there is no such tree.
tree_dir() {
    for td_entry in $TREES; do
        case $td_entry in
            "$1":*) printf '%s\n' "${td_entry#*:}"; return 0 ;;
        esac
    done
    return 1
}

# Print the name of the tree that the repo-relative path $1 is part of; fail
# if it is part of none.
tree_of() {
    for to_entry in $TREES; do
        case $1 in
            "${to_entry#*:}"/*) printf '%s\n' "${to_entry%%:*}"; return 0 ;;
        esac
    done
    return 1
}

tree_removed() {
    [ -e "$STATE_DIR/$1.removed" ]
}

# Print the managed files of the tree in directory $1, from $FILE_LIST.
tree_files() {
    while IFS= read -r tf_rel; do
        case $tf_rel in
            "$1"/*) printf '%s\n' "$tf_rel" ;;
        esac
    done < "$FILE_LIST"
}

# Remove $HOME/$1, a file some version of a tree installed, backing it up
# first; then the directories that this leaves empty, up to but not including
# the tree's own, $2.
tree_remove_file() {
    trf_rel=$1
    # A list is a file in $HOME, and anybody may have written to it: nothing
    # outside the tree is removed on its word, and nothing through "..".
    case $trf_rel in
        "$2"/*) ;;
        *) return 0 ;;
    esac
    case /$trf_rel/ in
        */../*) return 0 ;;
    esac
    if [ ! -e "$HOME/$trf_rel" ] && [ ! -L "$HOME/$trf_rel" ]; then
        return 0
    fi
    note "remove  $trf_rel"
    CHANGES=$((CHANGES + 1))
    [ "$DRY_RUN" -eq 1 ] && return 0
    backup_file "$HOME/$trf_rel" "$trf_rel" || return 1
    if ! rm -f -- "$HOME/$trf_rel"; then
        fail "cannot remove: $HOME/$trf_rel"
        return 1
    fi
    trf_dir=$(dirname -- "$trf_rel")
    while [ "$trf_dir" != "$2" ] && [ "$trf_dir" != . ] && [ "$trf_dir" != / ]; do
        rmdir -- "$HOME/$trf_dir" 2>/dev/null || break
        trf_dir=$(dirname -- "$trf_dir")
    done
    return 0
}

# Finish installing the tree named $1, whose files $FILE_LIST names: remove
# from $HOME what the last version installed and this one no longer has, and
# write down what this one installed.
tree_settle() {
    ts_name=$1
    ts_dir=$(tree_dir "$ts_name") || return 1
    ts_list="$STATE_DIR/$ts_name.files"
    ts_new="$FILE_LIST.$ts_name"

    tree_files "$ts_dir" > "$ts_new"
    # A repo without this tree says nothing about what should be in $HOME.
    # Taking a tree away is what `uninstall` is for, and only that.
    if [ ! -s "$ts_new" ]; then
        rm -f -- "$ts_new"
        return 0
    fi

    if [ -f "$ts_list" ]; then
        while IFS= read -r ts_old; do
            grep -F -x -q -e "$ts_old" "$ts_new" && continue
            tree_remove_file "$ts_old" "$ts_dir"
        done < "$ts_list"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        if ! mkdir -p -- "$STATE_DIR" ||
            ! cp -- "$ts_new" "$ts_list.new" ||
            ! mv -f -- "$ts_list.new" "$ts_list"; then
            fail "cannot write: $ts_list"
        fi
    fi
    rm -f -- "$ts_new"
}

# Point out the files in the tree directory $1 of $HOME that are not this
# repo's: yours, or left by a version installed before lists were kept.
tree_strangers() {
    [ -d "$HOME/$1" ] || return 0
    (cd -- "$HOME" && find "$1" \( -type f -o -type l \) -print) 2>/dev/null |
        sort > "$FILE_LIST.found"
    while IFS= read -r tsr_rel; do
        grep -F -x -q -e "$tsr_rel" "$FILE_LIST" && continue
        tsr_note="not from this repo"
        for tsr_own in $HAND_COPY_FILES; do
            [ "$tsr_rel" = "$tsr_own" ] && tsr_note="yours"
        done
        note "kept    $tsr_rel  ($tsr_note)"
    done < "$FILE_LIST.found"
    rm -f -- "$FILE_LIST.found"
}

# `install NAME` for a tree.
cmd_install_tree() {
    cit_name=$1
    cit_dir=$(tree_dir "$cit_name") || return 1
    msg "Installing $cit_name into $HOME/$cit_dir"

    tree_files "$cit_dir" > "$FILE_LIST.wanted"
    if [ ! -s "$FILE_LIST.wanted" ]; then
        rm -f -- "$FILE_LIST.wanted"
        fail "this repo has no $cit_dir to install"
        return 1
    fi
    cit_before=$CHANGES
    while IFS= read -r cit_rel; do
        install_file "$cit_rel"
    done < "$FILE_LIST.wanted"
    rm -f -- "$FILE_LIST.wanted"

    # Asked for by name: it is wanted again, whatever was said before.
    if [ "$DRY_RUN" -eq 0 ] && tree_removed "$cit_name"; then
        rm -f -- "$STATE_DIR/$cit_name.removed"
    fi
    tree_settle "$cit_name"
    tree_strangers "$cit_dir"
    if [ "$CHANGES" -gt "$cit_before" ]; then
        note "an Emacs that is running goes on with what it loaded: restart it"
    fi
}

# `uninstall NAME` for a tree: what was installed goes, what is yours stays.
cmd_uninstall_tree() {
    cut_name=$1
    cut_dir=$(tree_dir "$cut_name") || return 1
    cut_list="$STATE_DIR/$cut_name.files"
    msg "Removing $cut_name from $HOME/$cut_dir"

    # What was installed, by the list kept of it; and what this repo would
    # install, which covers a copy that was made before lists were kept.
    {
        [ -f "$cut_list" ] && cat -- "$cut_list"
        tree_files "$cut_dir"
    } | sort -u > "$FILE_LIST.going"
    while IFS= read -r cut_rel; do
        tree_remove_file "$cut_rel" "$cut_dir"
    done < "$FILE_LIST.going"

    # What MEGA 2.0 built for itself, and can build again: the compiled copy
    # of its own Lisp. Not your history, your undo or its backups of your
    # files, which are yours to delete.
    if [ "$cut_name" = mega2 ]; then
        case ${XDG_CACHE_HOME-} in
            /*) cut_cache="$XDG_CACHE_HOME/mega2" ;;
            *)  cut_cache="$HOME/.cache/mega2" ;;
        esac
        for cut_built in compiled eln; do
            [ -d "$cut_cache/$cut_built" ] || continue
            note "remove  $cut_cache/$cut_built  (built by MEGA, which builds it again)"
            CHANGES=$((CHANGES + 1))
            if [ "$DRY_RUN" -eq 0 ] && ! rm -rf -- "$cut_cache/$cut_built"; then
                fail "cannot remove: $cut_cache/$cut_built"
            fi
        done
    fi

    # What is left in the directory is not ours: say so, and leave it.
    if [ -d "$HOME/$cut_dir" ]; then
        (cd -- "$HOME" && find "$cut_dir" \( -type f -o -type l \) -print) 2>/dev/null |
            sort > "$FILE_LIST.left"
        while IFS= read -r cut_rel; do
            # In a dry run, what would have gone is still there.
            grep -F -x -q -e "$cut_rel" "$FILE_LIST.going" && continue
            note "kept    $cut_rel  (not installed from here)"
        done < "$FILE_LIST.left"
        rm -f -- "$FILE_LIST.left"
    fi
    rm -f -- "$FILE_LIST.going"

    if [ "$DRY_RUN" -eq 0 ]; then
        rm -f -- "$cut_list"
        rmdir -- "$HOME/$cut_dir" 2>/dev/null
        # So that `user` does not put it straight back.
        if ! mkdir -p -- "$STATE_DIR" || ! : > "$STATE_DIR/$cut_name.removed"; then
            fail "cannot write: $STATE_DIR/$cut_name.removed"
        fi
    fi
    if [ "$cut_name" = mega2 ]; then
        note "kept    what MEGA remembers, and its backups of your files:"
        note "        ${XDG_STATE_HOME:-$HOME/.local/state}/mega2  ${XDG_CACHE_HOME:-$HOME/.cache}/mega2"
    fi
    # chemacs2 would go on trying to start what is no longer there.
    if grep -F -q -e "/$cut_dir\"" "$HOME/.emacs-profiles.el" 2>/dev/null; then
        note "~/.emacs-profiles.el still names ~/$cut_dir as a profile"
    fi
}

cmd_user() {
    msg "Installing into $HOME"
    cu_skipped=
    while IFS= read -r cu_rel; do
        # A tree that was uninstalled stays away until it is installed again.
        if cu_tree=$(tree_of "$cu_rel") && tree_removed "$cu_tree"; then
            case " $cu_skipped " in
                *" $cu_tree "*) ;;
                *) cu_skipped="$cu_skipped $cu_tree" ;;
            esac
            continue
        fi
        install_file "$cu_rel"
    done < "$FILE_LIST"

    for cu_entry in $TREES; do
        cu_tree=${cu_entry%%:*}
        tree_removed "$cu_tree" || tree_settle "$cu_tree"
    done
    for cu_tree in $cu_skipped; do
        note "skip    $(tree_dir "$cu_tree")  (uninstalled; '$PROG install $cu_tree' brings it back)"
    done
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

# --- clones: programs fetched from where they are published -------------------

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
        cr_kept="$BACKUP_DIR/$(basename -- "$cr_dir")"
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
    note "start a profile yourself:  emacs --init-directory ~/.mega2.d"
}

# Print the names `install` and `uninstall` take.
names() {
    for n_entry in $TREES; do
        printf '%s ' "${n_entry%%:*}"
    done
    printf '%s\n' "$CLONES"
}

known_name() {
    for kn_name in $(names); do
        [ "$kn_name" = "$1" ] && return 0
    done
    return 1
}

cmd_install() {
    for ci_name in $NAMES; do
        case $ci_name in
            tmux)     cmd_install_tmux ;;
            chemacs2) cmd_install_chemacs2 ;;
            *)        cmd_install_tree "$ci_name" ;;
        esac
    done
}

cmd_uninstall() {
    for ci_name in $NAMES; do
        case $ci_name in
            tmux)     cmd_uninstall_tmux ;;
            chemacs2) cmd_uninstall_chemacs2 ;;
            *)        cmd_uninstall_tree "$ci_name" ;;
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
trap 'rm -f -- "$FILE_LIST" "$FILE_LIST".*' EXIT
trap 'rm -f -- "$FILE_LIST" "$FILE_LIST".*; exit 130' INT
trap 'rm -f -- "$FILE_LIST" "$FILE_LIST".*; exit 143' TERM

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

if [ "$COMMAND" = user ] || [ "$COMMAND" = link ] || [ "$COMMAND" = install ]; then
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
