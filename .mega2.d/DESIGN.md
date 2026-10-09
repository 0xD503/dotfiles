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
     selected (or the function at point); on standard input, never on a
     command line; a private file needs a typed "yes".
   - gdb's debuginfod lookups, which name what you debug to a server, are
     off.
   - Language servers get telemetry switched off where they offer a switch.
   - State directories are 0700. The kill ring is never saved. Files matched
     by `mega-private-file-p` are left out of recent files, saved places and
     persistent undo.
3. **Security — a cloned repository cannot run code by being opened.**
   - `enable-local-variables :safe`, no local `eval`, no remote dir-locals.
   - `compilation-read-command` stays on: it is the only reason Emacs accepts
     a project's `compile-command`.
   - **Project trust.** Language servers, formatters and build tools run
     code that belongs to the project (build scripts, macros, plugins). MEGA
     asks once per project before it starts any of them, remembers the
     answer, and in an untrusted project only edits text.
   - A further prompt, tied to the file's hash, before anything from
     `devcontainer.json` runs.
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
5. **Extensibility.** Keys, languages, formatters, tasks, snippets, picker
   sources and doctor sections are data tables or lists; machine overrides go
   in `local.el`.
6. **Maintainability.**
   - One module, one concern; explicit module list in `init.el`; no DSL;
     byte-compiles with zero warnings.
   - Every feature ships with unit tests; a feature without them is not done.
   - The user guide stays one short page.
7. **Performance.** Startup ≤ 100 ms in a terminal; heavy modules load on
   first use; typing is never blocked. These are goals and yield to
   everything above.

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
| Completion menu | Appears as you type, with a documentation popup |
| Live picker | Minibuffer picker with async sources, in-place toggles, export |
| Project search | `git grep -PnI` or `rg --hidden`; toggles for case, untracked, hidden, ignored, literal/word, file glob |
| File finder | Fuzzy over `git ls-files` / `rg --files` / `fd`, cached per project |
| Tasks | Build / run / test per project, with jump to error |
| Format on save | editorconfig, then the language server or the language's own tool (rustfmt on the buffer; `cargo fmt` project-wide) |
| Snippets | LSP-syntax tab stops; user snippets per mode |
| Dev Containers | See below |
| Claude | Project session in a tmux pane or a terminal buffer; one-shot ask, explain and rewrite-with-diff through `claude --print` |
| Undo | Tree drawn from Emacs's own undo list; history persisted per file |
| Debugging | Picks the GUD front end and the program for the project; one set of keys for gdb, lldb and pdb |
| Workspaces | Named tab layouts saved and resumed |
| Small helpers | Indent guides, TODO highlight, symbol jump, trim changed lines, clipboard bridge |
| Modes | Markdown, Zig, justfile, Rust fallback |
| DAP client | Last milestone, optional |

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
    kit       mega-popup  mega-pick  mega-exec                      (M1, M2)
    features  mega-complete  mega-project  mega-workspace  mega-home
              mega-search  mega-edit  mega-indent-guides  mega-trust
              mega-undo  mega-undo-tree  mega-snippet  mega-format
              mega-lsp  mega-lang  mega-task  mega-debug  mega-container
              mega-remote  mega-llm  mega-zone                      (M1–M5)
    modes     mega-mode-markdown  mega-mode-zig  mega-mode-just  mega-mode-rust
