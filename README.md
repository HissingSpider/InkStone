# Inkstone

Handwritten notebooks in, Obsidian notes out.

Inkstone watches the folder your GoodNotes Auto-Backup syncs into, transcribes
new handwriting with Apple's Vision framework, crops the drawings out as images,
and writes the result into your vault as Markdown — on a schedule, without being
asked, and without ever overwriting something you edited yourself.

```
GoodNotes → cloud drive → PDF pages → Vision OCR → Markdown + PNG diagrams → your vault
```

Everything runs on the machine. The cloud model is optional, off by default, and
only ever sees a page the local recogniser already failed on.

---

## Install

Requires macOS 14 or later and a Swift 6 toolchain (Xcode or the Command Line
Tools).

```bash
git clone <this repo> && cd InkStone
make install
```

That builds `Inkstone.app` into `~/Applications` and links the `inkstone` CLI
into `/usr/local/bin`.

Then:

```bash
inkstone init      # detects your vault and cloud folder, writes a config
inkstone doctor    # checks the whole chain and says what to fix
inkstone run       # transcribe everything new
```

Setting up the GoodNotes side is a separate, one-time job:
**[docs/goodnotes-auto-backup.md](docs/goodnotes-auto-backup.md)**.

---

## Running it unattended

```bash
inkstone install-agent --at 22:00
```

This installs two launchd agents, and they answer different questions.

The **daily agent** is a floor: notes appear even if the Mac was asleep when the
backup landed. The **watcher** is immediacy: a notebook synced at lunchtime is
transcribed a minute later. Running both is cheap, because an unchanged inbox
costs a handful of file hashes and nothing else.

The menu-bar app shows the last run, surfaces anything `doctor` would complain
about, and has a **Process now** button for when you do not want to wait.

Remove them with `inkstone uninstall-agent`.

---

## What ends up in the vault

```markdown
---
title: Field Notes
source: Field Notes.pdf
pages: 12
created: 2026-08-24
updated: 2026-08-24
transcriber: inkstone
ocr: mixed
quality: 0.88
needs_review: true
low_confidence_pages: [7]
tags: [inkstone, handwritten]
---

## Page 1

### Observations

Tide was low at dawn

- gulls on the sandbar
- three seals

![[field-notes-p1-1.png]]

Weather turned by noon
```

Layout carries meaning in handwritten notes, so a line on the page stays a line
in the note. Only structure that geometry makes unambiguous is promoted to
Markdown: a line noticeably taller than its neighbours becomes a heading, a
leading bullet glyph becomes a list item, a left-margin offset becomes an indent
level, a vertical gap becomes a paragraph break.

Diagrams are embedded where they sat on the page, not collected at the bottom.

---

## Your edits are safe

This is the constraint the design bends around: **Inkstone overwrites a note
only when it can prove by hash that the file is still byte-for-byte what
Inkstone last wrote.**

If you have edited a note, the new transcription is written beside it as
`Name.inkstone-new.md` and the run reports it as protected. Nothing you typed is
ever lost to an automated re-run.

To take a note over permanently, add this to its frontmatter:

```yaml
inkstone_lock: true
```

A locked note is never touched again, `--force` included.

---

## When Vision is not good enough

On-device recognition handles tidy handwriting well and dense cursive badly.
Inkstone scores every page and can escalate the bad ones to a cloud vision
model.

The score blends three signals, because Vision's own confidence is not enough on
its own — it reports high confidence on a page it barely read, being sure about
the six words it found and silent about the rest. So the gate also weighs how
many lines came back shaky, how much of the text is non-language garbage, and
how much ink is on the page relative to how little text came out.

Escalation is **off by default**. To turn it on:

```json
{
  "escalationMode": "lowConfidence",
  "vlmProvider": "openai"
}
```

and export `OPENAI_API_KEY` in your shell profile (never in the config file).
Anthropic works identically — set `"vlmProvider": "anthropic"` and export
`ANTHROPIC_API_KEY` instead.

`escalationMode` has three settings. `lowConfidence` pays only for the pages the
gate judges unreliable. `always` sends every page with content on it, which is
the right choice when Vision cannot read your hand at all — gating relies on
signals derived from an OCR pass that is wrong throughout, so it waves through
pages that are quietly garbage. Per-page hash caching keeps `always` affordable:
you pay for genuinely new pages, not for the whole notebook every night.

Set `INKSTONE_OPENAI_ENDPOINT` to route through Azure or a gateway that speaks
the same protocol.

