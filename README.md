# BookLoop

BookLoop is a native macOS companion for MkDocs books. It is designed as a
local-first AI/Human revision cockpit: read the rendered book, capture
structured feedback, generate Cursor-ready revision tasks, inspect proposed
patches, and apply approved diffs safely.

BookLoop does not call external LLM APIs and does not silently rewrite book
files. Feedback is submitted through the local feedback API, and agent-created
changes must pass through human-visible patch review.

## Expected book structure

```text
my-book/
  mkdocs.yml
  docs/
    index.md
    chapters/
    assets/
      figures/
  reviews/
    review_items/
    cumulative_review.md
    review_index.json
  figures/
  bookloop/
    style_guide.md
    figures.json
    tasks/
    patches/
```

## Start MkDocs

From the book root:

```bash
mkdocs serve
```

BookLoop defaults the preview URL to:

```text
http://127.0.0.1:8000
```

## Start the Feedback API

From the book root:

```bash
python scripts/feedback_api.py --host 127.0.0.1 --port 8765
```

BookLoop submits structured reviews to:

```text
http://127.0.0.1:8765/api/review
```

It never writes review Markdown files directly.

## Optional Agent Harness

BookLoop can check and optionally submit local tasks to a future agent harness
at:

```text
http://127.0.0.1:8770
```

The harness is optional. Core workflows work without it.

## Add a book in BookLoop

Use the sidebar Add button and select the MkDocs project root. Defaults:

```text
Preview URL: http://127.0.0.1:8000
Feedback API: http://127.0.0.1:8765
Agent Harness: http://127.0.0.1:8770
```

Book settings persist in:

```text
~/Library/Application Support/BookLoop/books.json
```

## Workflow

```text
Read -> Save Review -> Generate Task -> Agent/Cursor Creates Patch -> Review Patch -> Apply -> Rebuild
```

Task files are generated under:

```text
bookloop/tasks/
```

Patch proposals are scanned from:

```text
bookloop/patches/*.patch
bookloop/patches/*.diff
```

Patch application is explicit and guarded. If enabled for the book, BookLoop
runs:

```bash
git apply --check bookloop/patches/example.patch
git apply bookloop/patches/example.patch
```

It never force-applies patches.

## Build

Open `BookLoop.xcodeproj` in Xcode on macOS 14 or newer and run the `BookLoop`
scheme.

## Implementation checklist against the original prompt

1. **Product definition**: Implemented the native macOS BookLoop scaffold for multiple MkDocs books, preview, feedback, reviews, tasks, figures, and patches.
2. **Core principle**: AI/agent edits are represented as task files and patch proposals; BookLoop does not silently rewrite book content.
3. **Target platform and technology**: Swift, SwiftUI, WKWebView, URLSession, Codable, async/await, FileManager, and guarded Process usage; no external packages.
4. **App name**: Xcode product, bundle display name, target, and window title use `BookLoop`.
5. **High-level architecture**: Book library, preview, feedback client, review browser, figure manager, task generator, patch manager, and optional harness client are implemented.
6. **Important local APIs**: Feedback API and optional agent harness API clients include health checks and structured requests.
7. **Book configuration**: `BookConfig` includes the requested paths, commands, notes, defaults, existing-path inference, and suggested-path filling.
8. **Persistence**: Book library and selected book ID persist to `~/Library/Application Support/BookLoop/books.json` with auto-save on store updates.
9. **Main app layout**: Native three-pane `NavigationSplitView` with sidebar, tabbed workspace, and workflow inspector.
10. **Main app modes**: Preview, Reviews, Figures, Tasks, Patches, and Settings tabs are present.
11. **WKWebView preview**: Reusable WebView/WebViewModel supports load, reload, back, forward, current URL/title, and external browser opening.
12. **Chapter ID detection**: Detects `meta[name="chapter-id"]`, falls back to URL/file slug, and supports manual override in the feedback panel.
13. **Selected text capture**: `Use Selected Text` reads `window.getSelection()?.toString()` and appends it to feedback/task context.
14. **Feedback models**: Requested feedback enums and Codable request/response models are implemented with `suggested_fix`.
15. **Feedback API client**: URL trimming, async URLSession calls, decoding, HTTP body errors, and offline help text are implemented.
16. **Feedback panel**: Inspector form supports validation, API check, selected text, save review, clear form, success, and failure states.
17. **Review item browser**: Scans Markdown review items, parses frontmatter/best-effort Markdown, filters, searches, sorts, groups, and displays cumulative/index files.
18. **Task generation**: Generates Cursor-ready Markdown tasks under `bookloop/tasks/` for reviews, chapters, figures, and validation.
19. **Optional Agent Harness Client**: Scaffolded health check and fix-review submission; task-file generation remains the default workflow.
20. **Patch management**: Scans `.patch`/`.diff`, parses unified diffs, displays hunks, copies raw patches/commands, safely applies, and archives rejected patches.
21. **Markdown editing**: Full native editing is intentionally out of v1; current chapter Markdown can be opened externally or revealed in Finder.
22. **Chapter discovery**: Best-effort scanner reads `mkdocs.yml` nav entries, scans `docs/**/*.md`, and uses Markdown frontmatter IDs/titles.
23. **Figure management**: Scans Markdown references, output assets, source scripts, and `bookloop/figures.json`; detects missing, stale, unreferenced, and registered figures.
24. **Figure proposal workflow**: Figure tasks request reproducible sources, output assets, captions, insertion patches, and validation.
25. **Validation**: Generates validation tasks and can run a configured validation command only when shell commands are enabled and confirmed.
26. **Status dashboard**: Inspector/sidebar show preview, feedback API, agent harness, reviews, figures, patches, and task counts.
27. **Settings UI**: Settings form includes all requested fields, path pickers, path inference, suggestions, safety toggles, and notes.
28. **Safety rules**: No external LLM calls, no direct feedback-file writes, no automatic shell execution, no silent patch application, and explicit confirmations for commands.
29. **Suggested file organization**: Source is organized into the requested top-level folders; several related small types are consolidated into shared Swift files for this v1 scaffold.
30. **Implementation order**: The branch was built in the requested sequence: shell, library, preview, feedback, chapter detection, reviews, tasks, figures, patches, and polish.
31. **UI details**: Uses native sidebar sections, toolbar actions, status badges, inspector panels, tabs, empty states, and restrained styling.
32. **Error handling**: Missing folders, offline APIs, invalid URLs, bad patches, permission issues, and command failures are surfaced as empty states or messages.
33. **README**: This README documents expected structure, MkDocs/feedback startup, BookLoop setup, workflow, patch safety, and build instructions.
34. **Acceptance criteria**: The app covers all listed v1 acceptance criteria in source; macOS runtime verification requires Xcode on macOS 14+.
35. **Non-goals for v1**: Rich Markdown editing, direct LLM API integration, collaboration, automatic AI rewriting, and a custom MkDocs renderer are intentionally excluded.
