#!/bin/env bash


dot_files=(".profile" ".my_profile" ".bashrc" ".aliases" ".gitconfig" ".selected_editor" ".tmux.conf.local" ".zshrc")
#dot_dirs=(".emacs.d/" ".doom.d/")
dot_dirs=(".doom.d/")


function usage() {
    echo "usage:"
    echo "    $0 -h - show this info"
    echo "    $0 repo - update repo"
    echo "    $0 user - update user files"
    echo "    $0 -c - clean .emacs/.doom dirs"
}

function update_repo() {
    echo "Updating repo..."
    for dotfile in "${dot_files[@]}"; do
	    cp "$HOME/$dotfile" "./"
    done
    for dotdir in "${dot_dirs[@]}"; do
	    cp -r "$HOME/$dotdir" "./"
    done
}

function update_user() {
    echo "Updating user files..."
    for dotfile in "${dot_files[@]}"; do
	    cp "./$dotfile" "$HOME/"
    done
    for dotdir in "${dot_dirs[@]}"; do
        cp -r "./$dotdir" "$HOME/"
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
elif [ "$1" = "-h" ]; then
    usage
else
    echo "$0: Wrong usage"
    usage
fi

echo done
exit 0
