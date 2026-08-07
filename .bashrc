# ~/.bashrc -- read by bash INTERACTIVE shells.
#
# WHEN THIS RUNS
#   - every new terminal window (interactive, non-login)
#   - login shells, because ~/.profile sources this file explicitly
#   - `ssh host 'command'` -- NOT interactive, but bash still reads .bashrc
#     when its stdin is a network connection. That is why the environment is
#     loaded ABOVE the interactive guard: remote commands need PATH, but they
#     must not get aliases or a prompt.
#
# Distribution-neutral: everything optional is probed before use.

# --- environment layer (runs in every mode, must stay silent) ---------------
if [ -f "$HOME/.my_profile" ]; then
    . "$HOME/.my_profile"
fi

# --- interactive guard ------------------------------------------------------
# Nothing below this line runs for scripts or `ssh host 'command'`.
case $- in
    *i*) ;;
    *) return ;;
esac

# --- history ----------------------------------------------------------------
HISTCONTROL=ignoreboth          # skip duplicates and lines starting with a space
HISTSIZE=10000
HISTFILESIZE=20000
shopt -s histappend             # append instead of overwriting on exit
shopt -s cmdhist                # keep a multi-line command as one entry

# --- shell behaviour --------------------------------------------------------
shopt -s checkwinsize           # keep $LINES/$COLUMNS correct after each command
shopt -s globstar 2>/dev/null   # ** matches across directories (bash >= 4)

# --- prompt -----------------------------------------------------------------
# Colored only if the terminal actually supports it.
if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='\u@\h:\w\$ '
fi

# Show user@host:dir in the window title where the terminal understands it.
case "$TERM" in
    xterm*|rxvt*|alacritty|foot*|konsole*|tmux*|screen*)
        PS1="\[\e]0;\u@\h: \w\a\]$PS1"
        ;;
esac

# --- optional integrations --------------------------------------------------
# Make `less` handle non-text input. Named lesspipe.sh on Arch, lesspipe on Debian.
if command -v lesspipe.sh >/dev/null 2>&1; then
    export LESSOPEN="| lesspipe.sh %s"
elif command -v lesspipe >/dev/null 2>&1; then
    eval "$(SHELL=/bin/sh lesspipe)"
fi

# bash-completion lives in a different place on every distribution.
if ! shopt -oq posix; then
    for _brc_comp in \
        /usr/share/bash-completion/bash_completion \
        /etc/bash_completion \
        /usr/local/share/bash-completion/bash_completion \
        /opt/homebrew/etc/profile.d/bash_completion.sh
    do
        if [ -r "$_brc_comp" ]; then
            . "$_brc_comp"
            break
        fi
    done
    unset _brc_comp
fi

# --- aliases ----------------------------------------------------------------
if [ -f "$HOME/.aliases" ]; then
    . "$HOME/.aliases"
fi

# Machine-local overrides, never tracked in the dotfiles repo.
if [ -f "$HOME/.bashrc.local" ]; then
    . "$HOME/.bashrc.local"
fi
