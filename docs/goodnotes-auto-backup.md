# Getting your notebooks onto the Mac

Inkstone never talks to GoodNotes. It reads PDFs out of a folder on your Mac.
Everything on this page is about making that folder fill up on its own.

The chain is:

```
GoodNotes (iPad)  →  Auto-Backup  →  cloud drive  →  sync client (Mac)  →  ~/…/GoodNotes/*.pdf  →  Inkstone
```

Each arrow can break independently, which is why `inkstone doctor` checks the
end of the chain and tells you how old the newest file is. A backup that stops
arriving looks exactly like a tool that stopped working.

---

## 1. Turn on Auto-Backup in GoodNotes

On the iPad, in GoodNotes:

1. Open the app's **Settings** (the gear icon on the documents screen).
2. Choose **Auto-Backup**.
3. Turn it on and pick a cloud service — Google Drive, Dropbox, OneDrive, or a
   WebDAV server.
4. Sign in and choose (or create) a destination folder. Something plain like
   `GoodNotes` at the top level of the drive keeps the Mac side simple.
5. Set the file format to **PDF**.

Menu labels move around between GoodNotes versions; if the wording differs, look
for backup or export settings rather than the per-notebook *Share → Export*
sheet. Auto-Backup is the one that runs on its own.

**Why PDF and not the native format.** The `.goodnotes` format is a private
archive that only GoodNotes reads. PDF is a public format with vector page
content, and PDFKit renders it at any resolution — which is what lets Inkstone
rasterise a page at 300 DPI for OCR and crop diagrams out of it at full
fidelity. If your version offers *PDF* and *PDF (Flattened)*, either works;
plain PDF is smaller.

Auto-Backup uploads a fresh copy of a notebook after you edit it. That means the
same file name is rewritten repeatedly, which is exactly what Inkstone's
per-page change detection is built for: a rewritten 200-page notebook with one
new page costs one page of work.

---

## 2. Sync that folder down to the Mac

Install the desktop client for whichever service you chose and sign in.

**Google Drive** puts your files under
`~/Library/CloudStorage/GoogleDrive-<account>/My Drive/…`.

One setting matters. Drive for desktop can either *stream* files (they exist as
placeholders and download on first open) or *mirror* them (real bytes on disk,
always). Inkstone reads bytes; a placeholder is a real path with almost nothing
in it, and it will be skipped with a warning rather than transcribed.

Fix it in one of two ways:

- Right-click the GoodNotes folder in Finder → **Offline access → Available
  offline**, or
- switch the whole drive to mirroring in Drive for desktop's preferences.

**Dropbox** is the same story under a different name: turn off *Online-only* for
the folder — in Dropbox this is called Smart Sync or Selective Sync depending on
the version.

**iCloud Drive** lives under `~/Library/Mobile Documents/com~apple~CloudDocs/`
and evicts files it thinks you are not using. Right-click the folder and choose
**Keep Downloaded**.

---

## 3. Point Inkstone at it

```bash
inkstone init
```

This looks for your Obsidian vault (via Obsidian's own vault registry) and for a
cloud-synced folder, and writes what it finds into
`~/.config/inkstone/config.json`. Open that file and check two keys:

```json
{
  "inboxPath": "~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/GoodNotes",
  "vaultPath": "~/Notes"
}
```

`inboxPath` is searched recursively, so pointing it at a folder of per-notebook
subfolders is fine.

Then:

```bash
inkstone doctor
```

Every line is either fine or tells you what to do about it. The one to look at
first is **Freshness** — if the newest backup is weeks old, the problem is
upstream in GoodNotes or the sync client, and no amount of configuring Inkstone
will help.

---

## 4. Grant file access

The first run that touches `~/Library/CloudStorage` will trip macOS's privacy
controls. Depending on how you run Inkstone you may need to grant:

- **Full Disk Access** — System Settings → Privacy & Security → Full Disk
  Access. Add your terminal app if you use the CLI, and `Inkstone.app` if you use
  the menu-bar app. The launchd agents inherit the app's grant.
- **Files and Folders** — a narrower prompt that appears the first time
  something reads a synced folder. Allowing it is enough for most setups.

If `inkstone doctor` reports the inbox as unreadable while Finder shows the
files, this is the cause.

---

## Troubleshooting

**Nothing appears in the inbox.** Check GoodNotes first: open Auto-Backup
settings and confirm the destination is still connected. Cloud sign-ins expire.

**`skipping placeholder or empty file`.** The sync client has not downloaded the
real file. See step 2.

**PDFs arrive but notes do not.** Run `inkstone run --verbose` and read the log.
The most common cause is `vaultPath` pointing one directory above or below the
actual vault root.

**A notebook is transcribed but the text is nonsense.** That is a recognition
problem, not a setup problem — see the confidence gating section in the
[README](../README.md#when-vision-is-not-good-enough).
