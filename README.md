# BookLoop

BookLoop is a native macOS companion for MkDocs books. It is designed as a
local-first AI/Human revision cockpit: read the rendered book, capture
structured feedback, generate Cursor-ready revision tasks, inspect proposed
patches, and apply approved diffs safely.

BookLoop does not call external LLM APIs unless you configure an OpenAI key for
Chapter Chat or the built-in Native Agent. Feedback is saved directly as Markdown
under `reviews/review_items/`, and agent-created changes must pass through human-visible patch
review before apply.

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
  .bookloop/
    config.json
    sessions/
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

## Save feedback locally

**Save Review** (Reviews tool) and **Send as Feedback** (Chapter Chat) write Markdown files directly to:

```text
reviews/review_items/
```

No external feedback server is required.

## Native Agent (optional)

BookLoop includes a built-in agent that uses OpenAI tool-calling from Swift. It
can list and read project files, search text, read review items, stage guarded
patches, run the configured build command, and inspect git status/diff.

Edits are **propose-only**: `apply_patch` stages changes in memory and BookLoop
writes a unified diff to `bookloop/patches/agent-*.patch` at the end of a run.
Book files are not modified until you review and apply the patch in **Tools → Patches**.

Requirements:

- OpenAI API key in app settings (Keychain)
- Optional `.bookloop/config.json` in the book root (initialize from **Tools → Agent**)

Session logs are stored under `.bookloop/sessions/`. Use **Delete Proposal Patch**
to remove an exported proposal without changing book content. Path guards and allowed
write globs are defined in `.bookloop/config.json`.

The agent is optional. Core workflows (feedback, tasks, patches) work without it.

## Add a book in BookLoop

Use the sidebar Add button and select the MkDocs project root. Defaults:

```text
Preview URL: http://127.0.0.1:8000
Review items: reviews/review_items/
```

Book settings persist in:

```text
~/Library/Application Support/BookLoop/books.json
```

When a project root is selected or saved, BookLoop stores a security-scoped
bookmark for that folder so sandboxed builds can regain access to the local book
between launches.

## Workflow

```text
Read -> Save Review -> Generate Task -> Agent Creates Patch -> Review Patch -> Apply -> Rebuild
```

Or use **Tools → Agent** for in-app edits with session revert and git diff review.

Task files are generated under:

```text
bookloop/tasks/
```

Patch proposals are scanned from:

```text
bookloop/patches/*.patch
bookloop/patches/*.diff
```

Patch review is rendered at the block level. BookLoop parses each unified-diff
hunk into a rendered before/after HTML block so reviewers can accept or reject
whole semantic blocks instead of reading a classical line-by-line Git diff.

When blocks are accepted, BookLoop can save a new reviewed patch containing only
accepted blocks:

```text
bookloop/patches/reviewed-YYYYMMDD-HHMMSS-<patch-name>.patch
```

Patch application is explicit and guarded. If enabled for the book, BookLoop can
show `git status --short`, run `git apply --check`, and then run `git apply` for
either the full original patch or the accepted-blocks reviewed patch:

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
5. **High-level architecture**: Book library, preview, feedback client, review browser, figure manager, task generator, patch manager, and native OpenAI agent with Swift tools are implemented.
6. **Important local APIs**: MkDocs preview health check; optional OpenAI for Chapter Chat and Native Agent.
7. **Book configuration**: `BookConfig` includes the requested paths, commands, notes, defaults, existing-path inference, and suggested-path filling.
8. **Persistence**: Book library and selected book ID persist to `~/Library/Application Support/BookLoop/books.json` with auto-save on store updates.
9. **Main app layout**: Native three-pane `NavigationSplitView` with sidebar, tabbed workspace, and workflow inspector.
10. **Main app modes**: Preview, Reviews, Figures, Tasks, Patches, and Settings tabs are present.
11. **WKWebView preview**: Reusable WebView/WebViewModel supports load, reload, back, forward, current URL/title, and external browser opening.
12. **Chapter ID detection**: Detects `meta[name="chapter-id"]`, falls back to URL/file slug, and supports manual override in the feedback panel.
13. **Selected text capture**: `Use Selected Text` reads `window.getSelection()?.toString()` and appends it to feedback/task context.
14. **Feedback models**: Requested feedback enums and Codable request/response models are implemented with `suggested_fix`.
15. **Local feedback writer**: Saves structured review Markdown under `reviews/review_items/` with frontmatter matching the review parser.
16. **Feedback panel**: Inspector form supports validation, selected text, save review, clear form, success, and failure states.
17. **Review item browser**: Scans Markdown review items, parses frontmatter/best-effort Markdown, filters, searches, sorts, groups, and displays cumulative/index files.
18. **Task generation**: Generates Cursor-ready Markdown tasks under `bookloop/tasks/` for reviews, chapters, figures, and validation.
19. **Native Agent**: OpenAI tool-calling loop with list/read/search/stage-patch/build/git tools; exports proposals to `bookloop/patches/`; `.bookloop/config.json` and session logging.
20. **Patch management**: Scans `.patch`/`.diff`, parses unified diffs, renders before/after HTML blocks, supports block-level accept/reject, creates accepted-block reviewed patches, shows git status/preflight checks, safely applies, and archives rejected patches.
21. **Markdown editing**: Full native editing is intentionally out of v1; current chapter Markdown can be opened externally or revealed in Finder.
22. **Chapter discovery**: Best-effort scanner reads `mkdocs.yml` nav entries, scans `docs/**/*.md`, and uses Markdown frontmatter IDs/titles.
23. **Figure management**: Scans Markdown references, output assets, source scripts, and `bookloop/figures.json`; detects missing, stale, unreferenced, and registered figures.
24. **Figure proposal workflow**: Figure tasks request reproducible sources, output assets, captions, insertion patches, and validation.
25. **Validation**: Generates validation tasks and can run a configured validation command asynchronously only when shell commands are enabled and confirmed.
26. **Status dashboard**: Sidebar shows preview status and open review count.
27. **Settings UI**: Settings form includes paths, commands, security-scoped bookmarks, safety toggles, and notes; app settings cover OpenAI and native agent limits.
28. **Safety rules**: No OpenAI calls without a key, guarded agent writes exported as patch proposals, no automatic shell execution, no silent patch application, and explicit confirmations for commands.
29. **Suggested file organization**: Source is organized into the requested top-level folders; several related small types are consolidated into shared Swift files for this v1 scaffold.
30. **Implementation order**: The branch was built in the requested sequence: shell, library, preview, feedback, chapter detection, reviews, tasks, figures, patches, and polish.
31. **UI details**: Uses native sidebar sections, toolbar actions, status badges, inspector panels, tabs, empty states, and restrained styling.
32. **Error handling**: Missing folders, offline APIs, invalid URLs, bad patches, permission issues, and command failures are surfaced as empty states or messages.
33. **README**: This README documents expected structure, MkDocs startup, local feedback, BookLoop setup, workflow, patch safety, and build instructions.
34. **Acceptance criteria**: The app covers all listed v1 acceptance criteria in source; macOS runtime verification requires Xcode on macOS 14+.
35. **Non-goals for v1**: Rich Markdown editing, collaboration, automatic AI rewriting without review, and a custom MkDocs renderer are intentionally excluded. External Cursor CLI harness is replaced by the native agent.
