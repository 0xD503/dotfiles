#!/bin/env bash


dot_files=(".profile" ".my_profile" ".bashrc" ".aliases" ".gitconfig" ".selected_editor" ".tmux.conf.local" ".zshrc")
#dot_dirs=(".emacs.d/" ".doom.d/")
dot_dirs=(".doom.d/")


function usage() {
    echo "usage:"
    echo "    $0 repo - update repo"
    echo "    $0 user - update user files"
}

function update_repo() {
    echo "Updating repo..."
    for dotfile in "${dot_files[@]}"; do
	    cp "$HOME/$dotfile" "./$dotfile"
    done
    for dotdir in "${dot_dirs[@]}"; do
	    cp -r "$HOME/$dotdir" "./$dotdir"
    done
}

function update_user() {
    echo "Updating user files..."
    for dotfile in "${dot_files[@]}"; do
	    cp "./$dotfile" "$HOME/$dotfile"
    done
    for dotdir in "${dot_dirs[@]}"; do
        cp "./$dotdir" "$HOME/$dotdir"
    done
}

function clean_repo() {
    for dotdir in "${dot_dirs[@]}"; do
        rm -rf "./$dotdir"
    done
    echo "Clean done"
}



if [ "$1" = "repo" ]; then
    update_repo
elif [ "$1" = "user" ]; then
    update_user
elif [ "$1" = "-c" ]; then
    clean_repo
else
    echo "$0: Wrong usage"
    usage
fi

echo done
exit 0
