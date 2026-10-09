# MEGA 2.0 — Make Emacs Great Again

A terminal-first Emacs configuration that needs nothing but Emacs 31.1: no
packages, no downloads. This page is the whole user guide. How and why it is
built is in [DESIGN.md](DESIGN.md).

> **Status: milestone 0.** The foundation is here: safe defaults, the theme,
> modeline, ruler, history, the doctor and the cheat sheet. Search, the file
> finder, completion, the language server and the rest arrive milestone by
> milestone; DESIGN.md lists them.

## Start

```sh
emacs                                  # if MEGA 2.0 is your default chemacs2 profile
emacs --init-directory ~/.mega2.d      # anywhere else
```

Then, once:

```
M-x mega-doctor      what works on this machine, and what is missing
C-c ?                every MEGA key, on one screen
```

## Keys

`C-` is Ctrl, `M-` is Alt. `C-c ?` always shows the current, complete list of
MEGA's own keys; these are the ones to know on day one.

| Key | Does |
| --- | --- |
| `C-c ?` | The cheat sheet |
| `M-x mega-doctor` | Health report |
| `C-x C-f` | Open a file |
| `C-x C-s` | Save |
| `C-x b` | Switch buffer |
| `C-g` | Cancel whatever is happening |
| `C-/` | Undo |
| `C-M-_` | Redo |
| `C-s` | Search in the buffer |
| `M-%` | Search and replace |
| `C-x p f` | Open a file in the project |
| `C-x p g` | Search the project |
| `M-{` / `M-}` | Make the window narrower / wider |
| `C-c <left>` | Back to the previous window layout |
| `C-h k` | What does this key do? |
| `C-x C-c` | Quit |

Pause after a prefix such as `C-x` and Emacs lists what can follow.

## Where a setting goes

| Want to… | Edit |
| --- | --- |
| Change something on this machine only | `local.el` |
| Add or rebind a key | one row in `lisp/mega-keys.el` |
| Change a global default | `lisp/mega-core.el` |
| Remove a feature | delete its line in `init.el` |

`local.el` is never overwritten by a plain `./update.sh` command; install it
once with `./update.sh local user`.

The ruler sits at column 80. A project's `.editorconfig` moves it
(`max_line_length`) and sets indentation and line endings for its files.

## What MEGA does for you without asking

- **Keeps your work.** Backups and auto-saves are on, stored away from your
  projects. Deleting a file from Emacs moves it to the trash.
- **Keeps your data on the machine.** MEGA makes no network connection and
  has no telemetry. What you copy is never written to disk, and files such as
  `.env`, keys and anything under `~/.ssh` are left out of recent files.
- **Does not trust a repository.** Opening a file cannot run code: unsafe
  file-local variables and `eval:` lines are ignored.

Everything MEGA remembers lives in `~/.local/state/mega2` and
`~/.cache/mega2`, readable only by you. Deleting the cache loses nothing you
cannot rebuild offline. `~/.mega2.d` itself is never written to.

## When something breaks

A module that fails to load is skipped and reported; the rest keeps working.
`M-x mega-doctor` lists what failed, how long each module took, and whether
the safety settings above are really in force.

`M-x mega-keys-mode` turns every MEGA key off, leaving stock Emacs.

On an Emacs older than 31.1 MEGA configures nothing and says so, leaving a
plain, working Emacs.

## Tests

```sh
tests/test_mega2.sh      # from the dotfiles repo; runs in a sandbox
```
