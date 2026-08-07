# ~/.zshenv -- read by EVERY zsh, in every mode.
#
# zsh's startup order is unlike bash's. It always reads ~/.zshenv first --
# login or not, interactive or not, even for `zsh script.zsh`. Then:
#
#   login shell         -> /etc/zprofile, ~/.zprofile
#   interactive shell   -> /etc/zshrc,    ~/.zshrc
#   login shell         -> /etc/zlogin,   ~/.zlogin
#
# zsh never reads ~/.profile, so without this file a zsh script or
# `ssh host 'cmd'` under zsh would run with no PATH additions at all.
#
# Keep this file silent -- it runs for non-interactive shells too.

if [ -f "$HOME/.my_profile" ]; then
    . "$HOME/.my_profile"
fi
