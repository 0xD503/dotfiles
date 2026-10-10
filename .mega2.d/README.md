# MEGA 2.0 — Make Emacs Great Again

A terminal-first Emacs configuration that needs nothing but Emacs 31.1: no
packages, no downloads. This page is the whole user guide. How and why it is
built is in [DESIGN.md](DESIGN.md).

## Install, update, remove

From the dotfiles repo:

```sh
./update.sh install mega2      # install it, or update it: the same command
./update.sh install chemacs2   # optional: makes MEGA what plain `emacs` starts
./update.sh uninstall mega2    # remove it
```

Updating is safe to do at any time. `~/.mega2.d` ends up holding exactly the
repo's files: what an older version had and this one has not is removed, and
everything replaced or removed is first copied to `~/.dotfiles-backup/`.
Your `local.el` is never touched. What MEGA remembers (history, undo, trusted
projects, workspaces) lives elsewhere and is read with care: a file a newer
MEGA cannot make sense of is ignored, never guessed at, so the worst an
update can do is make MEGA ask or forget something once. Its compiled copy
is rebuilt by itself. Restart Emacs afterwards: a running one goes on with
the version it loaded. `./update.sh user`, which deploys every dotfile,
updates MEGA the same way.

Removing it takes away what was installed and what MEGA built; your
`local.el`, your history and MEGA's backups of your files stay, and the
command says where.

## Start

```sh
emacs                                  # if MEGA 2.0 is your default chemacs2 profile
emacs --init-directory ~/.mega2.d      # anywhere else
```

Without a file, Emacs opens on a home page: `r` continues where you left off,
`1`–`9` open a recent project, and the first line says how long starting
took, up to the moment the page was drawn.

Then, once:

```
M-x mega-doctor      what works on this machine, and what is missing
C-c ?                every MEGA key, and the keys of each place that has its own
```

**MEGA compiles itself.** There is nothing to do. The first start after an
update runs MEGA's Lisp as source and, a few seconds later, compiles a copy
in the background. Every start after that loads the copy, and Emacs turns
what it loads into native code by itself, also in the background. The copy
lives in `~/.cache/mega2`; nothing compiled is ever written to `~/.mega2.d`
or to the repository. `M-x mega-doctor` says which form is running.

## Keys

`C-` is Ctrl, `M-` is Alt. `C-c ?` always shows the complete, current list;
these are the ones to know. Pause after a prefix such as `C-c c` and Emacs
lists what can follow.

| Key | Does |
| --- | --- |
| `C-c ?` | The cheat sheet |
| `C-c h` | The home page |
| `C-c y` | Trust this project: let its tools run (see Trust below) |
| `C-c p f` | Open a file of the project: type any part of its name |
| `M-g a` | Search the project as you type (`M-g s`: the symbol at point) |
| `C-c t` | Show or hide the file tree |
| `M-.` | Go to the definition (`M-,` goes back, `M-?` lists the uses) |
| `C-c d` | Documentation for the thing at point |
| `C-c c r` | Rename everywhere (`C-c c a`: fixes, `C-c c f`: format) |
| `C-c c n` | Next problem (`C-c c e`: list them) |
| `C-c x b` | Build (`C-c x r` run, `C-c x t` test, `C-c x x` choose a task) |
| `C-c g g` | Start the debugger (`C-c g b` breakpoint, `r` run, `n` step, `c` continue) |
| `C-c k u` | Start or join the project's dev container (`C-c k d` leaves it) |
| `C-c l c` | Claude session for the project (`C-c l a` ask, `r` rewrite, `e` explain) |
| `C-x u` | The undo history as a tree |
| `C-c w s` | Save the open files and the window layout (`C-c w r` brings them back) |
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

**Searching** (`M-g a`) is done by `git grep`, as a Perl regular expression,
and the prompt says so. `C-o b` switches to ripgrep, then plain grep, then
back, and the session stays with what you chose; `(setq mega-search-backend
'rg)` in `local.el` makes ripgrep the one to start with. Outside a checkout
`git grep` cannot search, and the next of the three that is installed does.

`C-o ?` shows the settings and `C-o` plus a letter changes one: `c` case,
`w` whole words, `l` literal text, `e` export the hits to an editable buffer.
`needle -- src/*.rs` searches part of the project.

Which files are searched is where the three programs differ, since only git
knows what a checkout tracks. In brackets, how each starts out:

| | git grep | ripgrep | grep |
| --- | --- | --- | --- |
| untracked files | `C-o u` (on) | always | always |
| ignored files | `C-o i` (off) | `C-o i` (off) | always |
| hidden files | always | `C-o h` (on) | `C-o h` (on) |
| submodules | `C-o s` (off) | always | always |

With git grep, ignored files count as untracked, so `C-o i` brings both, and
`C-o s` leaves both out. A key the current program cannot act on says so.

**A dev container** starts in the background: Emacs stays yours while it
does, and `*mega-container*` shows each step. Before anything from
`devcontainer.json` runs you are shown what will: every command, in order,
and what is mounted from this machine. A file that asks for something MEGA
cannot do, or does not know, is refused by name and not half-followed.

## What needs what

Everything outside Emacs is optional: without it the feature stays quiet and
`M-x mega-doctor` says what is missing.

