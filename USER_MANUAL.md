# BookLoop User Manual

BookLoop is a native macOS app for working on MkDocs books. It helps you read the rendered book, ask questions about the current chapter (optional OpenAI chat), run a built-in native agent, capture structured feedback, browse review items, manage figures, generate Cursor-ready revision tasks, and review or apply agent-produced patches.

This manual describes how to install BookLoop, set up a book project, and use each part of the interface.

---

## Table of contents

1. [What you need before you start](#1-what-you-need-before-you-start)
2. [Install and launch BookLoop](#2-install-and-launch-bookloop)
3. [Understand the interface](#3-understand-the-interface)
4. [Prepare your book project](#4-prepare-your-book-project)
5. [Add and configure a book](#5-add-and-configure-a-book)
6. [Start local services](#6-start-local-services)
7. [The end-to-end workflow](#7-the-end-to-end-workflow)
8. [Reading mode (preview)](#8-reading-mode-preview)
9. [Chapter Chat (right column)](#9-chapter-chat-right-column)
10. [Tools mode (Reviews, Figures, Tasks, Patches, Agent, Settings)](#10-tools-mode-reviews-figures-tasks-patches-agent-settings)
11. [Reviews tool](#11-reviews-tool)
12. [Figures tool](#12-figures-tool)
13. [Tasks tool](#13-tasks-tool)
14. [Agent tool](#14-agent-tool)
15. [Patches tool](#15-patches-tool)
16. [Settings tool](#16-settings-tool)
17. [App settings (OpenAI & native agent)](#17-app-settings-openai--native-agent)
18. [Safety and permissions](#18-safety-and-permissions)
19. [Keyboard shortcuts](#19-keyboard-shortcuts)
20. [Troubleshooting](#20-troubleshooting)

---

## 1. What you need before you start

- **macOS 14 or newer**
- **Xcode** (to build and run BookLoop from source)
- An **MkDocs book project** on disk
- Optionally, an **OpenAI API key** for Chapter Chat and the built-in **Native Agent** (stored in the macOS Keychain)
- Optionally, a terminal for running local services:
  - **MkDocs preview** (`mkdocs serve`)
  - **Feedback API** (`python scripts/feedback_api.py …`)

BookLoop does **not** (unless you enable OpenAI features):

- Call external LLM APIs by default — Chapter Chat and the Native Agent are optional and require your OpenAI key
- Write review Markdown files directly (feedback goes through the Feedback API)
- Silently rewrite book files or force-apply patches

---

## 2. Install and launch BookLoop

1. Open `BookLoop.xcodeproj` in Xcode.
2. Select the **BookLoop** scheme and **My Mac** as the run destination.
3. Press **Run** (⌘R).

On first launch you will see an empty library. Use the sidebar **Add** button to register your first book.

BookLoop stores your library here:

```text
~/Library/Application Support/BookLoop/books.json
```

---

## 3. Understand the interface

BookLoop uses a three-column layout optimized for reading:

| Column | Purpose |
|--------|---------|
| **Library sidebar (left)** | Books, clickable chapter tree, compact status, Tools launcher, Add/Edit/Delete |
| **Center** | **Reading mode** — MkDocs preview (default), or **Tools mode** — Reviews, Figures, Tasks, Patches, Agent, or Settings |
| **Chapter Chat (right)** | OpenAI-powered chat about the current page; **Send as Feedback** submits the transcript to the Feedback API |

### Reading vs Tools mode

- **Reading mode** (default): the center column shows the book preview. Use the sidebar chapter tree or preview navigation to move between pages.
- **Tools mode**: choose **Reviews**, **Figures**, **Tasks**, **Patches**, **Agent**, or **Settings** under **Tools** in the sidebar. The center column switches to that tool. Click **Back to Reading** to return to the preview at the same URL.

### Hide panels

- Preview toolbar: **Hide Panel** / **Show Panel** (sidebar), **Hide Chat** / **Show Chat**
- Sidebar header: collapse icon to hide the library panel

The toolbar provides:

- **Refresh** — reloads chapters, reviews, figures, tasks, and patches for the selected book
- **Check APIs** — checks MkDocs preview and Feedback API connectivity

---

## 4. Prepare your book project

BookLoop expects a typical MkDocs layout. Recommended structure:

```text
my-book/
  mkdocs.yml
  docs/
    index.md
    chapters/
    assets/
      figures/
  reviews/
    review_items/          ← individual review Markdown files
    cumulative_review.md   ← optional summary
    review_index.json      ← optional index
  figures/                 ← figure source scripts (optional)
  .bookloop/
    config.json            ← optional native agent config
    sessions/              ← native agent session logs
  bookloop/
    style_guide.md
    figures.json
    tasks/                 ← generated Cursor tasks
    patches/               ← .patch / .diff files from agents
      archive/             ← rejected patches moved here
  scripts/
    feedback_api.py        ← local feedback server (your book may vary)
```

You do not need every folder on day one. BookLoop can infer or suggest paths when you configure a book.

---

## 5. Add and configure a book

### Add a book

1. Click **Add** in the sidebar toolbar.
2. Choose the **MkDocs project root** (the folder containing `mkdocs.yml`).
3. BookLoop creates a book entry with sensible defaults.

Default URLs:

| Setting | Default |
|---------|---------|
| Preview URL | `http://127.0.0.1:8000` |
| Feedback API | `http://127.0.0.1:8765` |

### Edit book settings

1. Select a book in the sidebar.
2. Click **Edit** (slider icon), open **Tools → Settings**, or use the book settings sheet from **Edit** in the sidebar.
3. Adjust paths, commands, and safety toggles.
4. Click **Save Settings** (⌘S in the Settings tab).

Useful buttons in Settings:

- **Infer Existing Paths** — scans the project root and fills in paths that already exist
- **Fill Suggested Paths** — fills standard relative paths even if folders are not created yet

### Delete a book

Select the book and click **Delete** (trash icon). This removes the entry from BookLoop’s library only; it does not delete files on disk.

---

## 6. Start local services

BookLoop connects to services you run separately in Terminal.

### MkDocs preview

From the book root:

```bash
mkdocs serve
```

BookLoop loads the preview URL (default `http://127.0.0.1:8000`) in the center **Reading** column.

### Feedback API

From the book root:

```bash
python scripts/feedback_api.py --host 127.0.0.1 --port 8765
```

When you submit feedback (Reviews tool **Save Review** or Chapter Chat **Send as Feedback**), BookLoop POSTs to:

```text
http://127.0.0.1:8765/api/review
```

The API is responsible for writing review files under `reviews/review_items/`. BookLoop never writes those files itself.

---

## 7. The end-to-end workflow

BookLoop is designed around this loop:

```text
Read → Save Review → Generate Task → Agent/Cursor Creates Patch → Review Patch → Apply → Rebuild
```

1. **Read** the rendered book in the center preview (Reading mode).
2. **Save Review** via Chapter Chat, the Reviews tool feedback form, or both.
3. **Generate Task** (Markdown files in `bookloop/tasks/`) for Cursor or another agent.
4. Let the agent produce a **patch** in `bookloop/patches/`.
5. **Review** the patch block-by-block in **Tools → Patches**.
6. **Apply** accepted changes (with confirmation and `git apply --check` first).
7. Rebuild or re-serve MkDocs and continue reading.

---

## 8. Reading mode (preview)

The center column embeds your MkDocs site in a web view. MkDocs side navigation is hidden so the chapter uses the full width.

### Sidebar chapter tree

- Click a chapter in the sidebar **Chapters** section to navigate the preview.
- After the preview loads, BookLoop extracts the MkDocs nav tree from the page. Until then, a fallback list from your project’s chapter scan is shown.

### Preview toolbar

| Control | Action |
|---------|--------|
| **Hide Panel** / **Show Panel** | Toggle the library sidebar |
| **Hide Chat** / **Show Chat** | Toggle Chapter Chat |
| ← / → | Back and forward in preview history |
| ↻ | Reload preview |
| **Auto Refresh** | Toggle automatic reload (when enabled) |
| **Open Chapter** | Opens the detected chapter’s Markdown in your default editor |
| **Open in Browser** | Opens the current page in your system browser |

### Chapter detection

BookLoop tries to detect the current chapter from:

1. `<meta name="chapter-id" content="…">` in the HTML page
2. The URL or file slug as a fallback

The detected chapter ID is used for Chapter Chat context, feedback forms, and task generation.

### Selected text

Select text in the preview, then in **Tools → Reviews → Submit Review** click **Use Selected Text**. BookLoop appends the selection to your feedback body as a quoted passage.

### Reload preview

- Use the preview toolbar reload button, or
- **BookLoop menu → Reload Preview** (⌘R)

---

## 9. Chapter Chat (right column)

Chapter Chat lets you ask questions about the page you are reading. It is optional and requires an OpenAI API key (see [App settings](#16-app-settings-openai)).

### Setup

1. Click the **gear** icon in the sidebar header.
2. Enter your OpenAI API key and preferred model (default `gpt-4.1`).
3. Click **Save**.

### Using chat

- Each page keeps its own in-memory chat session. Switch chapters and return later — your messages for that page are restored.
- **Send** — asks OpenAI using the current page text plus chat history.
- **Send as Feedback** — saves the full conversation as a review item via the Feedback API (requires Feedback API online).
- **Clear Chat** — clears the current page’s messages.
- **Check API** — verifies the Feedback API (needed for **Send as Feedback**).

The chat header shows the page title and detected chapter ID when available.

---

## 10. Tools mode (Reviews, Figures, Tasks, Patches, Agent, Settings)

Open a tool from **Tools** in the sidebar. The center column switches from preview to that tool. Click **Back to Reading** to restore the preview at the same URL.

| Tool | Purpose |
|------|---------|
| **Reviews** | Browse review items; submit structured feedback |
| **Figures** | Scan and manage figures |
| **Tasks** | Generate and view Cursor task files |
| **Agent** | Built-in OpenAI tool-calling agent with native file/build/git tools |
| **Patches** | Review and apply agent patches |
| **Settings** | Per-book configuration |

---

## 11. Reviews tool

Browse structured review items scanned from `reviews/review_items/`.

Click **Submit Review** in the toolbar to show the manual feedback form (moved from the old inspector panel).

### Feedback form fields

| Field | Description |
|-------|-------------|
| Chapter ID | Auto-filled from preview when possible (use frontmatter id, not `docs/` path) |
| Type / Severity | Review classification |
| Title / Body | Required for **Save Review** |
| Suggested Fix | Optional |

Use **Use Selected Text**, **Check API**, **Save Review** (⌘Return), and **Clear Form** as before.

### Filters and organization

- **Search** — filter by title or content
- **Chapter / Severity / Type** — narrow the list
- **Group** — None, Chapter, Severity, or Type
- **Sort** — control display order

### Sub-tabs

| Sub-tab | Content |
|---------|---------|
| **Review Items** | List and detail view of individual reviews |
| **Cumulative** | Contents of `reviews/cumulative_review.md` (if present) |
| **Index** | Contents of `reviews/review_index.json` (if present) |

### Actions

| Button | Purpose |
|--------|---------|
| **Refresh Reviews** | Rescan review files on disk |
| **Generate Task for Selected Reviews** | Create a fix-reviews task from selected items |
| **Generate Task for Current Chapter** | Create a patch-proposal task for the preview chapter |
| **Generate Figure Task** | Create a figure proposal task from selected reviews |

Select items in the list to include them in task generation. The detail pane shows body text, suggested fix, and shortcuts to open or copy the review ID.

---

## 12. Figures tool

BookLoop scans Markdown image references, output assets under `docs/assets/figures/`, source scripts, and `bookloop/figures.json`.

### Figure list

Click a figure in the left list to inspect it. Status values include **ok**, **missing output**, **stale**, **unreferenced**, and others.

### Figure detail

| Action | Purpose |
|--------|---------|
| **Open Output** | Show rendered asset in Finder |
| **Open Source** | Show source script (if found) |
| **Copy Markdown Reference** | Copy `![caption](path)` to the clipboard |
| **Regenerate** | Run the configured figure command (requires safety toggles) |

### Toolbar

- **Refresh Figures** — rescan the book
- **Generate Figure Task** — write a Cursor task for the selected figure

---

## 13. Tasks tool

Shows Markdown task files in `bookloop/tasks/`.

### Generate tasks

| Button | Task type |
|--------|-----------|
| **Current Chapter Task** | Patch proposal for the chapter detected in Preview |
| **Validation Task** | Ask an agent to validate the book |
| **Refresh** | Rescan the tasks folder |

Select a task file to view its contents. Use **Open Task in Finder** or **Copy Task Text** to paste into Cursor or another tool.

### Run validation command

If a **validation command** is configured (default suggestion: `mkdocs build`) and **Allow shell commands** is enabled, you can run validation from this tool. BookLoop shows a confirmation dialog before executing anything.

---

## 14. Agent tool

The **Native Agent** runs inside BookLoop using OpenAI tool-calling and Swift file/build/git tools. It does not require an external Cursor CLI harness.

### Prerequisites

1. Configure your OpenAI API key in app settings (sidebar gear).
2. Select a book in the library.
3. Optionally click **Initialize Config** to create `.bookloop/config.json` in the book root (build command, protected paths, allowed write globs).

### Built-in tasks

| Button | Purpose |
|--------|---------|
| **Summarize Project** | Scan chapters, reviews, and config; produce a project summary |
| **Apply Review Feedback** | Read open review items and propose edits |
| **Improve Current Chapter** | Improve the chapter detected in Reading mode |
| **Fix Build Errors** | Run the configured build and attempt fixes |
| **Run Custom Task** | Run with your optional instruction text |

While a task runs, BookLoop shows a live **Tool Log** (list files, read file, search, stage patch, build, git status/diff). When finished, you see a summary, staged files, and a **patch proposal** written to `bookloop/patches/agent-*.patch`.

### Propose-only workflow

The native Agent **does not modify book files on disk**. Each `apply_patch` call stages an exact-text replacement. At the end of a run, BookLoop exports a unified diff to `bookloop/patches/`. Review and apply it from **Tools → Patches**.

### Session artifacts

- Each run writes a session folder under `.bookloop/sessions/` (including `proposal.patch`).
- **Delete Proposal Patch** removes the exported proposal from `bookloop/patches/` without changing book content.
- Staging is limited to paths allowed in `.bookloop/config.json`; protected paths (`.git`, `.bookloop`, etc.) cannot be modified.

Agent settings (max iterations, build timeout, review edits) are in app settings under **Native Agent**.

---

## 15. Patches tool

Review and apply unified-diff patches from `bookloop/patches/*.patch` and `*.diff`.

### Layout

- **Left** — pending patch proposals (applied patches are archived automatically and disappear)
- **Center** — rendered before/after blocks (HTML), not a raw line diff
- **Right** — 3-step workflow: Review → Apply → Commit, plus live git status and activity log

### Block-level review

Each diff hunk is shown as a semantic **block** with Before and After HTML. For each block you can **Accept Block**, **Reject Block**, or **Reset** to pending.

In the right pane, **Step 1** provides **Accept All**, **Reject All**, and **Reset** for the whole patch.

Review decisions choose what *would* change. Nothing is written to book files until Step 2.

### 3-step workflow (right pane)

| Step | What it does |
|------|----------------|
| **1 Review blocks** | Accept/reject blocks; summary shows accepted · rejected · pending counts |
| **2 Apply to book** | **Apply Accepted Changes** runs `git apply --check` then `git apply` for accepted blocks only. Requires **Allow patch apply**. Patch file is archived and removed from the left list. |
| **3 Commit to git** | **Commit to Git** runs `git add` + `git commit`. Requires **Allow shell commands**. Enabled only after Step 2 succeeds. |

Terminology:

- **Review decisions** — block choices; not yet on disk
- **Applied to book** — `git apply` succeeded; files modified
- **Committed** — `git commit` succeeded; recorded in git history

### Git panel (auto-refreshed)

The right pane shows:

- **Working tree** — `git status --short` (refreshes automatically; no manual button)
- **Latest commit** — `git log -1 --oneline`
- **Activity** — recent apply/commit/archive events (also saved to `bookloop/patches/activity.json`)

### Advanced (collapsed)

Power-user actions: open patch file, copy commit command, archive without applying, check/copy/save accepted-block patch, apply full original patch.

### End-to-end workflow

1. **Agent** → Apply Review Feedback writes one `.patch` under `bookloop/patches/`.
2. **Patches** → Step 1: accept blocks → Step 2: Apply Accepted Changes → Step 3: Commit to Git.
3. Applied patches move to `bookloop/patches/archive/` and leave the pending list.

For very long reviews, increase **Max tool iterations** in app settings or run the agent again after committing the first batch.

---

## 16. Settings tool

Full book configuration in one form. Sections:

### Book

Display name, project root, preview URL, and feedback API URL.

### Paths

Paths to `mkdocs.yml`, `docs/`, review folders, figure folders, `bookloop/`, style guide, and figures registry.

### Commands

Optional shell commands (reference only unless execution is explicitly allowed):

- MkDocs serve
- Feedback API
- Figure generation (supports `<figure-id>` placeholder)
- Validation

### Safety

| Toggle | Effect |
|--------|--------|
| **Allow shell commands** | Master switch for running commands from BookLoop |
| **Allow figure regeneration** | Enables **Regenerate** on figures (also requires a command) |
| **Allow patch apply** | Enables git apply actions in Patches |

### Notes

Free-form notes stored with the book configuration.

---

## 17. App settings (OpenAI & native agent)

Global app settings (not per-book) are opened from the **gear** icon in the sidebar header.

| Setting | Description |
|---------|-------------|
| **OpenAI Model** | Model slug for Chapter Chat and the Native Agent (default `gpt-4.1`) |
| **OpenAI API Key** | Stored in the macOS Keychain; required for Chapter Chat and Agent |
| **Max tool iterations** | Limit on agent tool-calling loop (1–24) |
| **Build timeout** | Seconds allowed for agent `run_build` (30–600) |
| **Allow agent to edit review items** | Lets the agent stage writes under `reviews/` when allowed by config |
| **Auto-run build after patch apply** | Reserved for future use when applying patches from the Patches tab |

Use **Remove Key** to delete the saved key.

Per-book agent path rules live in `.bookloop/config.json` (initialize from **Tools → Agent**).

---

## 18. Safety and permissions

BookLoop is built around explicit, human-visible actions:

- **Chapter Chat** and the **Native Agent** call OpenAI only when you run them and an API key is configured
- Agent file writes are path-guarded and exported as patch proposals for Patches-tab review before apply
- No direct writes to review Markdown files (Feedback API writes them)
- No automatic shell execution unless toggles are on and you confirm
- No silent patch application—always confirm, and run `git apply --check` first
- Figure regeneration requires both **Allow shell commands** and **Allow figure regeneration**

When in doubt, leave safety toggles off and omit your OpenAI key if you only want reading, feedback submission, and task file generation.

---

## 19. Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Reload preview (BookLoop menu) |
| ⌘Return | Save Review (feedback form) |
| ⌘S | Save Settings (Settings tool) |
| ⌘Return | Save (book settings sheet) |

---

## 20. Troubleshooting

### Preview shows blank or error

- Confirm `mkdocs serve` is running.
- Check the preview URL in **Tools → Settings** (default `http://127.0.0.1:8000`).
- Use toolbar **Check APIs**.

### Save Review fails / Feedback API offline

- Start the feedback server from the book root.
- Verify the Feedback API URL in book settings.
- Click **Check API** in Chapter Chat or the Reviews feedback form.

### Chapter Chat does not respond

- Open app settings (sidebar gear) and confirm your OpenAI API key is saved.
- Check your network connection and model name.

### No review items appear

- Ensure `reviews/review_items/` exists and contains Markdown files.
- Click **Refresh Reviews** or toolbar **Refresh**.
- Check the **review_items** path in Settings.

### No patches appear

- Place `.patch` or `.diff` files in `bookloop/patches/`.
- Click **Refresh Patches**.

### Patch apply fails

- Ensure the book root is a git repository (patches use `git apply`).
- Read the error output in the Patches panel.
- Try **Apply Accepted Blocks** with a smaller reviewed patch instead of the full original.

### Figure regeneration disabled

- Enable **Allow shell commands** and **Allow figure regeneration** in Settings.
- Set a **Figure generation command** (book-level or per-figure in registry).
- Confirm the command when prompted.

### Agent does not run

- Open app settings and confirm your OpenAI API key is saved.
- Select a book and click **Initialize Config** if `.bookloop/config.json` is missing.
- Check the tool log and error message in **Tools → Agent**.

### Chapter not detected in preview

- Add `<meta name="chapter-id" content="your-chapter-id">` to your MkDocs theme or chapter templates.
- Or enter the chapter ID manually in the Reviews feedback form.

---

## Quick reference: default ports

| Service | Default URL |
|---------|-------------|
| MkDocs preview | `http://127.0.0.1:8000` |
| Feedback API | `http://127.0.0.1:8765` |

---

For developer-oriented setup, architecture notes, and build details, see [README.md](README.md).
