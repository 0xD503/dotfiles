# MEGA — Make Emacs Great Again

A small, terminal-first Emacs configuration built on what Emacs 30 already
ships. No DSL, no bootstrap, no module resolver: `init.el` names every module
it loads, and each module is one file with one concern.

```sh
emacs --with-profile mega -nw
```

## First run

```
M-x mega-doctor              # what's working, what's missing, how to fix it
M-x mega-treesit-install-all # build the tree-sitter grammars (needs cc + git)
```

`mega-doctor` is the important one. It reports which grammars and language
servers actually exist on this machine and prints the exact install command for
each that doesn't — a feature enabled in a config but missing its binary does
nothing, silently, and that is the failure this buffer is designed to surface.

Startup is ~150 ms in a terminal with all 15 grammars installed. MEGA ships as
source; `M-x mega-compile` byte-compiles it, but measured the difference at
about 2 ms, so it is genuinely optional.

## Where a new setting goes

| Want to… | Edit |
| --- | --- |
| Add a language | one row in `mega-languages` (`lisp/mega-lang.el`) |
| Add or rebind a key | `lisp/mega-keys.el` — every binding is there |
| Add a package | one `use-package` form in the module that owns it |
| Add a whole feature area | new `lisp/mega-X.el` + one line in `mega-modules` |
| Change a global default | `lisp/mega-core.el` |
| Anything machine-specific | `local.el` — untracked, never deployed |

## Adding a language

One row. Adding Go, in full:

```elisp
(go
 :grammars ((go "https://github.com/tree-sitter/tree-sitter-go" "v0.23.4"))
 :remap ((go-mode . go-ts-mode))
 :modes (go-ts-mode)
 :servers (("gopls")))
```

Then `M-x mega-treesit-install-all` and `M-x mega-lang-reload`. The grammar is
registered, the mode is remapped **only if the grammar actually built**, and
`gopls` is wired to eglot **only if the binary exists**. Nothing else in MEGA
knows a language name.

## Keys

Everything lives in `mega-keys-mode-map`, a global minor-mode keymap. That is
deliberate: minor-mode maps outrank major-mode maps, so `C-c C-c` means
"comment" in `org-mode` and `python-ts-mode` alike. `M-x mega-keys-mode` turns
the whole layer off.

| Key | Does |
| --- | --- |
| `M-g a` | ripgrep the project |
| `M-g s` | ripgrep the symbol at point |
| `C-c p …` | projectile (`C-c p f` = find file in project) |
| `C-c C-c` | comment/uncomment region or line |
| `C-c C-v` | the major mode's own `C-c C-c` (org, python, …) |
| `M-n` / `M-p` | jump to next/previous occurrence of the symbol at point |
| `M-{` / `M-}` | shrink/enlarge window horizontally |
| `C-x u` | undo tree visualiser |
| `C-c d` / `C-c D` | documentation in a side window / in a popup |
| `C-c t` | treemacs |
| `C-c w …` | workspaces (`n` new, `r` resume, `s` save, `w` switch) |
| `C-c l c` | Claude CLI for this project (**no API key needed**) |
| `C-c l s` / `r` / `q` | gptel: send, rewrite, explain-at-point |

`M-x`, `C-x C-f`, `C-x b` and `M-y` are bound to dispatchers so they behave
correctly under either completion backend.

## Switchable choices

Set these in `local.el` and restart:

- `mega-completion-backend` — `helm` (default) or `vertico`
- `mega-undo-backend` — `vundo` (default) or `undo-tree`
- `mega-zone-idle-seconds` — `nil` (default) or a number
- `mega-enable-kkp` — `nil` (default). Turning it on lets a supporting
  terminal distinguish `C-.` from `C-,` and `C-RET` from `RET`, but
  `global-kkp-mode` blocks until the terminal answers or times out — measured
  at **250 ms** here, and tmux does not forward the query by default. Enable it
  only if your terminal answers.

The invariant worth protecting: **flipping a backend changes no keybinding.**
Keys are bound to `mega-*` commands that dispatch, so the two code paths stay
confined to one file each.

## Layout

```
early-init.el   GC deferral, XDG paths, package.el locations
init.el         archives, local.el, the module list
local.el        machine-specific overrides (never deployed)
lisp/
  mega-lib.el         paths, mega-exe-p, mega-load-module
  mega-core.el        encoding, backups, security, defaults
  mega-ui.el          Nord, modeline, icons, hl-todo, indent guides
  mega-keys.el        every binding
  mega-completion.el  helm | vertico dispatch, corfu
  mega-project.el     projectile, treemacs
  mega-edit.el        whitespace, editorconfig, smartscan, undo, comments
  mega-treesit.el     grammar install/pin machinery
  mega-lsp.el         eglot, eldoc, terminal doc popup
  mega-lang.el        the language table  ← add languages here
  mega-lang-verilog.el SystemVerilog
  mega-session.el     workspaces, history, places
  mega-remote.el      tramp
  mega-llm.el         Claude CLI + gptel
  mega-zone.el        idle screensaver
  mega-doctor.el      M-x mega-doctor
```

## Where state lives

`~/.mega.d` stays byte-identical to the repository — nothing is written into
it at runtime, which is what keeps `./update.sh diff` honest.

| | |
| --- | --- |
| `~/.local/share/mega/` | installed packages |
| `~/.cache/mega/` | grammars, eln cache, backups, project caches |
| `~/.local/state/mega/` | history, places, `custom.el`, grammar pins |

Deleting `~/.cache/mega` loses nothing you care about.

## Secrets

There are none in this repository, and there must not be. `gptel` reads its
API key from auth-source (`~/.authinfo.gpg`) through a function, at call time.
`M-x mega-doctor` prints the setup if no key is found.

`C-c l c` — the Claude CLI — needs no API key at all, since the CLI carries its
own authentication. Start there.

## When something breaks

A module that signals during startup is **recorded and skipped**; the rest of
MEGA still loads and you get a warning naming the failure. You will not land in
`--debug-init`. `M-x mega-doctor` lists failures and per-module load times, so
when startup gets slower you can see which module did it.

## Grammar pinning

`mega-languages` pins each grammar to an upstream release tag. Tags are stable
in practice but mutable in principle, so once a set is known good:

```
M-x mega-treesit-freeze
```

records the exact commit SHAs in `~/.local/state/mega/treesit-pins.el`, which
overrides the tags from then on. Delete that file to float back.
