# ~/.profile -- entry point for LOGIN shells (sh, dash, ksh, and bash).
#
# WHEN THIS RUNS
#   Login shells only: a TTY login, `su -`, `ssh host` (no command), and most
#   display managers when they start your desktop session.
#   It does NOT run for a new terminal window -- that is a non-login
#   interactive shell, which reads ~/.bashrc or ~/.zshrc instead.
#
#   bash reads the FIRST of ~/.bash_profile, ~/.bash_login, ~/.profile that
#   exists -- so ~/.bash_profile shadows this file. That is why this repo also
#   ships a ~/.bash_profile which simply hands control back here.
#
#   zsh never reads this file (it uses ~/.zshenv / ~/.zprofile / ~/.zshrc).
#
# CONTRACT: POSIX sh only -- /bin/sh may be dash or ash, not bash.

# The environment layer: PATH, umask, EDITOR. Safe in every mode.
if [ -f "$HOME/.my_profile" ]; then
    . "$HOME/.my_profile"
fi

# The interactive layer. A login shell is not necessarily interactive
# (`ssh host 'cmd'` is not), so each branch checks before loading aliases.
if [ -n "${BASH_VERSION-}" ]; then
    # bash: .bashrc carries the interactive setup and guards itself, so a
    # non-interactive login bash returns from it immediately.
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
else
    # Plain POSIX shells have no rc file for login mode; load aliases directly.
    case $- in
        *i*)
            if [ -f "$HOME/.aliases" ]; then
                . "$HOME/.aliases"
            fi
            ;;
    esac
fi
