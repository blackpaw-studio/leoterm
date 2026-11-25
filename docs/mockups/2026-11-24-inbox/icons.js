// SF Symbol stand-ins (16pt grid, stroke = currentColor). Replaces <i class="ic" data-i="name">.
// Also applies ?theme=dark so one artboard file renders both appearances.
(() => {
  const S = {
    gear: '<circle cx="8" cy="8" r="2.3"/><path d="M8 1.6v1.8M8 12.6v1.8M1.6 8h1.8M12.6 8h1.8M3.5 3.5l1.3 1.3M11.2 11.2l1.3 1.3M3.5 12.5l1.3-1.3M11.2 4.8l1.3-1.3"/><circle cx="8" cy="8" r="4.6"/>',
    puzzle: '<path d="M3 5.5h2.2a1.5 1.5 0 1 1 3 0H10.5v2.3a1.5 1.5 0 1 1 0 3V13H3z"/>',
    laptop: '<rect x="3" y="3.5" width="10" height="7" rx="1"/><path d="M1.5 12.5h13"/>',
    server: '<rect x="2.5" y="2.5" width="11" height="4.5" rx="1.2"/><rect x="2.5" y="9" width="11" height="4.5" rx="1.2"/><path d="M5 4.75h.01M5 11.25h.01"/>',
    doc: '<path d="M4 1.8h5.2L12 4.6v9.6H4z"/><path d="M9 1.8v3h3M6 8h4M6 10.5h4"/>',
    clock: '<circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.4 1.6"/>',
    leaf: '<path d="M3 13c0-6 3.5-9.5 10-10-.3 6.8-4 10-10 10z"/><path d="M3 13l5.5-5.5"/>',
    branch: '<circle cx="4" cy="3.5" r="1.5"/><circle cx="4" cy="12.5" r="1.5"/><circle cx="12" cy="6" r="1.5"/><path d="M4 5v6M12 7.5c0 2.5-3 2.5-6.5 4"/>',
    palette: '<path d="M8 2a6 6 0 1 0 0 12c1 0 1.3-.7 1-1.5-.4-.9.2-1.8 1.2-1.8H12a2 2 0 0 0 2-2C14 4.6 11.3 2 8 2z"/><circle cx="5" cy="7" r=".6"/><circle cx="7.5" cy="4.8" r=".6"/><circle cx="10.6" cy="5.6" r=".6"/>',
    sliders: '<path d="M2.5 4.5h11M2.5 11.5h11"/><circle cx="5.5" cy="4.5" r="1.6" fill="var(--icfill,#fff)"/><circle cx="10.5" cy="11.5" r="1.6" fill="var(--icfill,#fff)"/>',
    gear2: '<circle cx="6" cy="9.5" r="3.6"/><circle cx="6" cy="9.5" r="1.2"/><circle cx="11.5" cy="4.5" r="2.4"/><circle cx="11.5" cy="4.5" r=".7"/>',
    pulse: '<path d="M1.5 8.5h3l1.5-4 3 8 1.5-4h4"/>',
    chevR: '<path d="M6 3l5 5-5 5"/>',
    chevL: '<path d="M10 3L5 8l5 5"/>',
    chevD: '<path d="M3 6l5 5 5-5"/>',
    updown: '<path d="M4.5 6L8 2.8 11.5 6M4.5 10L8 13.2 11.5 10"/>',
    search: '<circle cx="7" cy="7" r="4.5"/><path d="M10.4 10.4L14 14"/>',
    plus: '<path d="M8 2.5v11M2.5 8h11"/>',
    minus: '<path d="M2.5 8h11"/>',
    seal: '<path d="M8 1.5l1.6 1.2 2-.1.6 1.9 1.6 1.2-.6 1.9.6 1.9-1.6 1.2-.6 1.9-2-.1L8 14.5l-1.6-1.2-2 .1-.6-1.9L2.2 10.3l.6-1.9-.6-1.9 1.6-1.2.6-1.9 2 .1z"/><path d="M5.6 8.1l1.6 1.6 3.2-3.2"/>',
    terminal: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M4.5 6.5l2 1.8-2 1.8M8 10.2h3.5"/>',
    globe: '<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c2 2 2 10 0 12M8 2c-2 2-2 10 0 12"/>',
    play: '<path d="M5 3.2v9.6L12.5 8z"/>',
    reload: '<path d="M13 8a5 5 0 1 1-1.5-3.6"/><path d="M12 1.8v2.8H9.2"/>',
    warn: '<path d="M8 2l6.3 11H1.7z"/><path d="M8 6.5v3M8 11.5h.01"/>',
    info: '<circle cx="8" cy="8" r="6"/><path d="M8 7.2V11M8 5h.01"/>',
    lock: '<rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/>',
    check: '<path d="M3 8.5l3.2 3L13 4.5"/>',
    browser: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M1.8 5.8h12.4M4 4.3h.01M5.6 4.3h.01"/>',
    gauge: '<path d="M2.5 11a5.5 5.5 0 1 1 11 0"/><path d="M8 11l2.6-3.4"/>',
    key: '<circle cx="5" cy="10.5" r="2.8"/><path d="M7 8.5l6-6M11 4.5l1.6 1.6"/>',
    folder: '<path d="M1.8 4.2c0-.7.5-1.2 1.2-1.2h3l1.5 1.5H13c.7 0 1.2.5 1.2 1.2v6.8c0 .7-.5 1.2-1.2 1.2H3c-.7 0-1.2-.5-1.2-1.2z"/>',
    person2: '<circle cx="6" cy="5.5" r="2.3"/><path d="M1.8 13c.4-2.4 2.2-3.8 4.2-3.8s3.8 1.4 4.2 3.8"/><circle cx="11.2" cy="5" r="1.8"/><path d="M11 9c1.7 0 3 1.2 3.3 3.2"/>',
    tray: '<path d="M1.8 9.2l1.9-5.6c.2-.5.6-.8 1.1-.8h6.4c.5 0 .9.3 1.1.8l1.9 5.6v3.2c0 .6-.5 1-1 1H2.8c-.6 0-1-.4-1-1z"/><path d="M1.8 9.2h3.6l.8 1.6h3.6l.8-1.6h3.6"/>',
    hand: '<path d="M5.6 9.4V4.2M7.8 7.6V3M10 7.6V3.6M12.2 8.4V5.2"/><path d="M12.2 8.4v1.6c0 2.3-1.6 4-3.9 4-1.5 0-2.6-.7-3.5-2L3 9.3c-.5-.7.4-1.6 1.1-1l1.5 1.4"/>',
    qbubble: '<path d="M8 2.2c3.4 0 6 2.2 6 5s-2.6 5-6 5c-.6 0-1.2-.1-1.8-.2L3 13.4l.6-2.6C2.6 9.9 2 8.6 2 7.2c0-2.8 2.6-5 6-5z"/><path d="M6.6 5.9c.1-.8.7-1.3 1.5-1.3s1.5.5 1.5 1.3c0 1.1-1.5 1.1-1.5 2.1M8.1 9.6h.01" stroke="var(--ink-on,#fff)"/>',
    checkc: '<circle cx="8" cy="8" r="6.2"/><path d="M5.2 8.3l1.9 1.8 3.7-4"/>',
    warnf: '<path d="M8 1.9l6.4 11.2H1.6z"/><path d="M8 6v3.2M8 11.2h.01" stroke="var(--ink-on,#fff)"/>',
    moon: '<path d="M12.8 10.2A5.6 5.6 0 0 1 5.8 3.2a5.6 5.6 0 1 0 7 7z"/>',
    goto: '<path d="M6 3.5H3.5v9h9V10"/><path d="M8.5 2.5h5v5M13.5 2.5L7.5 8.5"/>',
    xmark: '<path d="M4 4l8 8M12 4l-8 8"/>',
    sendup: '<path d="M8 13V3.5M3.8 7.6L8 3.4l4.2 4.2"/>',
    ellipsis: '<path d="M3.5 8h.01M8 8h.01M12.5 8h.01" stroke-width="2.4"/>',
    bubble: '<path d="M8 2.5c3.3 0 6 2.1 6 4.8S11.3 12 8 12c-.7 0-1.3-.1-1.9-.2L3 13.4l.7-2.5C2.6 10 2 8.7 2 7.3c0-2.7 2.7-4.8 6-4.8z"/>',
    compose: '<path d="M12.6 2.3l1.1 1.1-6.3 6.3-1.6.5.5-1.6z"/><path d="M13 8.3v4.2c0 .6-.5 1-1 1H3.5c-.6 0-1-.4-1-1V4c0-.6.4-1 1-1h4.2"/>',
    person: '<circle cx="8" cy="5.3" r="2.7"/><path d="M2.8 14c.5-3 2.6-4.5 5.2-4.5s4.7 1.5 5.2 4.5"/>',
    gearf: '<circle cx="8" cy="8" r="2.3"/><circle cx="8" cy="8" r="5"/>',
    sidebar: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M6 2.8v10.4"/>',
    filter: '<path d="M2.5 4h11M4.5 8h7M6.5 12h3"/>',
    clock2: '<circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.4 1.6"/>',
  };
  const render = (el) => {
    const name = el.dataset.i;
    const fillish = name === 'play' || (el.dataset.fill === '1' && name !== 'hand');
    el.innerHTML = `<svg viewBox="0 0 16 16" fill="${fillish ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="${el.dataset.w || 1.5}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${S[name] || ''}</svg>`;
  };
  const theme = new URLSearchParams(location.search).get('theme');
  if (theme) document.documentElement.dataset.theme = theme;
  document.querySelectorAll('.ic[data-i]').forEach(render);
})();
