# ==============================================================================
# 1. ENVIRONMENT & LOCALE (Custom)
# ==============================================================================
# Ensures Zsh correctly calculates the width of multi-byte Unicode characters.
# Prevents visual redrawing glitches without altering system language.
export LC_CTYPE="C.UTF-8"

# ==============================================================================
# 2. HISTORY CONFIGURATION (Custom Multi-Terminal)
# ==============================================================================

if [ -z "$ZSH_HISTFILE" ]; then
    HISTFILE=~/.zsh_history
else
    HISTFILE="$ZSH_HISTFILE"
fi
HISTSIZE=100000
SAVEHIST=100000
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY
setopt HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS
setopt hist_expire_dups_first
setopt hist_ignore_dups
setopt hist_verify

# Force zsh to show the complete history
alias history="history 0"

# ==============================================================================
# 3. ZSH BEHAVIOR & OPTIONS (Kali Defaults)
# ==============================================================================
setopt autocd              # change directory just by typing its name
setopt interactivecomments # allow comments in interactive mode
setopt magicequalsubst     # enable filename expansion for arguments of the form ‘anything=expression’
setopt nonomatch           # hide error message if there is no match for the pattern
setopt notify              # report the status of background jobs immediately
setopt numericglobsort     # sort filenames numerically when it makes sense
setopt promptsubst         # enable command substitution in prompt

WORDCHARS='_-' # Don't consider certain characters part of the word
PROMPT_EOL_MARK="" # hide EOL sign ('%')

# ==============================================================================
# 4. KEYBINDINGS (Kali Defaults)
# ==============================================================================
bindkey -e                                        # emacs key bindings
bindkey ' ' magic-space                           # do history expansion on space
bindkey '^U' backward-kill-line                   # ctrl + U
bindkey '^[[3;5~' kill-word                       # ctrl + Supr
bindkey '^[[3~' delete-char                       # delete
bindkey '^[[1;5C' forward-word                    # ctrl + ->
bindkey '^[[1;5D' backward-word                   # ctrl + <-
bindkey '^[[5~' beginning-of-buffer-or-history    # page up
bindkey '^[[6~' end-of-buffer-or-history          # page down
bindkey '^[[H' beginning-of-line                  # home
bindkey '^[[F' end-of-line                        # end
bindkey '^[[Z' undo                               # shift + tab undo last action

# ==============================================================================
# 5. MISE (Tool Version Manager) - must be before compinit so tools are on PATH
# ==============================================================================
eval "$(mise activate zsh)"

# ==============================================================================
# 6. COMPLETION FEATURES
# ==============================================================================
autoload -Uz compinit
compinit -d ~/.cache/zcompdump

# Auto-discover completions: when pressing TAB on any command for the first
# time, try running `<cmd> completion zsh` to load its completions on the fly.
_try_load_completion() {
    local cmd=$words[1]
    local out=$($cmd completion zsh 2>/dev/null)
    if [[ $out == *compdef* ]]; then
        source <(echo $out)
        ${_comps[$cmd]} "$@"
    else
        _default "$@"
    fi
}
_comps[-default-]=_try_load_completion
zstyle ':completion:*:*:*:*:*' menu select
zstyle ':completion:*' completer _expand _complete
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' rehash true
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose false
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# ==============================================================================
# 6. ALIASES & COLORS (Kali Defaults)
# ==============================================================================
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    export LS_COLORS="$LS_COLORS:ow=30;44:" # fix ls color for folders with 777 permissions

    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
    alias diff='diff --color=auto'
    alias ip='ip --color=auto'

    export LESS_TERMCAP_mb=$'\E[1;31m'     # begin blink
    export LESS_TERMCAP_md=$'\E[1;36m'     # begin bold
    export LESS_TERMCAP_me=$'\E[0m'        # reset bold/blink
    export LESS_TERMCAP_so=$'\E[01;33m'    # begin reverse video
    export LESS_TERMCAP_se=$'\E[0m'        # reset reverse video
    export LESS_TERMCAP_us=$'\E[1;32m'     # begin underline
    export LESS_TERMCAP_ue=$'\E[0m'        # reset underline
    export MANROFFOPT="-c"

    # Take advantage of $LS_COLORS for completion as well
    zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
    zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
fi

alias ll='ls -l'
alias la='ls -A'
alias l='ls -CF'

# ==============================================================================
# 7. KALI PROMPT FALLBACK (In case Starship/P10k isn't installed)
# ==============================================================================
# set variable identifying the chroot you work in
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

PROMPT=$'%F{%(#.blue.green)}┌──${debian_chroot:+($debian_chroot)─}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n㉿%m%b%F{%(#.blue.green)})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]\n└─%B%(#.%F{red}#.%F{blue}$)%b%F{reset} '

# ==============================================================================
# 8. PLUGINS (Kali Defaults)
# ==============================================================================
# enable auto-suggestions based on the history
if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'
fi

# enable syntax-highlighting
if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    . /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# enable command-not-found if installed
if [ -f /etc/zsh_command_not_found ]; then
    . /etc/zsh_command_not_found
fi

# ==============================================================================
# 9. ADVANCED PROMPT (Starship)
# ==============================================================================
eval "$(starship init zsh)"
