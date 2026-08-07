# ~/.bash_profile -- read by bash LOGIN shells.
#
# bash reads the first of ~/.bash_profile, ~/.bash_login, ~/.profile that
# exists and ignores the rest. Most distributions ship a ~/.bash_profile that
# sources only ~/.bashrc, which silently shadows ~/.profile and skips the
# environment layer for login shells.
#
# This file exists purely to undo that: it hands control to ~/.profile, which
# loads ~/.my_profile and then ~/.bashrc. Nothing else belongs here.

if [ -f "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi
