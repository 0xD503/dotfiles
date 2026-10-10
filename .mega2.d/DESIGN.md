# MEGA 2.0 — design

The agreed requirements, feature list and architecture. The user guide is
[README.md](README.md); this file is for whoever changes MEGA.

## The one rule

MEGA 2.0 is **self-sufficient**: it uses what Emacs ships and code written for
MEGA, and depends on no downloadable Elisp. MEGA 1 (`.mega.d`) pulled about 40
packages and 15 tree-sitter parsers; 2.0 pulls none.

| Decision | |
| --- | --- |
| Emacs | 31.1 or newer |
| Code allowed | Emacs built-ins + code written for MEGA. No packages, no vendored third-party files |
| Tree-sitter parsers | Emacs 31's own prompt offers to build one; MEGA has no installer |
| Completion popup | None is built in, so MEGA writes one on 31.1's terminal child frames |
| Project search | Live, as you type |
| Kept from MEGA 1 | Workspaces, Claude CLI, undo tree + persistent undo, indent guides |
| Added | Tasks, debugger, format on save, snippets, Dev Containers, vertical ruler |
| Not wanted | Git workflow beyond stock `vc`; spell and grammar checking |
| Dev Containers | MEGA-native subset; official `devcontainer` CLI when it is installed |
| Location | `.mega2.d`, beside `.mega.d` until that is removed; default chemacs2 profile |
| Own language modes | Markdown, Zig, justfile; a Rust fallback for when its parser is not built |

## Priorities

In descending order. When two conflict, the higher one wins.

**safety → privacy → security → stability → extensibility → maintainability → performance**

Examples of that ordering already decided:

- Backups and auto-saves cover private files too (safety over privacy), in a
  directory only the owner can read.
- Emacs asks before killing a running process on exit (safety over
  convenience); MEGA 1 did not.
- Startup tricks that risk misreading a file named on the command line are
  not used (stability over performance).

## Hard constraints

- **Emacs ≥ 31.1.** An older Emacs is left plain and told why; it is never
  half-configured.
- **No Elisp downloads.** `package.el` is not initialised and has no archives.
- **External programs are optional, never prerequisites.** Each is detected,
  and its feature is inert with a clear message when it is missing.
- **Terminal-first.** Fully functional under `emacs -nw` and tmux. Popups use
  TTY child frames with an echo-area or side-window fallback.
- **Launcher-neutral.** Works as a chemacs2 profile and with
  `--init-directory`; no file of MEGA mentions its launcher.

## Requirements, by priority

1. **Safety — never lose or damage your work.**
   - Backups and auto-save stay on, outside project trees, under hashed names
     so a deep path cannot make one uncreatable.
   - Deleting a file moves it to the trash.
   - Format on save is all-or-nothing and never blocks or aborts the save.
   - Persistent undo is restored only when the file content matches.
   - Nothing destructive without confirmation; nothing a repository defines
     runs automatically.
2. **Privacy — nothing leaves the machine unless you ask.**
   - MEGA opens no network connection and has no telemetry. The only
     sanctioned download is Emacs's parser prompt, after you answer yes.
   - Code goes to Claude only on an explicit command, and only the text you
     selected; with nothing selected, the function at point, in code only,
     after its size was shown and agreed to. On standard input, never on a
     command line; a private file needs a typed "yes".
   - A debugger's debuginfod lookups, which name what you debug to a
     server, are off: every debugger is started with `DEBUGINFOD_URLS`
     empty, lldb and those in a container included.
   - Language servers get telemetry switched off where they offer a switch,
     and a project's own server settings are merged under that, not over it.
   - State directories are 0700. The kill ring is never saved.
   - **One rule for what leaves no trace.** `mega-forgettable-file-p` is
     asked by everything that writes something about a file to disk: recent
     files, cursor places, the history of file prompts, recent projects,
     workspaces (down to the buffer names in a saved window layout) and
     persistent undo. It covers private files, by name or by where a link
     leads; temporary directories, `$TMPDIR` included; and files that exist
     for one command, such as a commit message.
3. **Security — a cloned repository cannot run code by being opened.**
   - `enable-local-variables :safe`, no local `eval`, no remote dir-locals.
   - `compilation-read-command` stays on: it is the only reason Emacs accepts
     a project's `compile-command`.
   - **Project trust.** Language servers, syntax checkers, formatters,
     tasks, debuggers and containers run code that belongs to the project
     (build scripts, macros, plugins, a Makefile). None of them starts in a
     project you have not trusted, and that includes what Emacs would start
     by itself: its on-the-fly checker runs `make` for C and `perl -c` for
     Perl. Trust is an act, `C-c y`, not an answer to a prompt met in
     passing: MEGA never asks from a hook, a timer or a process filter,
     only from a command that cannot go on without the answer. The
     modeline shows `untrusted` where tools are held back.
   - **What a decision covers.** A project, by its root. A file outside any
     project: its directory and nothing below, and no longer once a project
     appears there. The home directory and `/` are never a root, whatever
     marks them. Decisions are data, written whole or not at all, and read
     again when the file changes, so two sessions agree.
   - **Emacs's own launch points.** A project's `compile-command` is taken
     only in a trusted project. Every git that Emacs or MEGA starts runs
     with `core.fsmonitor` off and bare repositories refused unless named,
     because both are ways for a directory to run a program
     (`mega-git-hardening`).
   - A further approval, tied to a hash of `devcontainer.json` and of the
     files it names, before anything from it runs. The screen shows what
     will run, in order; what is mounted from the host; `privileged`; and
     what is left to the official CLI, when that is what will act on it.
   - A one-shot Claude question never runs in the project: `claude --print`
     skips that program's own trust question, and a project can carry
     settings that run commands. It runs in an empty directory with tools,
     MCP servers and project settings off.
   - Stored undo history is data: read, checked record by record, never
     evaluated. Records that call functions are neither written nor accepted.
   - Processes get argument lists, never shell strings built from file names
     or search input.
4. **Stability.**
   - A module that fails to load is skipped and reported.
   - Built-ins only. The places that lean on something Emacs keeps for
     itself — eglot's snippet hook, `undo-equiv-table` — are isolated,
     tested, and reported by the doctor if they change.
   - The configuration directory is read-only at runtime.
5. **Extensibility.** Keys, languages, kinds of project, snippets, picker
   sources and doctor sections are data tables or lists; machine overrides go
   in `local.el`, keys included (`mega-keys-add`).
6. **Maintainability.**
   - One module, one concern; explicit module list in `init.el`; no DSL;
     byte-compiles with zero warnings.
   - Every feature ships with unit tests; a feature without them is not done.
   - The user guide stays one short page.
7. **Performance.** Startup ≤ 100 ms in a terminal, counting what is put
   off until Emacs has started; heavy modules load on first use; typing is
   never blocked, and neither is a save: every formatter, the language
   server included, gets `mega-format-timeout` seconds and no more. These
   are goals and yield to everything above.

## Features

### Configured from built-ins

LSP through eglot (completion, diagnostics, hover, navigation, rename, code
actions, hierarchies, semantic highlighting); tree-sitter modes through
Emacs's own prompt; a vertical minibuffer with `flex` matching; the ruler;
a file tree (speedbar in a side window); imenu; diagnostics list; folding;
which-key; editorconfig; tabs; history, recent files and places; TRAMP;
project shell; editable grep results; GUD debuggers (gdb, lldb, pdb).

### Written for MEGA

| Feature | What it does |
| --- | --- |
| Popup | Child-frame popup primitive |
| Completion menu | Appears as you type; fed by the language server, snippets and the buffer |
| Live picker | Minibuffer picker with async sources, in-place toggles, export |
| Project search | `git grep -PnI` by default, `rg --hidden` or `grep` one key away (`C-o b`, which lasts for the session); toggles for case, untracked, ignored, submodules, hidden, literal/word, file glob |
| Project files | Emacs's own `C-c p f`, matching fuzzily. In a checkout the list is version control's; in a project without one MEGA lists it (`rg --files`, else `find`) and leaves out what a build made. Not cached |
| Tasks | Build / run / test per project, with jump to error |
| Format on save | editorconfig, then the language server or the language's own tool (rustfmt on the buffer; `cargo fmt` project-wide) |
| Snippets | LSP-syntax tab stops; user snippets per mode |
| Dev Containers | See below |
| Claude | Project session in a tmux pane or a terminal buffer; one-shot ask, explain and rewrite-with-diff through `claude --print` |
| Undo | Tree drawn from Emacs's own undo list; history persisted per file |
| Debugging | Picks the debugger and the program for the project; one set of keys for gdb, lldb and pdb. On the host through GUD, in a container through a debug adapter |
| Debug adapter client | Own client for the Debug Adapter Protocol: breakpoints that outlive sessions, stack, variables, output |
| Workspaces | The open files and the window layout, saved under a name and resumed |
| Small helpers | Indent guides, TODO highlight, symbol jump, trim changed lines, clipboard bridge |
| Modes | Markdown, Zig, justfile, Rust fallback |

