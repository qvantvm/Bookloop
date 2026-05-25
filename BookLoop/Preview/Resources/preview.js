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
    }
  };
})();
