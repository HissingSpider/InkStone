# How Inkstone works

## The pipeline

```
inbox scan ─► file hash ─► [unchanged? stop]
                 │
                 ▼
          PDFPageRenderer ─► page fingerprint ─► [unchanged? serve from cache]
                 │
                 ▼
         render at 300 DPI
                 │
       ┌─────────┴─────────┐
       ▼                   ▼
   VisionOCR         DiagramExtractor
  (text blocks)     (text-box subtraction)
       │                   │
       └─────────┬─────────┘
                 ▼
          ConfidenceGate ──[bad page]──► VLMClient ──► markdown
                 │
                 ▼
          MarkdownBuilder ─► NoteComposer ─► VaultWriter ─► vault
                                                  │
                                                  └─ hash check ─► sidecar if edited
```

Source layout mirrors that: one file per box, in `Sources/InkstoneCore/`.

## Everything expensive is behind a hash

Two levels of change detection, because they cost different amounts.

**Document level.** A SHA-256 of the PDF's bytes, streamed in 1 MiB chunks. If
it matches what the state store recorded, the file is never even opened. In
steady state this is the entire cost of a run.

**Page level.** Each page is rendered at a fixed 96-pixel width in greyscale and
hashed. Fixed width rather than the configured DPI, so changing `renderDPI` does
not invalidate every fingerprint in the database. A page whose fingerprint
matches is served from the state store, which caches the page's finished
Markdown and its diagram list — so an unchanged page never pays for OCR again.

The result is that a daily run over a 200-page notebook with one new page costs
one file hash, 200 thumbnails, and one page of real work.

Page bitmaps are hashed through a tightly packed 8-bit grey buffer rather than
the raw CGImage backing store, because CoreGraphics chooses row padding based on
width and the padding bytes would otherwise leak into the hash.

## Reading order

Vision returns observations in a stable order that is not reading order, and it
splits one handwritten line into several observations whenever the pen lifts for
long enough. `VisionOCR.groupIntoLines` reassembles them: blocks join a line when
their vertical spans overlap by more than half the shorter block's height —
proportional rather than absolute, so a title and a footnote on the same page are
both handled — then sort left to right within the line.

## Diagram extraction is subtraction, not classification

The interesting move. Vision already tells us where every word is. Whatever ink
remains after erasing those boxes is, by elimination, drawing.

1. Threshold the page into an ink mask, downsampled to ~6-pixel cells so
   connected-component labelling runs over ~200k cells instead of 8M pixels.
2. Zero out every cell covered by a text bounding box, grown by 35% of its
   height so ascenders and descenders come out too.
3. Label the remaining components with an iterative flood fill (iterative
   because a full-page sketch is one component with tens of thousands of cells,
   and recursion would blow the stack).
4. Merge components whose boxes come within a few cells of each other — a
   diagram is rarely one connected stroke.
5. Reject candidates below a minimum area, below a minimum ink density (which
   kills a large empty box formed by two far-apart specks), and hairlines that
   are wide but two cells tall (page rules, underlines).

This inherits Vision's own judgement about what counts as text, which is far
more reliable than trying to classify strokes directly.

The same pass yields the page's total ink coverage, which the confidence gate
uses for its most useful signal.

## The confidence gate

Vision's confidence alone is misleading: it reports high confidence on a page it
barely read, because it is sure about the six words it found and silent about
the rest. The gate blends four terms:

| Signal | Weight | Catches |
| --- | --- | --- |
| Character-weighted mean confidence | 0.50 | Ordinary bad recognition |
| Share of lines below threshold | 0.20 | A few good lines hiding many bad ones |
| Non-language character ratio | 0.15 | OCR that has lost the plot |
| Text yield per unit of ink | 0.15 | Dense cursive Vision gave up on |

A near-blank page short-circuits to a perfect score. A blank page is a confident
"nothing here", not a failed transcription, and escalating it to a paid model
would be pure waste.

## Section splitting

`--granularity section` exists because handwriting apps cap notebook counts,
which pushes people to keep several subjects in one book.

A section starts at any page whose first line is a markdown heading. The check
runs against the page's *finished markdown*, not its raw OCR lines, which means
it works identically for locally recognised and cloud-transcribed pages and
costs nothing for a cached page, because the markdown is already in the state
store.

Candidate titles are filtered: three to sixty characters, at most six words, and
at least one letter. That keeps a long sentence written large, or a smear of OCR
punctuation, from becoming a note name.

Routing for a section prefers a rule matching the section title, falling back to
nesting under the notebook rather than to the vault's default folder — otherwise
every unrouted section from every notebook would pile into one directory and two
notebooks containing a "Standup" would overwrite each other on alternate runs.
Within one notebook, repeated headings are disambiguated with a numeric suffix.

## Edit protection

`VaultWriter` stores the hash of exactly what it wrote. Before overwriting, it
hashes the file on disk. Three outcomes:

- **Hashes match** — the file is untouched since Inkstone wrote it. Overwrite.
- **No stored hash** — a pre-existing file we did not create. Sidecar.
- **Hashes differ** — a human edited it. Sidecar.

Plus `inkstone_lock: true` in frontmatter, which wins over everything including
`--force`, because that is the user saying the note is theirs now.

The original `created:` date is carried forward on every rewrite, so re-runs do
not make every note look newly created. Frontmatter keys emit in a fixed order
for the same reason: a new field must not silently reorder an existing note and
produce a spurious diff in the user's vault history.

## State

SQLite at `~/Library/Application Support/Inkstone/state.sqlite3`, WAL mode,
five-second busy timeout. Four tables: `documents`, `pages`, `notes`, `runs`.

Single-writer by design. The CLI, the launchd agents and the menu-bar app all go
through the same file, which is what makes the menu bar show the truth about
what the scheduled agent did rather than a second, drifting copy of it.

Document paths are canonicalised with `resolvingSymlinksInPath()` before use as
keys, so the same PDF reached through `/var` and `/private/var` cannot grow two
sets of page rows and re-OCR itself forever.

## Debouncing

`FolderWatcher` uses FSEvents with `kFSEventStreamCreateFlagFileEvents` for
per-file paths, then waits for a quiet period — 20 seconds by default — before
firing.

This is not a nicety. Google Drive writes a synced PDF in pieces and renames it
into place, so one backup produces a burst of events over several seconds.
Running on the first one would read a truncated file.

The `watch` command also does a full pass on startup, because a resident process
must not fall behind while it was not running.

## No dependencies

`Package.swift` has no external packages. SQLite through the system C API, the
Anthropic client hand-rolled over `URLSession`, argument parsing hand-rolled.
`swift build` works on a machine with no network and no package cache, which is
the right property for a tool whose job is running unattended on one Mac for
years.