### Not in 2.0

Spell and grammar checking; Git UI or margin marks; icons; kitty keyboard
protocol; multiple cursors; an API-key LLM client; Dev Container Features and
compose without the official CLI; RON mode; anything GUI-specific.

## Architecture

```
.mega2.d/
  early-init.el   version gate, where files go, startup cost
  init.el         the module list
  local.el        machine overrides (a stub; installed by hand)
  lisp/
    base      mega-lib  mega-core  mega-keys  mega-ui  mega-nord-theme
              mega-session  mega-help  mega-doctor
    kit       mega-popup  mega-pick  mega-exec  mega-project  mega-trust
              mega-lang  mega-compile
    features  mega-complete  mega-workspace  mega-home  mega-search
              mega-edit  mega-indent-guides  mega-undo  mega-undo-tree
              mega-snippet  mega-format  mega-lsp  mega-task  mega-debug
              mega-dap  mega-container  mega-remote  mega-llm  mega-zone
    modes     mega-mode-markdown  mega-mode-zig  mega-mode-just  mega-mode-rust
tests/mega2/      ERT suite and the two start-up probes (not deployed)
tests/test_mega2.sh
```

- **Layers, dependencies pointing down only:** features → kit → base → Emacs.
  A module `require`s what it calls, so the layering is in the code and not
  only in this picture: taking a feature off the list in `init.el` removes
  it, and taking a kit module off changes nothing while a feature needs it.
- **Source here, a compiled copy in the cache.** MEGA's Lisp is deployed
  as source, and nothing compiled is ever stored with it: not in this
  directory, which is read-only, and not in the repository. A start that
  finds no compiled copy runs the source and, once idle, has another Emacs
  make one in the cache directory (`mega-compile`); later starts load it,
  and Emacs's own JIT takes each compiled file it loads on to native code.
  `early-init.el` decides which is loaded, before the first module, by a
  fingerprint of every source file: a copy made from any other source is
  not used, so compiled code can be absent but never stale. A copy is made
  whole or not at all. The Emacs that makes it gets state directories of
  its own to throw away and leaves without running exit hooks: compiling a
  module loads the modules it needs, and one that saved something on the
  way out would save it over yours. None does today; this is so that none
  can.
- **Loading.** `init.el` lists every module. A bare name loads at startup; a
  list such as `(mega-doctor :commands (mega-doctor))` loads on first use.
- **Read-only configuration.** `init.el` points `user-emacs-directory` at the
  state directory, which catches every Emacs feature that writes there
  without asking. It is done in `init.el`, not `early-init.el`, because
  chemacs2 finds `init.el` through that variable. MEGA finds its own files
  through `mega-dir`.
- **Keys are a table.** `mega-keys` builds the keymap and the cheat sheet, so
  they cannot disagree; `mega-keys-add` and `mega-keys-remove` change both
  at once, from `local.el`, and a key whose command does not exist is
  dropped at start-up. The keys of the places that have their own (the
  completion menu, the undo tree, the home page) are described in
  `mega-keys-elsewhere`, and a test holds that description to the keymaps,
  key by key, in both directions.
- **Logic separate from display.** Popup, picker, completion menu and undo
  tree keep a model apart from the code that draws it, so the model is
  unit-testable without a terminal.
- **Two tables say what MEGA knows about code.** `mega-languages`, by
  language: the modes, the server candidates, the formatters, the
  indentation variable of each mode, the kind of debugger. Nothing else
  knows which modes make up a language; snippets name a language, not its
  modes. `mega-project-kinds`, by the file that marks a kind of project:
  whether it marks a root, its tasks, the command that formats all of it.
  `Cargo.toml` is named there once. What a module keeps beside them is for
  what is in neither: a mode of no language, your own tasks for one project.
