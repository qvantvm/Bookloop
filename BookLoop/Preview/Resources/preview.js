(function () {
  function preprocessAdmonitions(source) {
    const lines = source.split("\n");
    const output = [];
    let index = 0;
    while (index < lines.length) {
      const line = lines[index];
      const match = line.match(/^!!!\s+(\w+)(?:\s+"([^"]*)")?\s*$/);
      if (!match) {
        output.push(line);
        index += 1;
        continue;
      }
      const kind = match[1].toLowerCase();
      const customTitle = match[2];
      index += 1;
      const body = [];
      while (index < lines.length) {
        const next = lines[index];
        if (/^!!!\s+\w+/.test(next) || /^#{1,6}\s/.test(next.trim())) break;
        if (next.trim() === "" && body.length > 0 && index + 1 < lines.length && !/^ {2,4}\S/.test(lines[index + 1])) break;
        body.push(next.replace(/^ {4}/, ""));
        index += 1;
      }
      const title = customTitle || kind.charAt(0).toUpperCase() + kind.slice(1);
      output.push(`<div class="admonition ${kind}"><p class="admonition-title">${title}</p>\n\n${body.join("\n")}\n\n</div>`);
    }
    return output.join("\n");
  }

  function preprocessDetailsBlocks(source) {
    return source.replace(/^(\?\?\?\+?\s+"([^"]+)")\s*\n((?: {4}.+\n?)+)/gm, function (_all, _header, title, body) {
      const cleaned = body.replace(/^ {4}/gm, "");
      return `<details open><summary>${title}</summary>\n\n${cleaned}\n\n</details>\n`;
    });
  }

  function rewriteInternalLinks(html, currentPath) {
    return html.replace(/href="([^"]+)"/g, function (_all, href) {
      if (!href || href.startsWith("#") || /^https?:\/\//i.test(href) || href.startsWith("bookloop://")) {
        return `href="${href}"`;
      }
      const resolved = resolveDocsPath(currentPath, href);
      if (!resolved) return `href="${href}"`;
      return `href="bookloop://chapter?path=${encodeURIComponent(resolved)}"`;
    });
  }

  function resolveDocsPath(currentPath, target) {
    if (!currentPath) return target;
    const currentParts = currentPath.split("/");
    currentParts.pop();
    const targetParts = target.split("/");
    for (const part of targetParts) {
      if (part === "." || part === "") continue;
      if (part === "..") currentParts.pop();
      else currentParts.push(part);
    }
    return currentParts.join("/");
  }

  function createMarkdownIt() {
    const md = window.markdownit({
      html: true,
      linkify: true,
      typographer: true,
      breaks: false
    });
    md.enable(["table", "strikethrough"]);
    return md;
  }

  window.BookLoopPreview = {
    render: function (markdown, currentPath) {
      const md = createMarkdownIt();
      let source = markdown || "";
      source = preprocessDetailsBlocks(source);
      source = preprocessAdmonitions(source);
      let html = md.render(source);
      html = rewriteInternalLinks(html, currentPath || "");
      return html;
    },
    renderMath: function (root) {
      if (!window.renderMathInElement) return;
      window.renderMathInElement(root, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false },
          { left: "\\[", right: "\\]", display: true }
        ],
        throwOnError: false
      });
    },

    contentRoot: function () {
      return document.getElementById("bookloop-content");
    },

    getTextNodeSegments: function (root) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
      const segments = [];
      let fullText = "";
      while (walker.nextNode()) {
        const node = walker.currentNode;
        const text = node.textContent || "";
        if (!text) continue;
        const start = fullText.length;
        fullText += text;
        segments.push({ node: node, start: start, end: start + text.length });
      }
      return { fullText: fullText, segments: segments };
    },

    findQuoteOffset: function (fullText, exact, prefix, suffix) {
      if (!exact) return -1;
      let index = 0;
      while (index <= fullText.length) {
        const found = fullText.indexOf(exact, index);
        if (found === -1) return -1;
        const before = fullText.slice(Math.max(0, found - 32), found);
        const after = fullText.slice(found + exact.length, found + exact.length + 32);
        const prefixOk = !prefix || before.endsWith(prefix);
        const suffixOk = !suffix || after.startsWith(suffix);
        if (prefixOk && suffixOk) return found;
        index = found + 1;
      }
      return -1;
    },

    rangeFromOffsets: function (segments, start, end) {
      let startNode = null;
      let startOffset = 0;
      let endNode = null;
      let endOffset = 0;
      for (const segment of segments) {
        if (!startNode && start >= segment.start && start <= segment.end) {
          startNode = segment.node;
          startOffset = start - segment.start;
        }
        if (!endNode && end >= segment.start && end <= segment.end) {
          endNode = segment.node;
          endOffset = end - segment.start;
        }
      }
      if (!startNode || !endNode) return null;
      const range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      return range;
    },

    wrapRangeWithHighlight: function (range, id, note) {
      const mark = document.createElement("mark");
      mark.className = "bookloop-highlight";
      mark.dataset.annotationId = id;
      if (note) mark.title = note;
      try {
        range.surroundContents(mark);
        return true;
      } catch (_error) {
        const contents = range.extractContents();
        mark.appendChild(contents);
        range.insertNode(mark);
        return true;
      }
    },

    captureSelectionQuote: function () {
      const root = window.BookLoopPreview.contentRoot();
      const selection = window.getSelection();
      if (!root || !selection || selection.isCollapsed || !selection.rangeCount) return null;
      const range = selection.getRangeAt(0);
      if (!root.contains(range.commonAncestorContainer)) return null;
      const exact = selection.toString();
      if (!exact || !exact.trim()) return null;

      const prefixRange = document.createRange();
      prefixRange.selectNodeContents(root);
      prefixRange.setEnd(range.startContainer, range.startOffset);
      const prefix = prefixRange.toString().slice(-32);

      const suffixRange = document.createRange();
      suffixRange.selectNodeContents(root);
      suffixRange.setStart(range.endContainer, range.endOffset);
      const suffix = suffixRange.toString().slice(0, 32);

      return { exact: exact, prefix: prefix, suffix: suffix };
    },

    applyHighlights: function (annotations) {
      const root = window.BookLoopPreview.contentRoot();
      if (!root) return { applied: 0, failed: 0 };
      root.querySelectorAll("mark.bookloop-highlight").forEach(function (mark) {
        const parent = mark.parentNode;
        while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
        parent.removeChild(mark);
        parent.normalize();
      });

      let applied = 0;
      let failed = 0;
      (annotations || []).forEach(function (annotation) {
        const { fullText, segments } = window.BookLoopPreview.getTextNodeSegments(root);
        const start = window.BookLoopPreview.findQuoteOffset(
          fullText,
          annotation.exact,
          annotation.prefix,
          annotation.suffix
        );
        if (start === -1) {
          failed += 1;
          return;
        }
        const range = window.BookLoopPreview.rangeFromOffsets(segments, start, start + annotation.exact.length);
        if (!range) {
          failed += 1;
          return;
        }
        if (window.BookLoopPreview.wrapRangeWithHighlight(range, annotation.id, annotation.note)) {
          applied += 1;
        } else {
          failed += 1;
        }
      });
      return { applied: applied, failed: failed };
    },

    setupAnnotationHandlers: function () {
      const root = window.BookLoopPreview.contentRoot();
      if (!root || root.dataset.bookloopAnnotationsBound === "1") return;
      root.dataset.bookloopAnnotationsBound = "1";
      root.addEventListener("click", function (event) {
        const mark = event.target.closest("mark.bookloop-highlight");
        if (!mark || !mark.dataset.annotationId) return;
        event.preventDefault();
        event.stopPropagation();
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bookloopAnnotation) {
          window.webkit.messageHandlers.bookloopAnnotation.postMessage({
            type: "click",
            id: mark.dataset.annotationId
          });
        }
      });
    }
  };
})();