With it off, low-confidence pages are still transcribed and written — they are
just flagged with `needs_review: true` and listed in `low_confidence_pages`, so
a Dataview query can round them up.

The escalation prompt is a transcription prompt, not an editing one. A language
model shown a page of notes will happily tidy them into prose it thinks you
wanted, which is silent data loss; the prompt forbids it, requires `[?]` for
illegible words rather than plausible invention, and preserves the writer's own
shorthand.

---

## Commands

| Command | What it does |
| --- | --- |
| `inkstone init` | Write a config, pre-filled with what it can detect |
| `inkstone doctor` | Check the setup end to end, with a fix for each problem |
| `inkstone run` | Transcribe everything new |
| `inkstone watch` | Stay resident and transcribe as backups land |
| `inkstone status` | Configuration and recent runs (`--json` for scripting) |
| `inkstone install-agent` | Install the daily + watcher launchd agents |
| `inkstone reset` | Forget cached hashes so the next run redoes everything |

Useful flags: `--dry-run` (write nothing), `--all` (ignore caches), `--file`
(one notebook), `--force` (overwrite hand-edited notes), `--verbose`,
`--granularity notebook|page|section`.

---

## Several subjects in one notebook

Handwriting apps cap how many notebooks you get, so one book often ends up
holding several unrelated things. `--granularity section` splits it back apart:

```bash
inkstone run --granularity section
```

A new section starts at any page whose first line is a heading. Everything
until the next heading belongs to it, and pages before the first heading stay
together under the notebook's own name so nothing is orphaned.

Each section becomes its own note, categorised:

```yaml
title: Vectors
category: Vectors
notebook: Calculus
source_pages: [2, 3]
tags: [inkstone, handwritten, vectors]
```

`notebookRouting` matches section names too, so a rule sends a subject to its
own folder wherever you happen to have written it:

```json
{ "notebookRouting": { "Vectors": "Courses/Linear Algebra" } }
```

Unrouted sections nest under their notebook — `Inkstone/Calculus/Vectors.md` —
so two notebooks can both contain a "Standup" without overwriting each other.

Then in Obsidian:

````
```dataview
TABLE category, notebook, quality FROM #inkstone WHERE category
GROUP BY category
```
````

A caveat worth knowing: section names come from OCR. If Vision misreads a
heading you get a note called `Vector operating` instead of `Vector
operations`. Cloud escalation fixes the headings along with everything else.

---

## Configuration

`~/.config/inkstone/config.json`. Every key is optional — missing ones fall back
to defaults, so a config written by an older version keeps working.

| Key | Default | Notes |
| --- | --- | --- |
| `inboxPath` | detected | Folder the backups sync into; searched recursively |
| `vaultPath` | detected | Obsidian vault root |
| `notesSubfolder` | `Inkstone` | Where notes land inside the vault |
| `attachmentsSubfolder` | `Inkstone/attachments` | Where cropped diagrams land |
| `renderDPI` | `300` | Vision's accuracy plateaus above this |
| `recognitionLanguages` | `["en-US"]` | Best match first |
| `usesLanguageCorrection` | `true` | Helps cursive, hurts formulas |
| `customWords` | `[]` | Names, jargon, project codes |
| `escalationThreshold` | `0.55` | Below this a page is bad |
| `escalationMode` | `off` | `off`, `lowConfidence`, or `always` |
| `vlmProvider` | `openai` | `openai` or `anthropic` |
| `vlmModel` | provider default | `gpt-4o` / `claude-opus-5`; empty takes the default |
| `apiKeyEnvVar` | provider default | `OPENAI_API_KEY` / `ANTHROPIC_API_KEY`; never the key itself |
| `diagramExtractionEnabled` | `true` | Crop drawings out as PNGs |
| `minDiagramAreaFraction` | `0.01` | Share of a page a drawing must cover |
| `diagramCropPadding` | `12` | Pixels of breathing room around a crop |
| `notebookRouting` | `{}` | `{"Physics 201": "Courses/Physics"}` — matches notebook *and* section names, prefix match |
| `defaultTags` | `["inkstone", "handwritten"]` | Added to every note |

---

## How it works

[docs/architecture.md](docs/architecture.md) covers the pipeline, the change
detection, and why diagram extraction works by subtracting text rather than
classifying strokes.

## Development

```bash
make build
make test     # 65 tests, including a full pipeline run against generated PDFs
make app      # build Inkstone.app into ./dist
```

The test suite drives real PDFKit rendering and real Vision recognition rather
than stubs — it is the only thing that proves the pieces fit together.