- **`mega-exec` is the key abstraction** (from M1). Every process MEGA starts
  goes through it, as an argument list. The caller says where: the project's
  tools (its container if it has one), where the files are (never a
  container: a search, a file listing), or this machine whatever the buffer
  visits (the clipboard, tmux, the container program itself). And how long
  it can wait: `mega-exec-run` waits, interruptibly and with a limit that
  covers sending the input; `mega-exec-start` calls back; `mega-exec-open`
  hands over output as it comes, for a conversation such as a debug
  adapter's. A project on another machine is not a context: its directory
  is a remote file name and Emacs starts the program there. The few
  programs that need a terminal of their own (GUD, the Claude session, a
  container shell) get their argument list from `mega-exec-command`. That
  is what makes containers a cross-cutting feature and not a rewrite of
  each module.
- **Dev Containers.** Parse `devcontainer.json` (own JSON-with-comments
  reader), show what it will do and wait for approval, then start: with
  `devcontainer up` if that CLI exists, else podman/docker directly. The
  start runs in the background, a step at a time, with a log; Emacs is
  never held. Every key of the file is in one of three lists: acted on
  (image, mounts, runArgs, capAdd, securityOpt, privileged, init, the
  environment, users, ports, the lifecycle commands), harmless to ignore,
  or impossible without the official CLI (build, features, compose).
  Without that CLI the last kind is refused by name, and so is a key in
  none of the lists: MEGA does not guess at a setting. With it, both are
  listed on the approval screen as the CLI's to act on. Files stay on the host and tools run in the container, with one
  path-mapping layer, applied per language server; container-only files
  open through TRAMP.
- **Undo has no data structure of its own.** The tree is read off
  `buffer-undo-list` and `undo-equiv-table` each time it is drawn, and a
  move is a replay of the records between two states, recorded like any
  other change. The only thing that could ever be wrong is the claim "the
  text is now in that older state", so it is made only when the replay ran
  exactly from one state to the other. Two consequences, both deliberate:
  Emacs's "undone all the way back" is not believed (it does not say back
  to where, and Emacs discards old history), so that state is drawn as a
  node of its own; and MEGA's own mark for the oldest state is dropped the
  moment the end of the list changes.
- **Two debugger interfaces, one set of keys.** On the host MEGA starts
  Emacs's own (GUD), which is mature and costs no code. In a container the
  full form of that needs a terminal of the host, so MEGA talks to the
  debugger as a debug adapter instead (`mega-dap`), over the same
  `podman exec` every other tool uses. `mega-debug-backend` overrides the
  rule; an adapter that is missing or too old falls back to GUD. The
  client is three layers — bytes, session, display — and wholly
  asynchronous: a key sends a request and returns.
- **The debugger is chosen before the interface.** `mega-debug-prefer`
  ranks the families, lldb before gdb by default, and outranks the choice
  of interface: lldb through its console is taken before gdb through an
  adapter. Both lists of candidates carry a `:family`, and
  `mega-debug-plan` is the one place the two are weighed.
- **The adapter client was written against recordings, not the
  specification.** Real conversations with gdb 16 and lldb-dap 19 were
  captured first, and the test stand-in plays either back with its habits
  intact, because they disagree on every point that matters: gdb says
  "initialized" at once and answers `launch` only after
  `configurationDone`, lldb the other way round; gdb's breakpoints start
  unverified and its frame ids go stale at every stop; lldb announces a
  step before answering it, ends the program's lines with CR LF, and
  crashes with a page of backtrace when told to disconnect. And they cut
  a frame's variables up differently: lldb gives one scope with arguments
  and locals in it, gdb gives the two apart and leaves out whichever would
  be empty; both say which is which, and neither marks the registers as
  costly to read.
- **Programs that take long** (`claude --print`) go through
  `mega-exec-start`, which returns at once and calls back; a mistake in the
  callback is reported, not raised, because it runs in the middle of
  whatever else is happening.

## Milestones

