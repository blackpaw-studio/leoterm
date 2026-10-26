import Foundation

/// The JavaScript the agent browser injects into pages, as plain strings so
/// any WebKit host (the Mac app now, iOS later) runs the same scripts.
/// LeoKit never imports WebKit: the host decides which content world each
/// script runs in, as each one's documentation says.
public enum LeoBrowserScripts {
    /// Longest snapshot text an agent gets back, before the note.
    public static let snapshotLimit = 50_000

    /// The message handler the console hook posts to.
    public static let consoleHandlerName = "leoConsole"

    /// How many console messages a tab keeps.
    public static let consoleCapacity = 500

    /// The text an agent gets from a snapshot's raw `text`: cut at the last
    /// line that fits in `limit` characters, with a note when anything was
    /// left out.
    public static func snapshotText(_ text: String, truncated: Bool, limit: Int = snapshotLimit) -> String {
        guard truncated || text.count > limit else { return text }
        let head = text.prefix(limit)
        let kept = head.count < text.count ? head.lastIndex(of: "\n").map { head[..<$0] } ?? head : head
        return String(kept)
            + "\n[snapshot truncated at \(limit) characters; use browser_eval to read the rest of the page]"
    }

    /// Body of an async function run in an isolated content world, with
    /// arguments `gen` (a number that grows with every snapshot of the tab)
    /// and `limit`. Walks the visible DOM into an indented text tree with a
    /// role, accessible name and value per element, and gives each
    /// interactive element a ref (`s<gen>e<n>`) kept in a world-local map,
    /// so the page's own DOM and scripts never see it. A new snapshot or
    /// document drops the previous refs. Returns `{text, truncated}`.
    public static let snapshot = #"""
    const refs = new Map();
    globalThis.__leoAgent = { gen, refs };
    const INTERACTIVE = new Set(['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox',
      'listbox', 'option', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
      'menuitemradio', 'treeitem', 'clickable']);
    const NAMED_FROM_CONTENT = new Set(['link', 'button', 'heading', 'option', 'tab', 'menuitem', 'treeitem',
      'menuitemcheckbox', 'menuitemradio', 'cell', 'columnheader', 'rowheader', 'switch']);
    const TAG_ROLES = {
      BUTTON: 'button', SUMMARY: 'button', TEXTAREA: 'textbox', OPTION: 'option', NAV: 'navigation',
      MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', FORM: 'form', DIALOG: 'dialog', UL: 'list',
      OL: 'list', LI: 'listitem', TABLE: 'table', TR: 'row', TD: 'cell', TH: 'columnheader', ASIDE: 'complementary',
      H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
    };
    const INPUT_ROLES = {
      checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button', image: 'button',
      range: 'slider', number: 'spinbutton', search: 'searchbox', hidden: null,
    };
    const squash = (s, max = 200) => {
      const t = (s || '').replace(/\s+/g, ' ').trim();
      return t.length > max ? t.slice(0, max - 1) + '…' : t;
    };
    const quote = s => JSON.stringify(s);

    function roleOf(el) {
      const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
      if (explicit && explicit !== 'presentation' && explicit !== 'none') return explicit;
      const tag = el.tagName;
      if (tag === 'A' || tag === 'AREA') return el.hasAttribute('href') ? 'link' : null;
      if (tag === 'INPUT') {
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        return type in INPUT_ROLES ? INPUT_ROLES[type] : 'textbox';
      }
      if (tag === 'SELECT') return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
      if (tag === 'IMG') return el.getAttribute('alt') === '' ? null : 'img';
      if (TAG_ROLES[tag]) return TAG_ROLES[tag];
      if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
      if (el.hasAttribute('onclick') || el.tabIndex >= 0 && el.hasAttribute('tabindex')) return 'clickable';
      return null;
    }

