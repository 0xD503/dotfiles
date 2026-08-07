# ~/.zshrc -- read by zsh INTERACTIVE shells (login and non-login alike).
#
# The environment layer lives in ~/.zshenv, which zsh reads before this file
# in every mode. It is re-sourced here on purpose: on many distributions
# /etc/zprofile runs `emulate sh -c 'source /etc/profile'` for login shells,
# which happens AFTER ~/.zshenv and can reorder or overwrite PATH. Sourcing
# the environment layer again is idempotent and puts PATH back in order.

if [ -f "$HOME/.my_profile" ]; then
    . "$HOME/.my_profile"
fi

# --- history ----------------------------------------------------------------
HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_VERIFY
setopt APPEND_HISTORY INC_APPEND_HISTORY

# --- oh-my-zsh, when it is installed ----------------------------------------
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"

if [ -r "$ZSH/oh-my-zsh.sh" ]; then
    ZSH_THEME="cloud"
    CASE_SENSITIVE="true"
    plugins=(git)

    zstyle ':omz:update' mode reminder
    zstyle ':omz:update' frequency 28

    source "$ZSH/oh-my-zsh.sh"
else
    # Fallback so a machine without oh-my-zsh still gets a usable zsh.
    autoload -Uz compinit
    compinit -d "${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump"
    zstyle ':completion:*' menu select
    zstyle ':completion:*' matcher-list 'r:|=*' 'l:|=* r:|=*'

    autoload -Uz colors && colors
    PROMPT='%F{green}%n@%m%f:%F{blue}%~%f%# '

    bindkey -e                  # emacs keybindings, matching oh-my-zsh's default
    setopt AUTO_CD INTERACTIVE_COMMENTS
fi

# --- aliases ----------------------------------------------------------------
# After oh-my-zsh, so these win over anything its plugins define.
if [ -f "$HOME/.aliases" ]; then
    . "$HOME/.aliases"
fi

# Machine-local overrides, never tracked in the dotfiles repo.
if [ -f "$HOME/.zshrc.local" ]; then
    . "$HOME/.zshrc.local"
fi