| | Delivers | Status |
| --- | --- | --- |
| M0 | Skeleton: init, base modules, theme, modeline, ruler, session, doctor, cheat sheet, tests, guide | done |
| M1 | Minibuffer, live prompt, `mega-exec`, file finder, live search, project keys, file tree | done |
| — | Home page and workspaces (requested after M0; workspaces moved up from M5) | done |
| M2 | Popup, completion menu, eglot, language table, parser prompt, the four modes | done |
| M3 | Project trust, format on save, snippets, tasks, indent guides, small edit helpers | done |
| M4 | Dev Containers: native subset, hand-over to the official CLI | done |
| M5 | GUD debugging, Claude, undo tree + persistence, remote, zone | done |
| M6 | Debug adapter client, used for debugging in a container | done |
| — | MEGA compiles itself: a compiled copy in the cache, made in the background, native through Emacs's JIT (requested after the review) | done |
| — | Architecture review, 37 findings: trust as an act and not a prompt, Emacs's own launch points gated, one process layer with three places, one rule for what leaves no trace, the two tables, tests over the wire, the bench rebuilt | done |

Each milestone ends with its unit tests, doctor rows and guide entries.

## Testing

`tests/test_mega2.sh` runs five stages in a sandbox, without the network,
and a sixth when it is asked for by name:

| Stage | Checks |
| --- | --- |
| lint | Every file byte-compiles with warnings as errors |
| unit | The ERT suite, twice: on MEGA's Lisp as source and on its compiled copy, each against a session started from the real init files. A test that waits for something that never comes is stopped and Emacs says where it was waiting |
| boot | Startup, from source and from the compiled copy, fails no module, runs no program, opens no connection, and fits the time budget, what is put off until Emacs has started included |
| bench | What a person waits for, each against what it is expected to take: a keystroke, the modeline, the completion menu, listing and matching files, search, save, undo history and tree, debugger messages, first use of a module and of a language server |
| terminal | Real sessions in a pseudo-terminal: 24-bit, 256 and 8 colours, under a tmux terminal type, through chemacs2, and an old Emacs being refused. And four starts in a row on one cache, as after an update: the first makes the compiled copy, the second runs from it, the third waits while Emacs compiles that to native code, the fourth is native from its first moment |
| container | Only with `MEGA_REAL_IMAGE` set and named on the command line. A real container, started by podman from a `devcontainer.json` with no network and removed afterwards: programs run and a project built in it, and a program debugged with each debugger the image has, through the adapter client and through its console |

Afterwards the configuration directory must be byte-for-byte what it was.

The bench stage is how performance, last of the priorities, is still kept
honest. Each benchmark states what it took on the machine the figures were
set on, and the run prints every time beside that figure. Over one and a
half times it, a line is marked `SLOW` and the run passes; over three
times, it fails. Two fixed pieces of work, one of Lisp and one of starting
programs and using the disk, say how slow the machine is right now, and the
figures are stretched by that; they are taken at the start and at the end,
and again before any benchmark is called a failure, which is then run a
second time. Memory is collected as in a running session. A run can be
saved and compared with (`MEGA_BENCH_SAVE`, `MEGA_BENCH_COMPARE`).

The expected times are kept apart from the benchmarks, in
`tests/mega2/mega-bench-history.eld`: for each, every time it was ever held
to, with the date, the commit that changed what it takes, and the reason.
A benchmark has no number of its own, so a time cannot be raised without a
record, and the stage fails on a record that lacks its commit or its
reason, or names a commit the repository does not have. The rule is in
that file and is short: over its time, a benchmark is first explained (the
stage prints the `git bisect` command, starting from the commit of the
last record), then fixed; the time goes up only when the slowdown is the
reasonable, direct and minimised price of a change that is wanted, and
then whoever introduced it adds the record. The commit comes first and the
record after it, in a commit of its own. The
harness was itself tried both ways: a threefold slowdown put into a copy of
the code fails it, and a machine kept busy by twice as many spinning
processes as it has processors does not. A new feature with something a
person waits on gets a benchmark in `tests/mega2/mega-bench.el`.

The promises about security and privacy are tested by what happens, not by
what a variable holds: a file of every kind is opened in an untrusted
directory and the programs that start are counted; a secret is edited,
saved and closed, and the state directory is searched for its name; the
stand-in language server writes down what it was told, so "telemetry is
off" is read from the wire.

Things learned while building it, worth keeping in mind:

- Emacs renders no modeline and runs no `emacs-startup-hook` in batch mode.
  Anything that depends on either belongs in the terminal stage, and a probe
  must print an explicit verdict: a clean exit proves nothing.
