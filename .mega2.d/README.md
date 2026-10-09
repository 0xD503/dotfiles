# MEGA 2.0 — Make Emacs Great Again

A terminal-first Emacs configuration that needs nothing but Emacs 31.1: no
packages, no downloads. This page is the whole user guide. How and why it is
built is in [DESIGN.md](DESIGN.md).

## Start

```sh
emacs                                  # if MEGA 2.0 is your default chemacs2 profile
emacs --init-directory ~/.mega2.d      # anywhere else
```

Without a file, Emacs opens on a home page: `r` continues where you left off,
`1`–`9` open a recent project, and the first line says how long start-up took.

Then, once:

```
M-x mega-doctor      what works on this machine, and what is missing
C-c ?                every MEGA key, on one screen
```

## Keys

`C-` is Ctrl, `M-` is Alt. `C-c ?` always shows the complete, current list;
these are the ones to know. Pause after a prefix such as `C-c c` and Emacs
lists what can follow.

| Key | Does |
| --- | --- |
| `C-c ?` | The cheat sheet |
| `C-c h` | The home page |
| `C-c p f` | Open a file of the project: type any part of its name |
| `M-g a` | Search the project as you type (`M-g s`: the symbol at point) |
| `C-c t` | Show or hide the file tree |
| `M-.` | Go to the definition (`M-,` goes back, `M-?` lists the uses) |
| `C-c d` | Documentation for the thing at point |
| `C-c c r` | Rename everywhere (`C-c c a`: fixes, `C-c c f`: format) |
| `C-c c n` | Next problem (`C-c c e`: list them) |
| `C-c x b` | Build (`C-c x r` run, `C-c x t` test, `C-c x x` choose a task) |
| `C-c g g` | Start the debugger (`C-c g b` breakpoint, `r` run, `n` step, `c` continue) |
| `C-c k u` | Join the project's dev container (`C-c k d` leaves it) |
| `C-c l c` | Claude session for the project (`C-c l a` ask, `r` rewrite, `e` explain) |
| `C-x u` | The undo history as a tree |
| `C-c w s` | Save the files and windows on screen (`C-c w r` brings them back) |
| `C-c s` | Insert a snippet |
| `C-/` | Undo (`C-M-_` redoes) |
| `C-g` | Cancel whatever is happening |
| `C-h k` | What does this key do? |

In code, `C-c C-c` comments or uncomments, `C-c f` folds the block the cursor
is in (`C-c F`: all of them), and `M-n` / `M-p` jump between the uses of the
symbol at point.

The mouse works in the terminal: click, scroll, hover for a hint. Selecting
text with the terminal itself then needs Shift held down; `(setq mega-mouse
nil)` in `local.el` gives the mouse back to the terminal.

**The completion menu** appears as you type. `TAB` takes a candidate, `C-n` /
`C-p` choose, `C-g` closes it; nothing is ever inserted unasked.

**The debugger** follows the program through your files. Where both are
installed, lldb is used before gdb (`mega-debug-prefer` in `local.el` turns
that round). On this machine it is Emacs's own interface to the debugger. In
a dev container MEGA shows the stack and the variables itself, in a window
below, and `C-c g b` sets breakpoints before you start; that needs lldb's
adapter (`lldb-dap`) or gdb 14 or newer in the container.

**In the search prompt**, `C-o ?` shows the settings and `C-o` plus a letter
changes one (`c` case, `u` untracked files, `h` hidden, `w` whole words, `e`
export the hits to an editable buffer). `needle -- src/*.rs` searches part of
the project.

## What needs what

Everything outside Emacs is optional: without it the feature stays quiet and
`M-x mega-doctor` says what is missing.

| For | Install |
| --- | --- |
| Fast search | `rg` (else `git grep`, else `grep`) |
| Go to definition, rename, problems as you type | the language's server, e.g. `rust-analyzer`, `clangd` |
| Format on save | the language's formatter, e.g. `rustfmt`, `clang-format`, `ruff` |
| Debugging | `lldb` or `gdb`; Python brings `pdb` |
| Dev containers | `podman` or `docker`; the `devcontainer` CLI if you have it |
| Claude | the `claude` program, signed in |

Syntax highlighting for some languages wants a parser; Emacs offers to build
it the first time you open such a file.

## Trust

A language server, a formatter, a task, a debugger or a container all run
code that comes with the project. The first time one is needed MEGA asks
once whether you trust the project, and remembers. Until then the project is
only edited. `M-x mega-trust-project` and `M-x mega-distrust-project` change
the answer.

## Where a setting goes

| Want to… | Edit |
| --- | --- |
| Change something on this machine only | `local.el` |
| Add or rebind a key | one row in `lisp/mega-keys.el` |
| Change a global default | `lisp/mega-core.el` |
| Add a language, formatter, task or snippet | its table, named at the top of the module |
| Remove a feature | delete its line in `init.el` |

`local.el` is never overwritten by a plain `./update.sh` command; install it
once with `./update.sh local user`. A project's `.editorconfig` sets its
indentation and line endings and moves the ruler (`max_line_length`).

## What MEGA does without asking, and what it never does

- **Keeps your work.** Backups and auto-saves are on, stored away from your
  projects. Deleting a file moves it to the trash. Undo history survives
  closing the file and restarting Emacs.
- **Keeps your data on the machine.** MEGA opens no network connection and
  has no telemetry. What you copy is never written to disk. Files such as
  `.env`, keys and anything under `~/.ssh` are left out of recent files and
  of stored undo history.
- **Sends text to Claude only when you press a Claude key**, and only the
  text you selected; a private file needs a typed "yes" first.
- **Does not trust a repository.** Opening a file cannot run code: unsafe
  file-local variables and `eval:` lines are ignored, and see Trust above.

Everything MEGA remembers lives in `~/.local/state/mega2` and
`~/.cache/mega2`, readable only by you. Deleting the cache loses nothing you
cannot rebuild offline. `~/.mega2.d` itself is never written to.

## When something breaks

A module that fails to load is skipped and reported; the rest keeps working.
`M-x mega-doctor` lists what failed, how long each module took, which
programs it found, and whether the promises above are really in force.

`M-x mega-keys-mode` turns every MEGA key off, leaving stock Emacs. On an
Emacs older than 31.1 MEGA configures nothing and says so.

## Tests and timings

```sh
tests/test_mega2.sh          # from the dotfiles repo; runs in a sandbox
tests/test_mega2.sh bench    # only the timings
```

The `bench` stage times what you wait for (a keystroke, the completion menu,
finding a file, a search, a save, the undo tree) and prints each time next to
its budget. Before a change that might cost time, keep a run with
`MEGA_BENCH_SAVE=before.eld`; afterwards `MEGA_BENCH_COMPARE=before.eld`
fails on anything that became twice as slow.