tests/mega2/      ERT suite and the two start-up probes (not deployed)
tests/test_mega2.sh
```

- **Layers, dependencies pointing down only:** features → kit → base → Emacs.
- **Loading.** `init.el` lists every module. A bare name loads at startup; a
  list such as `(mega-doctor :commands (mega-doctor))` loads on first use.
- **Read-only configuration.** `init.el` points `user-emacs-directory` at the
  state directory, which catches every Emacs feature that writes there
  without asking. It is done in `init.el`, not `early-init.el`, because
  chemacs2 finds `init.el` through that variable. MEGA finds its own files
  through `mega-dir`.
- **Keys are a table.** `mega-keys` builds the keymap and the cheat sheet, so
  they cannot disagree.
- **Logic separate from display.** Popup, picker, completion menu and undo
  tree keep a model apart from the code that draws it, so the model is
  unit-testable without a terminal.
- **Languages are data.** One row names the modes, optional server
  candidates, formatter, debugger and fallback mode.
- **`mega-exec` is the key abstraction** (from M1). Every process MEGA starts
  goes through it, as an argument list, and it knows the project's context:
  local, dev container, or TRAMP. That is what makes containers a
  cross-cutting feature and not a rewrite of each module.
- **Dev Containers.** Parse `devcontainer.json` (own JSON-with-comments
  reader), trust prompt, then `devcontainer up` if that CLI exists, else
  podman/docker directly (image, initializeCommand, mounts, runArgs, capAdd,
  securityOpt, env, remoteUser, ports, lifecycle commands; anything else is
  refused by name). Files stay on the host and tools run in the container,
  with one path-mapping layer; container-only files open through TRAMP.
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
| M6 | DAP client (optional) | not started |

Each milestone ends with its unit tests, doctor rows and guide entries.

## Testing

`tests/test_mega2.sh` runs four stages in a sandbox, without the network:

| Stage | Checks |
| --- | --- |
| lint | Every file byte-compiles with warnings as errors |
| unit | The ERT suite, against a session started from the real init files |
| boot | Startup fails no module, runs no program, opens no connection, and fits the time budget |
| terminal | Real sessions in a pseudo-terminal: 24-bit, 256 and 8 colours, under a tmux terminal type, through chemacs2, and an old Emacs being refused |

Afterwards the configuration directory must be byte-for-byte what it was.

Three things learned while building it, worth keeping in mind:

- Emacs renders no modeline and runs no `emacs-startup-hook` in batch mode.
  Anything that depends on either belongs in the terminal stage, and a probe
  must print an explicit verdict: a clean exit proves nothing.
- A variable that becomes buffer-local when set needs `setq-default`. A unit
  test scans MEGA's source for plain `setq` on such variables.
- Emacs makes no backups under the temporary directory, which is where the
  sandbox lives; tests that need one lift that rule explicitly.
- In batch mode an error in a process sentinel ends Emacs, and with it the
  whole test run, silently. Code that runs in a sentinel catches its errors.
- ERT runs tests with `debug-on-error` on, which lets errors through
  `with-demoted-errors`. A test of "this failure is only a message" has to
  switch it off.
- Tests are worth only what they can fail on. Each milestone's safety,
  privacy and security checks were run against deliberately broken copies
  of the code (`MEGA_TEST_CONFIG` points the suite at a copy).

## Open points

- **Compiling MEGA's own Lisp.** It runs as source. If a hot path (fuzzy
  scoring, in M1) needs compiling, the output must go to the cache directory.
- **Native compilation.** Emacs compiles its bundled libraries in the
  background the first time each is loaded. That is Emacs, not MEGA, and it
  is left on; the boot test switches it off to listen for MEGA alone.
- **Parsers.** An Emacs built against tree-sitter 0.20 accepts ABI 13–14 only.
- **Claude in the built-in terminal emulator** may render imperfectly. Inside
  tmux the session opens in a pane instead, which is the default there.
  Neither has been tried against the real program by the tests, which use a
  stand-in. The arguments of `mega-claude-print-arguments` are taken from
  the program's own help and their values pass its checks, but no question
  has been sent with them: that would have been a request nobody asked for.
- **Debugging in a container** uses gdb's plain interface (`gud-gdb`), since
  the full one wants a terminal of the host for the program's input and
  output. Beyond the stand-ins of the suite it was run once for real: gdb
  16.3 inside a container made from a `devcontainer.json`, breakpoint set
  from the host buffer, the arrow following in the host file.
- **Undo tree extras** left out: a diff between two states, and marking the
  state that is saved on disk.
- **One ruler.** Emacs draws a single ruler; several at once would be new code.
- **DAP** is the largest single piece and has not been started.