| For | Install |
| --- | --- |
| Search | `git` in a checkout; `rg` or `grep` anywhere else |
| Go to definition, rename, problems as you type | the language's server, e.g. `rust-analyzer`, `clangd` |
| Format on save | the language's formatter, e.g. `rustfmt`, `clang-format`, `ruff` |
| Debugging | `lldb` or `gdb`; Python brings `pdb` |
| Dev containers | `podman` or `docker`; the `devcontainer` CLI if you have it |
| Claude | the `claude` program, signed in |

Syntax highlighting for some languages wants a parser; Emacs offers to build
it the first time you open such a file.

## Trust

A language server, a syntax checker, a formatter, a task, a debugger and a
container all run code that comes with the project. Until you say so, none
of them does: a project you have not trusted is only edited, and the
modeline says `untrusted`.

`C-c y` trusts the project of the file you are in, and what was held back
starts in its open files. `M-x mega-distrust-project` takes that back.

MEGA never asks while you open or read a file. It asks only when you press
a key that cannot work without the answer, such as build or debug, and says
what the answer allows. A file outside any project is trusted with the other
files of its directory and nothing below it.

## Where a setting goes

| Want to… | Edit |
| --- | --- |
| Change something on this machine only | `local.el` |
| Add, move or remove a key | `mega-keys-add` / `mega-keys-remove`, in `local.el`; the cheat sheet follows |
| Change a global default | `lisp/mega-core.el` |
| Add a language: modes, server, formatter, indentation | one row of `mega-languages` in `lisp/mega-lang.el` |
| Add a kind of project: its tasks, its formatter | one row of `mega-project-kinds` in `lisp/mega-project.el` |
| Add a snippet | `mega-snippets` in `lisp/mega-snippet.el` |
| Remove a feature | delete its line in `init.el`; its keys go with it |

`local.el` is never installed or overwritten by `./update.sh install mega2`
or `./update.sh user`; put the stub in place once with `./update.sh local
user`. A project's `.editorconfig` sets its
indentation and line endings, moves the ruler (`max_line_length`), and says
whether spaces at the ends of lines are removed. A module that others are
built on (`mega-exec`, `mega-trust`, `mega-project`, `mega-lang`) stays
loaded for as long as anything that needs it is on the list.

## What MEGA does without asking, and what it never does

- **Keeps your work.** Backups and auto-saves are on, stored away from your
  projects. Deleting a file moves it to the trash. Undo history survives
  closing the file and restarting Emacs.
- **Keeps your data on the machine.** MEGA opens no network connection and
  has no telemetry. What you copy is never written to disk. Files such as
  `.env`, keys, anything under `~/.ssh` and anything in a temporary directory
  leave no trace: not in recent files, cursor places, prompt history, saved
  workspaces or stored undo history. `mega-private-file-regexps` in
  `local.el` adds your own.
- **Sends text to Claude only when you press a Claude key**, and only the
  text you selected. With nothing selected, explain and rewrite offer the
  function the cursor is in, say how many lines that is, and wait for a yes.
  A private file needs a typed "yes" first.
- **Does not trust a repository.** Opening a file cannot run code: unsafe
  file-local variables and `eval:` lines are ignored, nothing checks or
  builds it, and see Trust above.

Everything MEGA remembers lives in `~/.local/state/mega2` and
`~/.cache/mega2`, readable only by you. Deleting the cache loses nothing you
cannot rebuild offline. `~/.mega2.d` itself is never written to.

## When something breaks

A module that fails to load is skipped and reported; the rest keeps working.
`M-x mega-doctor` lists what failed, how long each module took, which
programs it found, and whether the promises above are really in force.

`M-x mega-keys-mode` turns every MEGA key off, leaving stock Emacs. On an
Emacs older than 31.1 MEGA configures nothing and says so.

`MEGA_SOURCE=1 emacs` runs MEGA from source this once, whatever compiled
copy there is. `M-x mega-compile-forget` deletes the copy; `(setq
mega-compile nil)` in `local.el` stops MEGA from making one.

## Tests and timings

```sh
tests/test_mega2.sh          # from the dotfiles repo; runs in a sandbox
tests/test_mega2.sh bench    # only the timings
MEGA_TEST_ONLY=mega-undo tests/test_mega2.sh unit    # only the tests so named
MEGA_REAL_IMAGE=my/image tests/test_mega2.sh container   # a real container: see below
```

The tests run on both forms of MEGA's Lisp, source and compiled, and a real
terminal session is taken through all of it: source, compiled, native.

The `bench` stage times what you wait for (a keystroke, the modeline, the
completion menu, listing and finding a file, a search, a save, the undo tree,
a language server's first start) and prints each time beside what it is
expected to take. A line marked `SLOW` is over one and a half times that and
worth a look; over three times, the run fails. Before a change that might
cost time, keep a run with `MEGA_BENCH_SAVE=before.eld`; afterwards
`MEGA_BENCH_COMPARE=before.eld` also fails on anything that became twice as
slow as it was.

What each benchmark is expected to take is on record in
`tests/mega2/mega-bench-history.eld`, with the commit that made it so and the
reason; there is no number anywhere else to change. When one is exceeded,
whoever sees it finds the cause first (the stage prints the `git bisect`
command) and fixes it. Only if the slowdown is the reasonable, direct and
minimised price of a change that is wanted does the time go up, and then
with a new record: the time, the commit that introduced it, and why.

The `container` stage runs only when named. It starts one container with
podman from an image you already have, with no network, runs, builds and
debugs in it, and removes it; nothing is downloaded.
