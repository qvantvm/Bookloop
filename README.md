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