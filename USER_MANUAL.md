# BookLoop User Manual

BookLoop is a native macOS app for working on technical book projects. It helps you read chapters with built-in Markdown preview, highlight passages and save annotations, ask questions about the current chapter (optional OpenAI chat), search the manuscript with natural language, run a built-in native agent (including whole-book consistency and flow audits), capture structured feedback, browse review items, manage figures, generate Cursor-ready revision tasks, inspect git history, and review or apply agent-produced patches.

This manual describes how to install BookLoop, set up a book project, and use each part of the interface.

---

## Table of contents

1. [What you need before you start](#1-what-you-need-before-you-start)
2. [Install and launch BookLoop](#2-install-and-launch-bookloop)
3. [Understand the interface](#3-understand-the-interface)
4. [Prepare your book project](#4-prepare-your-book-project)
5. [Add and configure a book](#5-add-and-configure-a-book)
6. [Local services](#6-local-services)
7. [The end-to-end workflow](#7-the-end-to-end-workflow)
8. [Reading mode (preview)](#8-reading-mode-preview)
9. [Preview annotations](#9-preview-annotations)
10. [Chapter Chat (right column)](#10-chapter-chat-right-column)
11. [Tools mode overview](#11-tools-mode-overview)
12. [Reviews tool](#12-reviews-tool)
13. [Figures tool](#13-figures-tool)
14. [Tasks tool](#14-tasks-tool)
15. [Search tool](#15-search-tool)
16. [Agent tool](#16-agent-tool)
17. [Patches tool](#17-patches-tool)
18. [Git tool](#18-git-tool)
19. [Settings tool](#19-settings-tool)
20. [App settings (OpenAI & native agent)](#20-app-settings-openai--native-agent)
21. [Safety and permissions](#21-safety-and-permissions)
22. [Keyboard shortcuts](#22-keyboard-shortcuts)
23. [Troubleshooting](#23-troubleshooting)

---

## 1. What you need before you start

- **macOS 14 or newer**
- **Xcode** (to build and run BookLoop from source)
- A **book project** on disk (`docs/`, `bookloop.yml`, reviews folders)
- Optionally, an **OpenAI API key** for Chapter Chat and the built-in **Native Agent** (stored locally in Application Support)

BookLoop does **not** require an external preview server. It renders Markdown chapters in-app.

BookLoop also does **not** (unless you enable OpenAI features):

- Call external LLM APIs by default — Chapter Chat and the Native Agent are optional and require your OpenAI key
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
| **Center** | **Reading mode** — native Markdown preview (default), or **Tools mode** — Search, Reviews, Figures, Tasks, Patches, Agent, Git, or Settings |
| **Right** | **Chapter Chat** (OpenAI, optional) or, in Reading mode, an optional **Annotations** panel when chat is hidden |

### Reading vs Tools mode

- **Reading mode** (default): the center column shows the book preview. Use the sidebar chapter tree or preview navigation to move between pages. Optionally show **Annotations** beside the preview (see [Preview annotations](#9-preview-annotations)).
- **Tools mode**: choose **Search**, **Reviews**, **Figures**, **Tasks**, **Patches**, **Agent**, **Git**, or **Settings** under **Tools** in the sidebar. The center column switches to that tool. Click **Back to Reading** to return to the preview at the same chapter.

### Hide panels

- Preview toolbar: **Hide Panel** / **Show Panel** (sidebar), **Hide Chat** / **Show Chat**, **Annotations** toggle
- Sidebar header: collapse icon to hide the library panel
- Opening **Annotations** hides Chapter Chat for that layout; BookLoop restores your panel choice when you return to Reading mode

The toolbar provides:

- **Refresh** — reloads chapters, reviews, figures, tasks, and patches for the selected book

---

## 4. Prepare your book project

BookLoop expects a typical book layout with Markdown under `docs/` and a root `bookloop.yml` project config (navigation, theme, optional extra CSS). Recommended structure:

```text
my-book/
  bookloop.yml
  llms.txt                 ← optional LLM context (legacy: static/llms.txt)
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
    preview_annotations.json  ← optional in-preview highlights (mirrored in App Support)
    sessions/              ← native agent session logs
  bookloop/
    style_guide.md
    figures.json
    tasks/                 ← generated Cursor tasks
    patches/               ← .patch / .diff files from agents
      archive/             ← rejected patches moved here
    audit-reports/         ← consistency / logical-flow audit reports
```

You do not need every folder on day one. BookLoop can infer or suggest paths when you configure a book. A `scripts/` folder is **not** required — reviews, tasks, and agent tools are built into BookLoop.

Optional **`llms.txt`** (or legacy `static/llms.txt`) summarizes the book for Chapter Chat and the native Agent. BookLoop loads it automatically when present, or generates `llms.txt` at the book root on first use if it is missing.

If you still have `mkdocs.yml` or `nav.yml` but no `bookloop.yml`, BookLoop reads the legacy file and shows a banner suggesting migration. Use **Create bookloop.yml from mkdocs.yml** in book settings to copy nav, theme, and related settings.

### Git hygiene (book repo)

BookLoop writes **two different kinds of output**:

| Location | Purpose | Commit to git? |
|----------|---------|----------------|
| `reviews/` | Human/editor feedback (Markdown review items); BookLoop writes here on Save Review / Send as Feedback | Usually **yes** — this is editorial input |
| `bookloop/patches/agent-*.patch` | Patch proposals for the Patches tool | **No** until you apply; then commit **`docs/`** changes |
| `.bookloop/sessions/` | Agent run logs (tool log, diff staging, snapshots) | **No** — ephemeral debug artifacts |
| `bookloop/patches/archive/` | Applied/rejected patch copies | **No** |
| `bookloop/audit-reports/` | Agent audit Markdown reports | Optional — commit if you want reports in the repo |
| `.bookloop/preview_annotations.json` | In-preview highlights and notes | Optional — personal markup; often **no** |

Click **Tools → Agent → Ensure Gitignore** (or **Initialize Config**) to append recommended ignores to your book’s `.gitignore`. After that, session folders disappear from git status.

What you **should** commit after a successful patch workflow: the modified chapter files under `docs/` (Step 3: Commit to git in Patches), not the agent session JSON or `diff-staging/` temp files.

---

## 5. Add and configure a book

### Add a book

1. Click **Add** in the sidebar toolbar.
2. Choose the **book project root** (the folder containing `docs/` and preferably `bookloop.yml`).
3. BookLoop creates a book entry with sensible defaults.

Default paths:

| Setting | Default |
|---------|---------|
| Navigation | `bookloop.yml` |
| Review items | `reviews/review_items/` (under project root) |

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

## 6. Local services

Feedback (**Save Review** and **Send as Feedback**) is written directly to `reviews/review_items/` in your book project. No separate server is required.

Reading mode uses BookLoop's built-in Markdown renderer. The sidebar **Preview** status dot reflects whether the `docs/` folder is available.

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
7. Optionally run your configured validation command and continue reading.

---

## 8. Reading mode (preview)

The center column renders the current chapter from `docs/` using bundled Markdown and KaTeX support. Navigation comes from `bookloop.yml` (or legacy `mkdocs.yml` nav).

### Sidebar chapter tree

- Click a chapter in the sidebar **Chapters** section to load that Markdown file.
- The tree matches your `bookloop.yml` nesting.

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

### Preview theme

In **App Settings → Preview**, choose **System**, **Light**, or **Dark** for the chapter preview only (independent of macOS appearance).

---

## 9. Preview annotations

While reading, you can highlight passages and attach notes directly in the preview.

### Create a highlight

1. Select text in the preview.
2. Click **Highlight & Note** in the preview toolbar.
3. Edit the quote and optional note, then **Save Highlight**.

Highlights appear in the preview and in the **Annotations** panel (toolbar toggle). Click a highlight badge in the preview to open or edit it.

### Annotations panel

When **Annotations** is on, a panel lists highlights for the current chapter. For each annotation you can:

- Open the editor, jump to the passage in the preview, or delete the highlight
- **Save as Review** — writes a review item under `reviews/review_items/` (same workflow as structured feedback)
- **Save All as Reviews** — batch-save every unsaved highlight on the chapter

Annotations persist in Application Support and are mirrored to `.bookloop/preview_annotations.json` in the book project when BookLoop has folder access.

---

## 10. Chapter Chat (right column)

Chapter Chat lets you ask questions about the page you are reading. It is optional and requires an OpenAI API key (see [App settings](#20-app-settings-openai--native-agent)).

### Setup

1. Click the **gear** icon in the sidebar header.
2. Enter your OpenAI API key and preferred model (default `gpt-4.1`).
3. Optionally enable **OpenAI web search** for external facts (see App settings).
4. Click **Save**.

### Using chat

- Each page keeps its own in-memory chat session. Switch chapters and return later — your messages for that page are restored.
- **Send** — asks OpenAI using the current page text, optional `llms.txt` context, and chat history.
- **Send as Feedback** — saves the full conversation as a review Markdown file under `reviews/review_items/`.
- **Clear Chat** — clears the current page’s messages.

The chat header shows the page title, detected chapter ID, and (when an API key is set) a **context token** line:

- **Context: N tokens (est.)** — estimated prompt size before you send (page content, history, draft message, book context).
- After a reply, **reply: N** shows completion tokens when the API returns usage.

With **OpenAI web search** enabled, the model may look up external projects or current facts; page content is still included every time.

---

## 11. Tools mode overview

Open a tool from **Tools** in the sidebar. The center column switches from preview to that tool. Click **Back to Reading** to restore the preview at the same chapter.

| Tool | Purpose |
|------|---------|
| **Search** | Natural-language search across the book (AI-planned or literal fallback) |
| **Reviews** | Browse review items; submit structured feedback |
| **Figures** | Scan, add, and manage figures |
| **Tasks** | Generate and view Cursor task files |
| **Patches** | Review and apply agent patches |
| **Agent** | Built-in OpenAI tool-calling agent with audits and native tools |
| **Git** | Branch list, commit graph, working tree, stage, and commit |
| **Settings** | Per-book configuration |

The **Agent** tool uses a two-column layout: task controls on the left, live **activity** on the right (assistant messages and tool steps interleaved).

---

## 12. Reviews tool

Browse structured review items scanned from `reviews/review_items/`.

Click **Submit Review** in the toolbar to show the manual feedback form (moved from the old inspector panel).

### Feedback form fields

| Field | Description |
|-------|-------------|
| Chapter ID | Auto-filled from preview when possible (use frontmatter id, not `docs/` path) |
| Type / Severity | Review classification |
| Title / Body | Required for **Save Review** |
| Suggested Fix | Optional |

Use **Use Selected Text**, **Save Review** (⌘Return), and **Clear Form**.

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

## 13. Figures tool

BookLoop scans Markdown image references, output assets under `docs/assets/figures/`, source scripts, and `bookloop/figures.json`.

### Add a figure

Use **Add Figure** in the Figures toolbar (or **Add Figure…** on a missing/stale figure) to open the figure proposal sheet. You can:

- **Upload** an image file into `docs/assets/figures/`
- **URL** — reference an external image URL
- **Script** — Mermaid, Graphviz, or a custom command that writes the output asset

Fill in figure ID, caption, target Markdown chapter, then build a patch proposal. BookLoop opens **Patches** when the patch file is ready.

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

## 14. Tasks tool

Shows Markdown task files in `bookloop/tasks/`.

### Generate tasks

| Button | Task type |
|--------|-----------|
| **Current Chapter Task** | Patch proposal for the chapter detected in Preview |
| **Validation Task** | Ask an agent to validate the book |
| **Refresh** | Rescan the tasks folder |

Select a task file to view its contents. Use **Open Task in Finder** or **Copy Task Text** to paste into Cursor or another tool.

### Run validation command

If a **validation command** is configured and **Allow shell commands** is enabled, you can run validation from this tool. BookLoop shows a confirmation dialog before executing anything.

---

## 15. Search tool

Search helps you find concepts, terms, or topics across the manuscript.

1. Open **Tools → Search**.
2. Describe what you want in plain language (for example, “mentions of LoRA fine-tuning”).
3. Choose **Scope** — whole project, current chapter only, or reviews.
4. Click **Search**.

With an OpenAI API key, BookLoop plans one or more grep/text searches and shows the **Search plan** before results. Without a key, it uses a **Literal** fallback plan (keyword-style) and suggests adding a key for smarter planning.

Results are grouped by file with line numbers. Click a result to jump to that chapter in Reading mode when possible.

---

## 16. Agent tool

The **Native Agent** runs inside BookLoop using OpenAI tool-calling and Swift file/build/git tools. It does not require an external Cursor CLI harness.

### Prerequisites

1. Configure your OpenAI API key in app settings (sidebar gear).
2. Select a book in the library.
3. Optionally click **Initialize Config** to create `.bookloop/config.json` in the book root (build command, protected paths, allowed write globs).

### Built-in tasks

Tasks are grouped in the left column:

| Category | Task | Purpose |
|----------|------|---------|
| Reviews & content | **Apply Review Feedback** | Read open review items and propose edits as a patch |
| Reviews & content | **Improve Current Chapter** | Improve the chapter open in Reading mode |
| Book quality | **Check Consistency** | Multiturn audit: table of contents, grep/search, terminology and cross-chapter consistency |
| Book quality | **Check Logical Flow** | Multiturn audit: narrative order, prerequisites, and transitions |
| Assets & links | **Fix Broken Links** | Find broken figure paths, missing assets, bad URLs; propose fixes |
| Explore | **Summarize Project** | Scan chapters, reviews, and config; produce a summary |
| — | **Run Custom Task** | Your instruction in the custom task field |

For **Check Consistency** and **Check Logical Flow**, enable **Propose fixes after consistency / flow audit** to let the agent stage patch fixes after reporting. Audit reports are saved under `bookloop/audit-reports/`; major findings can also create items in `reviews/review_items/`.

While a task runs, the **activity** column shows assistant replies and tool steps in order (list files, read file, grep, search, record audit finding, stage patch, build, git status/diff, fetch URL, and more). When finished, you see a summary, staged files, and often a **patch proposal** at `bookloop/patches/agent-*.patch`.

### Propose-only workflow

The native Agent **does not modify book files on disk**. Each `apply_patch` call stages an exact-text replacement. At the end of a run, BookLoop exports a unified diff to `bookloop/patches/`. Review and apply it from **Tools → Patches**.

### Session artifacts

- Each run writes a session folder under **`.bookloop/sessions/<uuid>/`** — tool log JSON, diff staging temp files, and a copy of the proposal patch. These are **debug/audit logs**, not review content.
- The human-facing patch for **Tools → Patches** is written to **`bookloop/patches/agent-*.patch`**.
- **Do not commit** `.bookloop/sessions/`. Use **Ensure Gitignore** on the Agent panel to add it to your book’s `.gitignore`.
- **Delete Proposal Patch** removes the exported proposal from `bookloop/patches/` without changing book content.
- Staging is limited to paths allowed in `.bookloop/config.json`; protected paths (`.git`, `.bookloop`, etc.) cannot be modified.

**Why not `reviews/`?** The `reviews/` folder holds editor feedback (input). Agent session logs are machine-generated tooling output (like build cache). Keeping them under hidden `.bookloop/` avoids cluttering editorial folders.

Agent settings (max iterations, build timeout, fetch URL size, review edits) are in [App settings](#20-app-settings-openai--native-agent).

After an audit run, the results area shows the **Audit report** path, finding count, and any review IDs created.

---

## 17. Patches tool

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

For very long reviews, increase **Max tool iterations** in app settings (default 20, up to 40) or run the agent again after committing the first batch.

---

## 18. Git tool

**Tools → Git** provides a three-panel git workspace for the selected book:

| Panel | Content |
|-------|---------|
| **Branches** | Local branches; select another branch to checkout (with confirmation) |
| **Commit History** | Graph-style commit timeline |
| **Working Tree** | Staged and unstaged file lists |

The bottom bar supports **Refresh**, **Stage All**, a commit message field, and **Commit**.

Git commands run only when **Allow patch apply** or **Allow shell commands** is enabled in book Settings (same guard as Patches Step 3). If disabled, use **Copy Commit Command** to run git manually in Terminal.

This tab is for day-to-day git hygiene. The **Patches** tool remains the place for block-by-block review of agent `.patch` files.

---

## 19. Settings tool

Full book configuration in one form. Sections:

### Book

Display name, project root, and security-scoped folder access.

### Paths

Paths to `bookloop.yml`, `docs/`, review folders, figure folders, `bookloop/`, style guide, and figures registry.

If you have `mkdocs.yml` but no `bookloop.yml`, use **Create bookloop.yml from mkdocs.yml** to migrate navigation.

### Commands

Optional shell commands (reference only unless execution is explicitly allowed):

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

## 20. App settings (OpenAI & native agent)

Global app settings (not per-book) are opened from the **gear** icon in the sidebar header.

| Setting | Description |
|---------|-------------|
| **OpenAI Model** | Model slug for Chapter Chat, Search planning, and the Native Agent (default `gpt-4.1`) |
| **OpenAI API Key** | Stored in the macOS Keychain; required for Chapter Chat, Search planning, and Agent |
| **Chapter preview theme** | System / Light / Dark for in-app preview only |
| **Enable OpenAI web search** | Chapter Chat uses the Responses API with hosted web search for external facts |
| **Max tool iterations** | Agent tool-calling limit (1–40, default 20) |
| **Build timeout** | Seconds for agent `run_build` (30–600) |
| **Fetch URL max size** | Max bytes for agent `fetch_url` (public HTTPS pages) |
| **Allow agent to edit review items** | Lets the agent stage writes under `reviews/` when allowed by config |
| **Auto-run build after patch apply** | Reserved for future use when applying patches from the Patches tab |

Use **Remove Key** to delete the saved key.

Per-book agent path rules live in `.bookloop/config.json` (initialize from **Tools → Agent**).

---

## 21. Safety and permissions

BookLoop is built around explicit, human-visible actions:

- **Chapter Chat**, **Search** planning, and the **Native Agent** call OpenAI only when you use them and an API key is configured (Search falls back to literal matching without a key)
- Agent file writes are path-guarded and exported as patch proposals for Patches-tab review before apply
- Feedback is written directly to `reviews/review_items/` as Markdown review files
- No automatic shell execution unless toggles are on and you confirm
- No silent patch application—always confirm, and run `git apply --check` first
- Figure regeneration requires both **Allow shell commands** and **Allow figure regeneration**

When in doubt, leave safety toggles off and omit your OpenAI key if you only want reading, feedback submission, and task file generation.

---

## 22. Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘R | Reload preview (BookLoop menu) |
| ⌘Return | Save Review (feedback form) |
| ⌘S | Save Settings (Settings tool) |
| ⌘Return | Save (book settings sheet) |

---

## 23. Troubleshooting

### Preview shows blank or error

- Confirm `docs/` exists and contains the chapter Markdown file.
- Check `bookloop.yml` (or legacy `mkdocs.yml` nav) points to valid `.md` paths.
- Use toolbar **Refresh** to reload navigation and the current chapter.

### Save Review fails

- Confirm the chapter ID matches a file under `docs/` (for example `home` → `docs/home.md`).
- Ensure BookLoop has folder access to the book project (re-save the book in **Edit** if needed).
- Check the **review_items** path in Settings and that the folder exists or can be created.

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
- Check the activity column and error message in **Tools → Agent**.

### Search returns no results

- Try a shorter or more specific query.
- Confirm the book is selected and `docs/` is readable.
- Without an API key, only literal keyword planning is used — add a key for AI-planned searches.

### Git tab commands are disabled

- Enable **Allow patch apply** or **Allow shell commands** in book Settings.
- Confirm the project root is a git repository.

### Annotations do not persist

- Re-save the book in **Edit** if BookLoop lost security-scoped access to the project folder.
- Check `.bookloop/preview_annotations.json` or Application Support under `BookLoop/annotations/`.

### `.bookloop/sessions/` files show as uncommitted in git

These files (`changed_files.json`, `diff.patch`, `project_snapshot.json`, `diff-staging/`, etc.) are **agent session logs**, not book content or reviews.

- **Do not commit them.** They change on every agent run and would clutter git history.
- In **Tools → Agent**, click **Ensure Gitignore** (or add `.bookloop/sessions/` to your book’s `.gitignore` manually).
- After that, git will ignore future session folders. Remove any already-tracked session files with `git rm -r --cached .bookloop/sessions/` if you committed them by mistake.
- What **should** be committed after a successful patch apply is **`docs/`** (and any other manuscript paths you changed), via **Patches → Step 3: Commit to git**.

### Chapter not detected in preview

- Add YAML frontmatter with `id: your-chapter-id` to the Markdown source.
- BookLoop also injects `<meta name="chapter-id">` from frontmatter during rendering.
- Or enter the chapter ID manually in the Reviews feedback form.

---

## Quick reference

| Item | Default |
|------|---------|
| Navigation config | `bookloop.yml` |
| Review items folder | `reviews/review_items/` |
| Preview annotations (project mirror) | `.bookloop/preview_annotations.json` |
| Agent audit reports | `bookloop/audit-reports/` |

---

For developer-oriented setup, architecture notes, and build details, see [README.md](README.md).
