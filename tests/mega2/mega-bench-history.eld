;;; mega-bench-history.eld --- What each benchmark is expected to take, and why  -*- lisp-data -*-

;; Data, read by mega-bench.el; never evaluated.  This file is the one place
;; a benchmark's expected time is written down.  There is no number beside
;; the benchmark itself, so a time cannot be changed without leaving a line
;; here that says who made the thing slower, and why.
;;
;; An entry is (NAME RECORD...), the oldest record first; the last one is
;; what the benchmark is held to.  A record is a plist:
;;
;;   :ms      what it takes on the reference machine, in milliseconds
;;   :limit   where three times that is the wrong measure (something done
;;            once, on a disk that may be cold): what it may take at most
;;   :date    the day the record was made, as YYYY-MM-DD
;;   :commit  the commit that changed what the benchmark takes: the one that
;;            added it, or the one that made it slower, or faster
;;   :reason  why: for a slowdown, what was got in exchange, and why it
;;            could not be had for less
;;
;; The first two entries are not benchmarks.  They are the two pieces of
;; work that say how fast a machine is, as the reference machine did them;
;; every other figure is in their terms, so they change only when all the
;; figures are taken again, on another machine.
;;
;; WHEN A BENCHMARK IS OVER ITS TIME
;;
;; The bench stage marks a line SLOW at one and a half times what is
;; expected, and fails at three times.  Either way, whoever sees it:
;;
;; 1. Finds the cause first.  The commit of the last record is one at which
;;    the figure held, so the commit that broke it can be searched for:
;;
;;      git bisect start HEAD <that commit>
;;      git bisect run env MEGA_BENCH_ONLY='<name>' tests/test_mega2.sh bench
;;
;; 2. Fixes it, if it can be fixed.  A slowdown that nobody decided on is a
;;    bug like any other.
;;
;; 3. Only if the slowdown is the direct price of a change that is wanted,
;;    is reasonable for what the change gives, and has been made as small
;;    as it can be: adds a record here, with the new time, the commit that
;;    introduced the slowdown, and the reason.  The commit comes first and
;;    the record after it, in a commit of its own: a record names a commit,
;;    and a commit has no name until it is made.
;;
;; A benchmark that got faster is recorded the same way.  Nothing is ever
;; removed from an entry: the old records are the history.
;;
;; The bench stage checks this file each time it runs: every benchmark has
;; an entry and every entry a benchmark, every record is complete, the dates
;; do not go backwards, and every commit named is one that the checked-out
;; history contains.

(("the reference machine: computing"
  (:ms 84.0 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("the reference machine: programs and disk"
  (:ms 20.5 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("first use of a feature: load its module (slowest)"
  (:ms 2.3 :limit 40 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("type 1000 characters in code"
  (:ms 26 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("type 1000 characters in Rust, each one highlighted"
  (:ms 97 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("modeline: what MEGA works out for it, 5000 times"
  (:ms 12.7 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("completion menu: choose from 5000 candidates"
  (:ms 3.6 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("completion menu: draw it 300 times"
  (:ms 17 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("project files: list 3000, pass over 3000 built ones"
  (:ms 7.6 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("narrow 100,000 file names at the prompt (Emacs's flex)"
  (:ms 165 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("search: show 2000 hits"
  (:ms 5.3 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("search: a real one, 300 files, with grep"
  (:ms 4.6 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("run a program and wait for it, ten times"
  (:ms 7 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("copy to and paste from the clipboard, ten times"
  (:ms 22 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("format a 2000-line buffer on save"
  (:ms 5 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("open 4000 lines, highlighted: mega-rust-mode"
  (:ms 104 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("open 4000 lines, highlighted: mega-zig-mode"
  (:ms 99 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("open 4000 lines, highlighted: mega-markdown-mode"
  (:ms 11 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("indentation guides over 4000 lines"
  (:ms 79 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("save a file after a small edit, ten times"
  (:ms 12 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("save a file with a megabyte of undo history"
  (:ms 38 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("open a file and get its undo history back"
  (:ms 70 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("undo tree: draw a history of 2000 changes"
  (:ms 16 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("undo tree: twenty moves in a history of 2000 changes"
  (:ms 241 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("debugger: take in 1000 messages"
  (:ms 2.9 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("draw the home page 50 times"
  (:ms 111 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("draw the cheat sheet 20 times"
  (:ms 6.2 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review."))
 ("language server: load eglot and connect, first time"
  (:ms 62 :limit 400 :date "2026-10-10" :commit "ea12a01"
   :reason "Established: the bench as rebuilt after the architecture review.")))
