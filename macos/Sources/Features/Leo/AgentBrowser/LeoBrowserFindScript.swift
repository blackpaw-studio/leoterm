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

    // Lower case that never changes a character's length, so offsets stay put.
    const lowerChar = (ch) => {
      const l = ch.toLowerCase();
      return l.length === ch.length ? l : ch;
    };
    const lower = (text) => Array.from(text, lowerChar).join('');

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

    // The page's visible text with every run of whitespace (a no-break space
    // included) read as one space, and a break between blocks and at each <br>.
    // `nodeOf` and `offsetOf` take a position in that text back to its text
    // node and offset, so a match becomes a range on the real nodes.
    const scan = (query) => {
      const needle = lower(query).replace(/\\s+/g, ' ');
      const ranges = [];
      let capped = false;
      if (!needle || !document.body) return { ranges, capped };
      const nodes = [];
      const nodeOf = [];
      const offsetOf = [];
      let text = '';
      let last = '';
      const emit = (ch, node, offset) => {
        text += ch;
        last = ch;
        nodeOf.push(node);
        offsetOf.push(offset);
      };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
        acceptNode(node) {
          if (node.nodeType === Node.ELEMENT_NODE) return node.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
          const el = node.parentElement;
          if (!el || !node.nodeValue) return NodeFilter.FILTER_REJECT;
          for (let a = el; a; a = a.parentElement) if (SKIPPED.has(a.tagName)) return NodeFilter.FILTER_REJECT;
          return isRendered(el) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        },
      });
      let previousBlock = null;
      let breakPending = false;
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          breakPending = true;
          continue;
        }
        const block = blockOf(node.parentElement);
        if (nodes.length && last !== '\\n' && (breakPending || block !== previousBlock)) emit('\\n', -1, 0);
        breakPending = false;
        previousBlock = block;
        const index = nodes.push(node) - 1;
        let offset = 0;
        for (const ch of node.nodeValue) {
          if (/\\s/.test(ch)) {
            if (last !== '' && last !== ' ' && last !== '\\n') emit(' ', index, offset);
          } else {
            const l = lowerChar(ch);
            for (let k = 0; k < l.length; k++) emit(l[k], index, offset + k);
          }
          offset += ch.length;
        }
      }
      for (let at = text.indexOf(needle); at !== -1; at = text.indexOf(needle, at + needle.length)) {
        if (ranges.length === LIMIT) { capped = true; break; }
        const end = at + needle.length - 1;
        if (nodeOf[at] < 0 || nodeOf[end] < 0) continue;
        const range = document.createRange();
        range.setStart(nodes[nodeOf[at]], offsetOf[at]);
        range.setEnd(nodes[nodeOf[end]], Math.min(offsetOf[end] + 1, nodes[nodeOf[end]].nodeValue.length));
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

    // A replaced highlight must give its ranges up: WebKit repaints a range when
    // its highlight lets go of it, but not when the registry swaps the highlight
    // for another, which left the old query's marks painted.
    const retire = (name) => {
      const old = highlights.get(name);
      if (!old) return;
      old.clear();
      highlights.delete(name);
    };

    const clearPaint = () => {
      if (highlights) {
        retire('\(allHighlight)');
        retire('\(currentHighlight)');
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

    // Scrolls until the match itself is on screen. The element holding it can
    // be taller than the window (a long <pre>), so centring it is not enough.
    const reveal = (range) => {
      const targetRect = () => range.getClientRects()[0] ?? range.getBoundingClientRect();
      const isVisible = (rect) => rect.top >= 0 && rect.bottom <= innerHeight && rect.left >= 0 && rect.right <= innerWidth;
      if (isVisible(targetRect())) return;
      range.startContainer.parentElement?.scrollIntoView({ block: 'center', inline: 'nearest' });
      const rect = targetRect();
      if (isVisible(rect)) return;
      const dy = rect.top + rect.height / 2 - innerHeight / 2;
      const outsideX = rect.left < 0 || rect.right > innerWidth;
      scrollBy(outsideX ? rect.left + rect.width / 2 - innerWidth / 2 : 0, dy);
    };

    const paint = (ranges, current) => {
      if (highlights) {
        ensureSheet();
        retire('\(allHighlight)');
        retire('\(currentHighlight)');
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