    function nameOf(el, role) {
      const labelledBy = el.getAttribute('aria-labelledby');
      if (labelledBy) {
        const text = labelledBy.split(/\s+/).map(id => document.getElementById(id)).filter(Boolean)
          .map(n => n.textContent).join(' ');
        if (squash(text)) return squash(text);
      }
      const label = el.getAttribute('aria-label');
      if (squash(label)) return squash(label);
      if (el.labels && el.labels.length) {
        const text = squash(Array.from(el.labels).map(l => l.textContent).join(' '));
        if (text) return text;
      }
      if (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type)) {
        return squash(el.value || (el.type === 'submit' ? 'Submit' : ''));
      }
      if (el.tagName === 'IMG' || el.tagName === 'AREA') return squash(el.getAttribute('alt'));
      if (NAMED_FROM_CONTENT.has(role) || role === 'clickable') {
        const text = squash(el.innerText || el.textContent);
        if (text) return text;
      }
      return squash(el.getAttribute('placeholder') || el.getAttribute('title'));
    }

    function detailsOf(el, role) {
      const parts = [];
      if (role === 'heading') parts.push(`[level=${el.getAttribute('aria-level') || el.tagName.slice(1) || 2}]`);
      if ('checked' in el && (role === 'checkbox' || role === 'radio' || role === 'switch')) {
        if (el.checked) parts.push('[checked]');
      } else if (el.getAttribute('aria-checked') === 'true') parts.push('[checked]');
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') parts.push('[disabled]');
      if (el.getAttribute('aria-expanded')) parts.push(`[expanded=${el.getAttribute('aria-expanded')}]`);
      if (el.selected || el.getAttribute('aria-selected') === 'true') parts.push('[selected]');
      if (role === 'link' && el.getAttribute('href')) parts.push(`[url=${squash(el.getAttribute('href'), 200)}]`);
      return parts.join(' ');
    }

    function valueOf(el, role) {
      if (el.tagName === 'SELECT') {
        return squash(Array.from(el.selectedOptions).map(o => o.textContent).join(', '));
      }
      if (role === 'textbox' || role === 'searchbox' || role === 'spinbutton' || role === 'slider'
        || role === 'combobox') {
        if (el.type === 'password') return el.value ? '••••' : '';
        if ('value' in el) return squash(el.value, 500);
        if (el.isContentEditable) return squash(el.innerText, 500);
      }
      return '';
    }

    function isShown(el) {
      if (el.checkVisibility) {
        return el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true,
          opacityProperty: true, visibilityProperty: true });
      }
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && el.getClientRects().length > 0;
    }

    const lines = [];
    let length = 0;
    let truncated = false;
    function emit(depth, line) {
      if (truncated) return false;
      const text = '  '.repeat(depth) + '- ' + line;
      length += text.length + 1;
      if (length > limit) { truncated = true; return false; }
      lines.push(text);
      return true;
    }

    const childrenOf = el => {
      if (el.shadowRoot) return el.shadowRoot.childNodes;
      if (el.tagName === 'SLOT') {
        const assigned = el.assignedNodes({ flatten: true });
        if (assigned.length) return assigned;
      }
      return el.childNodes;
    };

    function walk(nodes, depth) {
      for (const child of nodes) {
        if (truncated) return;
        if (child.nodeType === Node.TEXT_NODE) {
          const text = squash(child.textContent, 500);
          if (text && child.parentElement && isShown(child.parentElement)) emit(depth, 'text: ' + quote(text));
          continue;
        }
        if (child.nodeType !== Node.ELEMENT_NODE) continue;
        const el = child;
        if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD'].includes(el.tagName)) continue;
        if (el.hidden || el.getAttribute('aria-hidden') === 'true') continue;
        if (getComputedStyle(el).display === 'none') continue;
        const role = roleOf(el);
        if (!role || !isShown(el)) {
          walk(childrenOf(el), depth);
          continue;
        }
        let line = role;
        const name = nameOf(el, role);
        if (name) line += ' ' + quote(name);
        if (INTERACTIVE.has(role) && !el.disabled) {
          const ref = `s${gen}e${refs.size + 1}`;
          refs.set(ref, el);
          line += ` [ref=${ref}]`;
        }
        const details = detailsOf(el, role);
        if (details) line += ' ' + details;
        const value = valueOf(el, role);
        if (value) line += ': ' + quote(value);
        if (!emit(depth, line)) return;
        if (NAMED_FROM_CONTENT.has(role) || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') continue;
        walk(childrenOf(el), depth + 1);
      }
    }
    if (document.title) emit(0, 'document ' + quote(squash(document.title)));
    if (document.body) walk(childrenOf(document.body), 0);
    return { text: lines.join('\n'), truncated };
    """#

    /// Body of an async function run in the snapshot's content world, with
    /// argument `ref`: scrolls the element into view and returns its
    /// border box in viewport (CSS) pixels as `{x, y, width, height}`, or
    /// `{stale: true}` when the ref is not from this document's latest
    /// snapshot or the element has left the document.
    public static let locateRef = #"""
    const state = globalThis.__leoAgent;
    const el = state && state.refs.get(ref);
    if (!el || !el.isConnected) return { stale: true };
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = el.getBoundingClientRect();
    return { x: r.left, y: r.top, width: r.width, height: r.height };
    """#

    /// Body of an async function run in the snapshot's content world, with
    /// argument `ref`: focuses the element and selects its contents, so
    /// typing replaces them. Returns `{stale: true}` like `locateRef`.
    public static let focusRef = #"""
    const state = globalThis.__leoAgent;
    const el = state && state.refs.get(ref);
    if (!el || !el.isConnected) return { stale: true };
    el.focus({ preventScroll: true });
    if (typeof el.select === 'function') {
      el.select();
    } else if (el.isContentEditable) {
      const range = document.createRange();
      range.selectNodeContents(el);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    return { focused: document.activeElement === el };
    """#

    /// A user script for the page world, at document start in the main
    /// frame: forwards `console.*` calls, uncaught errors and unhandled
    /// promise rejections to the `consoleHandlerName` message handler as
    /// `{level, text}`.
    public static let console = #"""
    (() => {
      const handlers = window.webkit && window.webkit.messageHandlers;
      const handler = handlers && handlers.\#(consoleHandlerName);
      if (!handler) return;
      const describe = value => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value);
        try { return JSON.stringify(value) ?? String(value); } catch (_) { return String(value); }
      };
      const post = (level, values) => {
        try {
          handler.postMessage({ level, text: values.map(describe).join(' ').slice(0, 10000) });
        } catch (_) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...values) {
          post(level, values);
          return original.apply(this, values);
        };
      }
      addEventListener('error', event => {
        const where = event.filename ? ` (${event.filename}:${event.lineno})` : '';
        post('error', [`Uncaught ${event.message}${where}`]);
      });
      addEventListener('unhandledrejection', event => post('error', ['Unhandled rejection:', event.reason]));
    })();
    """#
}