- Emacs is idle only while it waits for a key with no time limit; not in a
  hook, not in `sit-for`. What MEGA postpones until after startup can
  therefore only be observed by a probe that itself runs from an idle
  timer, which is how the terminal probe runs.
- A batch Emacs is killed, silently, by writing to a program that has
  closed its input (the Emacs you edit in gets an error instead). Stand-in
  programs in the tests read their input; the real case is tried in the
  terminal stage.
- A variable that becomes buffer-local when set needs `setq-default`. A unit
  test scans MEGA's source for plain `setq` on such variables.
- Emacs makes no backups under the temporary directory, which is where the
  sandbox lives; tests that need one lift that rule explicitly.
- In batch mode an error in a process sentinel ends Emacs, and with it the
  whole test run, silently. Code that runs in a sentinel catches its errors.
- ERT runs tests with `debug-on-error` on, which lets errors through
  `with-demoted-errors`. A test of "this failure is only a message" has to
  switch it off.
- A synchronous request to a language server has no time limit in Emacs
  31: eglot passes "none" explicitly, so `jsonrpc-default-request-timeout`
  is never consulted. Anything MEGA asks a server from a hook is bounded
  from outside, with `with-timeout`. Found by a stand-in server that never
  answers; binding the variable had passed review and every other test.
- Emacs remembers whether a directory is in a checkout, and gives a caller
  that does not prompt an answer up to five minutes old. MEGA decides by the
  project's root what may run, so `mega-project-current` asks for the
  two-second answer a command gets.
- ripgrep reads a `.gitignore` only inside a repository unless told
  otherwise (`--no-require-git`), so in a project without version control
  nothing keeps it out of `target/` but MEGA.
- A shell's arithmetic prints a decimal comma in half the world's locales.
  The runner's does not (`LC_ALL=C`).
- Emacs's JIT compiles to native code what it loads *compiled*. Source
  that is loaded as source stays interpreted for good: with nothing to
  byte-compile MEGA's files, none of them was ever native, whatever the
  build of Emacs. And a compiled file is taken on to native code only if
  its source lies beside it, which is why the copy in the cache holds
  both.
- `secure-hash` and `md5` take a coding system into account, and on half
  a megabyte that costs seven milliseconds; `buffer-hash` takes the bytes
  as they are and costs half of one. The fingerprint is computed at every
  start.
- Compiling one module loads the modules it requires, in an Emacs that
  only came to compile. Were one of those a module that saves history when
  Emacs ends, it would save an empty one over yours. Tried without any
  protection, nothing was written: no module requires such a one today.
  The compiling Emacs is still given directories of its own and leaves
  without running exit hooks, so that this stays true whoever requires
  what later.
- A stand-in does what its author knew the real thing to do. The first
  run of the container stage found three faults that every test with a
  stand-in had passed: the commands of a `devcontainer.json` ran before the
  container's own `PATH` was read, so a `PATH` built on it found nothing;
  lldb's adapter starts no program where the kernel refuses to fix
  addresses, which is any container with its system-call filter on; and
  with gdb only a function's arguments were shown, because gdb lists
  arguments, locals and registers as three scopes, marks none as costly,
  and the recording the stand-in was written from came from a function
  without arguments. Each has a unit test now, and the stand-ins were
  corrected to what was recorded.
- A probe that plays the person must not say yes to everything: it will
  agree to something nobody meant. The container probe answers the
  questions it names, reports any other as a failure, and runs with a `git`
  that refuses to fetch.
- A variable of a library that is not loaded yet is not special. Bound
  with `let` in a file with lexical binding it switches nothing off, and
  the library then fails to load inside that `let`. Declare it first.
- Tests are worth only what they can fail on. Each milestone's safety,
  privacy and security checks were run against deliberately broken copies
  of the code (`MEGA_TEST_CONFIG` points the suite at a copy).

## Installing and updating

