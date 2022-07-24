#!/bin/env bash


dot_files=(".profile" ".aliases" ".bash_profile" ".bash_aliases" ".emacs.d/" ".gitconfig" ".selected_editor" ".tmux.conf.local")


## create sym link to connect dot files
for dotfile in "${dot_files[@]}"; do
    cp -r "$HOME/$dotfile" "./$dotfile"
done

echo done
