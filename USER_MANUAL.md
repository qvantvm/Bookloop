# BookLoop User Manual

BookLoop is a native macOS app for working on MkDocs books. It helps you read the rendered book, capture structured feedback, browse review items, manage figures, generate Cursor-ready revision tasks, and review or apply agent-produced patches—all locally, with no external LLM calls from the app itself.

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
8. [Preview tab](#8-preview-tab)
9. [Reviews tab](#9-reviews-tab)
10. [Figures tab](#10-figures-tab)
11. [Tasks tab](#11-tasks-tab)
12. [Patches tab](#12-patches-tab)
13. [Settings tab](#13-settings-tab)
14. [Inspector panel (right column)](#14-inspector-panel-right-column)
15. [Safety and permissions](#15-safety-and-permissions)
16. [Keyboard shortcuts](#16-keyboard-shortcuts)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. What you need before you start

- **macOS 14 or newer**
- **Xcode** (to build and run BookLoop from source)
- An **MkDocs book project** on disk
- Optionally, a terminal for running local services:
  - **MkDocs preview** (`mkdocs serve`)
  - **Feedback API** (`python scripts/feedback_api.py …`)
  - **Agent harness** (optional, for future local agent integration)

BookLoop does **not**:

- Call external LLM APIs
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

BookLoop uses a three-column layout:

| Column | Purpose |
|--------|---------|
| **Sidebar (left)** | Book list, workspace tabs, status summary, Add/Edit/Delete |
| **Workspace (center)** | Main content for the selected tab (Preview, Reviews, Figures, etc.) |
| **Inspector (right)** | Dashboard, feedback form, and agent harness controls |

The toolbar provides:

- **Refresh** — reloads chapters, reviews, figures, tasks, and patches for the selected book
- **Check APIs** — checks MkDocs preview, Feedback API, and Agent Harness connectivity

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
| Agent Harness | `http://127.0.0.1:8770` (optional) |

### Edit book settings

1. Select a book in the sidebar.
2. Click **Edit** (slider icon), or open the **Settings** tab in the workspace.
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

BookLoop loads the preview URL (default `http://127.0.0.1:8000`) in the **Preview** tab.

### Feedback API

From the book root:

```bash
python scripts/feedback_api.py --host 127.0.0.1 --port 8765
```

When you click **Save Review** in the inspector, BookLoop POSTs to:

```text
http://127.0.0.1:8765/api/review
```

The API is responsible for writing review files under `reviews/review_items/`. BookLoop never writes those files itself.

### Agent harness (optional)

If configured, BookLoop can check health at the harness base URL and optionally submit tasks. **Task file generation** under `bookloop/tasks/` remains the primary workflow; the harness is optional.

---

## 7. The end-to-end workflow

BookLoop is designed around this loop:

```text
Read → Save Review → Generate Task → Agent/Cursor Creates Patch → Review Patch → Apply → Rebuild
```

1. **Read** the rendered book in Preview.
2. **Save Review** via the Feedback API when you notice an issue.
3. **Generate Task** (Markdown files in `bookloop/tasks/`) for Cursor or another agent.
4. Let the agent produce a **patch** in `bookloop/patches/`.
5. **Review** the patch block-by-block in the Patches tab.
6. **Apply** accepted changes (with confirmation and `git apply --check` first).
7. Rebuild or re-serve MkDocs and continue reading.

---

## 8. Preview tab

The Preview tab embeds your MkDocs site in a web view.

### Navigation bar

| Control | Action |
|---------|--------|
| ← / → | Back and forward in preview history |
| ↻ | Reload preview |
| **Open Chapter** | Opens the detected chapter’s Markdown in your default editor |
| **Show Chapter** | Reveals the chapter file in Finder |
| **Open in Browser** | Opens the current page in your system browser |

### Chapter detection

BookLoop tries to detect the current chapter from:

1. `<meta name="chapter-id" content="…">` in the HTML page
2. The URL or file slug as a fallback

The detected chapter ID is used to pre-fill the feedback form and task generation.

### Selected text

Select text in the preview, then in the inspector click **Use Selected Text**. BookLoop appends the selection to your feedback body as a quoted passage—useful for pointing at specific wording.

### Reload preview

- Use the in-tab reload button, or
- **BookLoop menu → Reload Preview** (⌘R)

---

## 9. Reviews tab

Browse structured review items scanned from `reviews/review_items/`.

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

## 10. Figures tab

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

## 11. Tasks tab

Shows Markdown task files in `bookloop/tasks/`.

### Generate tasks

| Button | Task type |
|--------|-----------|
| **Current Chapter Task** | Patch proposal for the chapter detected in Preview |
| **Validation Task** | Ask an agent to validate the book |
| **Refresh** | Rescan the tasks folder |

Select a task file to view its contents. Use **Open Task in Finder** or **Copy Task Text** to paste into Cursor or another tool.

### Run validation command

If a **validation command** is configured (default suggestion: `mkdocs build`) and **Allow shell commands** is enabled, you can run validation from this tab. BookLoop shows a confirmation dialog before executing anything.

---

## 12. Patches tab

Review and apply unified-diff patches from `bookloop/patches/*.patch` and `*.diff`.

### Layout

- **Left** — list of patch proposals
- **Center** — rendered before/after blocks (HTML), not a raw line diff
- **Right** — actions for the selected patch

### Block-level review

Each diff hunk is shown as a semantic **block** with Before and After HTML. For each block you can:

- **Accept Block**
- **Reject Block**
- **Reset** to pending

Use **Accept All**, **Reject All**, or **Reset** for the whole patch.

Decisions apply to **whole rendered blocks**, not individual diff lines.

### Patch actions

| Action | Description |
|--------|-------------|
| **Copy Accepted-Blocks Patch** | Copy a patch containing only accepted blocks |
| **Save Accepted-Blocks Patch** | Save to `bookloop/patches/reviewed-YYYYMMDD-HHMMSS-<name>.patch` |
| **Apply Accepted Blocks** | Write reviewed patch, run `git apply --check`, then apply if check passes |
| **Open Original Patch File** | Reveal in Finder |
| **Copy Original Raw Patch** | Copy full patch text |
| **Apply Full Original Patch** | Apply entire patch (ignores block decisions); requires confirmation |
| **Reject / Archive Original Patch** | Move patch to `bookloop/patches/archive/` without changing book content |

Patch application always runs `git apply --check` before `git apply`. BookLoop never force-applies patches.

**Allow patch apply** must be enabled in book settings for apply actions to work.

---

## 13. Settings tab

Full book configuration in one form. Sections:

### Book

Display name, project root, preview URL, feedback API URL, optional agent harness URL.

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

## 14. Inspector panel (right column)

Always visible when a book is selected.

### Dashboard

Status badges for MkDocs preview, Feedback API, and Agent Harness, plus counts for open reviews, figures, patches, and tasks.

Click **Check MkDocs Preview** to verify the preview URL responds.

### Feedback form

| Field | Description |
|-------|-------------|
| Chapter ID | Auto-filled from preview when possible |
| Type | Question, Confusion, Missing Example, Figure Needed, etc. |
| Severity | Low, Medium, High, Critical |
| Section | Optional section within the chapter |
| Title | Short summary |
| Observation / Body | Detailed notes |
| Suggested Fix | Optional proposed correction |

| Button | Action |
|--------|--------|
| **Use Selected Text** | Append preview selection to the body |
| **Check API** | Verify Feedback API is reachable |
| **Save Review** | Submit to Feedback API (⌘Return) |
| **Clear Form** | Reset all fields |

### Agent harness panel

- **Check Harness** — health check
- **Send Task to Harness** — submit selected review items (optional; task files remain the default path)

---

## 15. Safety and permissions

BookLoop is built around explicit, human-visible actions:

- No external LLM API calls from the app
- No direct writes to review Markdown files
- No automatic shell execution unless toggles are on and you confirm
- No silent patch application—always confirm, and run `git apply --check` first
- Figure regeneration requires both **Allow shell commands** and **Allow figure regeneration**

When in doubt, leave safety toggles off and use BookLoop only for reading, feedback submission, and task file generation.

---

## 16. Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Reload preview (BookLoop menu) |
| ⌘Return | Save Review (feedback form) |
| ⌘S | Save Settings (Settings tab) |
| ⌘Return | Save (book settings sheet) |

---

## 17. Troubleshooting

### Preview shows blank or error

- Confirm `mkdocs serve` is running.
- Check the preview URL in Settings (default `http://127.0.0.1:8000`).
- Click **Check MkDocs Preview** in the inspector.

### Save Review fails / Feedback API offline

- Start the feedback server from the book root.
- Verify the Feedback API URL in Settings.
- Click **Check API** in the feedback panel.

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

### Chapter not detected in preview

- Add `<meta name="chapter-id" content="your-chapter-id">` to your MkDocs theme or chapter templates.
- Or enter the chapter ID manually in the feedback form.

---

## Quick reference: default ports

| Service | Default URL |
|---------|-------------|
| MkDocs preview | `http://127.0.0.1:8000` |
| Feedback API | `http://127.0.0.1:8765` |
| Agent harness | `http://127.0.0.1:8770` |

---

For developer-oriented setup, architecture notes, and build details, see [README.md](README.md).