`update.sh` at the top of the repo installs MEGA (`install mega2`) and
updates it by the same command; `user`, which deploys every dotfile, does the
same for MEGA's directory. Either way `~/.mega2.d` ends up holding exactly
the repo's files. The script keeps a list of what it installed, under
`~/.local/state/dotfiles/`, and on the next run removes from `~/.mega2.d`
what is on the old list and not on the new one, after backing it up; a file
it never listed is never removed, and a list is believed only about paths
inside the directory it belongs to. `uninstall mega2` removes what is
listed and the compiled copies in the cache, keeps `local.el`, the state
directory and the backups of your files, and leaves a mark so that `user`
does not put MEGA back.

What makes an update safe on MEGA's side is that nothing it keeps is
trusted on the way back in: the trust store, workspaces, undo histories and
approvals are data, checked when read, and ignored when they do not check,
which costs a question asked again and never a file. The compiled copy is
used only for the source it was made from. And MEGA writes nothing into
`~/.mega2.d` or the repo, so there is no state there for an update to
collide with.

## Open points

- **What compiling buys**, measured on the machine the bench figures were
  set on. Start-up: 50 ms as source, 36 ms from the compiled copy, 27 ms
  as native code. Compiled against source, the large factors are in the
  undo code (a megabyte of history brought back in 7 ms instead of 75, a
  move in a tree of 2000 changes in 1.5 ms instead of 12); a keystroke
  costs 0.020 ms instead of 0.027. The bench stage times the source, which
  is the slowest MEGA ever runs and the only form every machine has from
  the first start.
- **What it leaves behind.** About 1 MB for the compiled copy and 5 to 8 MB
  of native code, under `~/.cache/mega2`. Emacs keeps the native file of
  every version of a module it ever compiled; nothing prunes those.
  Deleting the cache directory is always safe.
- **Native compilation is Emacs's.** MEGA makes the compiled copy; the
  step from there to native code is Emacs's JIT, left as it comes, and it
  takes what a session loads: the modules loaded at start in the first
  session (about a quarter of a minute of background work), one that loads
  on first use in the session that first uses it. The boot test switches
  the JIT off to listen for MEGA alone.
- **Parsers.** An Emacs built against tree-sitter 0.20 accepts ABI 13–14 only.
- **Claude in the built-in terminal emulator** may render imperfectly. Inside
  tmux the session opens in a pane instead, which is the default there.
  Neither has been tried against the real program by the tests, which use a
  stand-in. The arguments of `mega-claude-print-arguments` are taken from
  the program's own help and their values pass its checks, but no question
  has been sent with them: that would have been a request nobody asked for.
- **Debugging in a container** is run for real by the container stage:
  lldb 19 and gdb 16.3, each through the adapter client and through its
  console (the fallback), with a breakpoint set from the buffer on the host
  and the line followed in the host's file. It needs nothing of the
  container: no added capability, no system-call filter switched off.
  Where the kernel will not fix a program's addresses MEGA finds that out
  first and tells lldb not to insist (`mega-dap--fixed-addresses-p`); the
  price there is that addresses differ from run to run.
- **Adapters.** lldb-dap and gdb are in `mega-dap-adapters`; both were run
  for real, lldb also on a Rust program (with the scripts Rust ships, a
  `String` shows as its text). debugpy would be one more row with a
  `:launch` function. Not done: conditional breakpoints, watch expressions,
  expanding a structure in the variables list, several threads shown at
  once, attaching to a running program, and giving the program arguments
  or input.
- **lldb through GUD in a container** works, but a command given in the
  first second is lost: Emacs's lldb interface sets lldb up by feeding it
  Python, and without a terminal lldb takes whatever arrives meanwhile as
  more Python. On the host lldb could not be tried at all: none is
  installed.
- **A project without version control** is recognised by a manifest at its
  root (`mega-project-markers`, by default the kinds marked `:root` in
  `mega-project-kinds`). The list is deliberately short; a Makefile is not
  on it, because one may sit in any directory. What a build put there is
  left out of its files and of a search by name
  (`mega-project-ignored-directories`), since no ignore file says so.
- **Trust is by path.** A decision is kept for the root's file name, not
  for the repository's identity: a different project unpacked at a path you
  once trusted is trusted. Storing an identity beside the path was
  considered in review and left out: there is none that a hostile checkout
  could not copy.
- **Undo tree extras** left out: a diff between two states, and marking the
  state that is saved on disk.
- **One ruler.** Emacs draws a single ruler; several at once would be new code.
- **Breakpoints with GUD** still need a running debugger: only the adapter
  path keeps them between sessions.
