/// The page-side half of find in page (B-407). It runs in its own content
/// world (`LeoWKPageFinder.world`), so the page's scripts never see it, and it
/// never changes the DOM: matches are painted through the CSS Custom Highlight
/// API (a selection stands in where WebKit lacks it).
///
/// One body serves every action. `callAsyncJavaScript` passes `action`
/// (`search`, `next`, `previous`, `clear`, `selection`) and `query`; the body
/// returns `{index, total, capped}` (index is 1-based, 0 for none), or the
/// page's selected text for `selection`. Every step scans the page again, so
/// content that changed since the last call is picked up and the current
/// index is clamped.
enum LeoBrowserFindScript {
    /// Most matches counted; one more sets `capped`.
    static let matchLimit = 1_000
    static let allHighlight = "leo-find"
    static let currentHighlight = "leo-find-current"

    static let body = """
    const LIMIT = \(matchLimit);
    const state = (globalThis.__leoFind ||= { query: '', index: 0, sheet: null, usedSelection: false });
    const SKIPPED = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'HEAD', 'TITLE']);
    const highlights = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight === 'function' ? CSS.highlights : null;

    const lower = (text) => {
      let out = '';
      for (const ch of text) {
        const l = ch.toLowerCase();
        out += l.length === ch.length ? l : ch;
      }
      return out;
    };

    const visibility = new Map();
    const isRendered = (el) => {
      if (!visibility.has(el)) {
        const style = getComputedStyle(el);
        visibility.set(el, el.getClientRects().length > 0 && style.visibility !== 'hidden');
      }
      return visibility.get(el);
    };
    const blocks = new Map();
    const blockOf = (el) => {
      if (!blocks.has(el)) {
        let node = el;
        while (node && node !== document.body && getComputedStyle(node).display.startsWith('inline')) node = node.parentElement;
        blocks.set(el, node);
      }
      return blocks.get(el);
    };

    const scan = (query) => {
      const needle = lower(query).replace(/\\s+/g, ' ');
      const ranges = [];
      let capped = false;
      if (!needle || !document.body) return { ranges, capped };
      const nodes = [];
      let text = '';
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const el = node.parentElement;
          if (!el || !node.nodeValue) return NodeFilter.FILTER_REJECT;
          for (let a = el; a; a = a.parentElement) if (SKIPPED.has(a.tagName)) return NodeFilter.FILTER_REJECT;
          return isRendered(el) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        },
      });
      let previousBlock = null;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const block = blockOf(node.parentElement);
        if (nodes.length && block !== previousBlock) text += '\\n';
        previousBlock = block;
        nodes.push({ node, start: text.length });
        text += lower(node.nodeValue);
      }
      const locate = (offset, isEnd) => {
        let lo = 0, hi = nodes.length - 1;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (nodes[mid].start <= offset) lo = mid; else hi = mid - 1;
        }
        const entry = nodes[lo];
        const local = Math.min(offset - entry.start, entry.node.nodeValue.length);
        return { node: entry.node, offset: local };
      };
      for (let at = text.indexOf(needle); at !== -1; at = text.indexOf(needle, at + needle.length)) {
        if (ranges.length === LIMIT) { capped = true; break; }
        const from = locate(at, false);
        const to = locate(at + needle.length - 1, true);
        const range = document.createRange();
        range.setStart(from.node, from.offset);
        range.setEnd(to.node, Math.min(to.offset + 1, to.node.nodeValue.length));
        ranges.push(range);
      }
      return { ranges, capped };
    };

    const ensureSheet = () => {
      if (state.sheet) return;
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(
        '::highlight(\(allHighlight)) { background-color: #ffe44d; color: #000; }' +
        '::highlight(\(currentHighlight)) { background-color: #ff9f0a; color: #000; }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      state.sheet = sheet;
    };

    const clearPaint = () => {
      if (highlights) {
        highlights.delete('\(allHighlight)');
        highlights.delete('\(currentHighlight)');
      }
      if (state.sheet) {
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== state.sheet);
        state.sheet = null;
      }
      if (state.usedSelection) {
        getSelection().removeAllRanges();
        state.usedSelection = false;
      }
    };

    const reveal = (range) => {
      const rect = range.getBoundingClientRect();
      const inView = rect.top >= 0 && rect.bottom <= innerHeight && rect.left >= 0 && rect.right <= innerWidth;
      if (!inView) range.startContainer.parentElement?.scrollIntoView({ block: 'center', inline: 'nearest' });
    };

    const paint = (ranges, current) => {
      if (highlights) {
        ensureSheet();
        const all = new Highlight(...ranges);
        const one = new Highlight(ranges[current]);
        one.priority = 1;
        highlights.set('\(allHighlight)', all);
        highlights.set('\(currentHighlight)', one);
      } else {
        const selection = getSelection();
        selection.removeAllRanges();
        selection.addRange(ranges[current]);
        state.usedSelection = true;
      }
      reveal(ranges[current]);
    };

    const result = (index, total, capped) => ({ index, total, capped });

    if (action === 'selection') return String(getSelection() ?? '');
    if (action === 'clear' || !query) {
      state.query = '';
      state.index = 0;
      clearPaint();
      return result(0, 0, false);
    }

    const { ranges, capped } = scan(query);
    if (!ranges.length) {
      state.query = query;
      state.index = 0;
      clearPaint();
      return result(0, 0, false);
    }
    let current = state.query === query ? Math.min(Math.max(state.index - 1, 0), ranges.length - 1) : 0;
    if (action === 'next' && state.query === query) current = (current + 1) % ranges.length;
    if (action === 'previous') current = (current - 1 + ranges.length) % ranges.length;
    state.query = query;
    state.index = current + 1;
    paint(ranges, current);
    return result(current + 1, ranges.length, capped);
    """
}
