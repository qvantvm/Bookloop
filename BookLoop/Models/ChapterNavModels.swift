import Foundation

struct ChapterNavItem: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let href: String
    let children: [ChapterNavItem]

    init(id: String? = nil, title: String, href: String, children: [ChapterNavItem] = []) {
        self.title = title
        self.href = href
        self.id = id ?? (href.isEmpty ? title : href)
        self.children = children
    }

    var isNavigable: Bool {
        !href.isEmpty && href != "#"
    }
}

enum ChapterNavExtractor {
    static let script = """
    (function() {
      var viewport = document.querySelector('meta[name=\\"viewport\\"]');
      if (!viewport) {
        viewport = document.createElement('meta');
        viewport.name = 'viewport';
        document.head.appendChild(viewport);
      }
      viewport.content = 'width=1600';

      var toggles = document.querySelectorAll('.md-nav__toggle');
      for (var i = 0; i < toggles.length; i++) {
        toggles[i].checked = true;
        toggles[i].setAttribute('checked', 'checked');
      }

      function directNavItems(list) {
        var items = [];
        for (var i = 0; i < list.children.length; i++) {
          var child = list.children[i];
          if (child.tagName === 'LI' && child.classList.contains('md-nav__item')) {
            items.push(child);
          }
        }
        return items;
      }

      function parseItem(li) {
        var link = li.querySelector('a.md-nav__link');
        if (!link) link = li.querySelector('label.md-nav__link');
        if (!link) return null;

        var title = (link.textContent || '').replace(/\\s+/g, ' ').trim();
        if (!title) return null;

        var href = '';
        if (link.tagName === 'A') {
          href = link.getAttribute('href') || '';
        }

        var children = [];
        var nestedNav = li.querySelector('nav.md-nav');
        if (nestedNav) {
          var childList = nestedNav.querySelector('ul.md-nav__list');
          if (childList) {
            var childLis = directNavItems(childList);
            for (var j = 0; j < childLis.length; j++) {
              var child = parseItem(childLis[j]);
              if (child) children.push(child);
            }
          }
        }

        return { title: title, href: href, children: children };
      }

      function parseRoot(root) {
        if (!root) return [];
        var items = [];
        var lis = directNavItems(root);
        for (var i = 0; i < lis.length; i++) {
          var item = parseItem(lis[i]);
          if (item) items.push(item);
        }
        return items;
      }

      var selectors = [
        '.md-nav--primary > .md-nav__list',
        '.md-sidebar--primary .md-nav__list',
        '[data-md-component=\\"navigation\\"] .md-nav__list'
      ];

      for (var s = 0; s < selectors.length; s++) {
        var root = document.querySelector(selectors[s]);
        var items = parseRoot(root);
        if (items.length > 0) {
          return JSON.stringify(items);
        }
      }

      return '[]';
    })();
    """
}
