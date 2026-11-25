// Leo sidebar for the Mac artboards: the existing Agents list plus the new
// pinned Inbox entry under the search field. Load before icons.js.
// <aside class="side" data-state="full|empty" data-sel="inbox|none"></aside>
(() => {
  const row = ([cls, icon, name, time, detail = '']) => `
    <div class="row ${cls}"><i class="ic" data-i="${icon}" data-fill="${cls === 'ny' || cls === 'er' ? 1 : 0}"></i>
      <span class="nm">${name}</span><span class="t">${time}</span>${detail ? `<span class="d">${detail}</span>` : ''}</div>`;
  const machine = (name, groups) => `
    <div class="mach"><i class="ic chev" data-i="chevD"></i><span class="dot"></span>${name}</div>
    ${groups.map(([g, rows]) => `<div class="grp">${g}</div>${rows.map(row).join('')}`).join('')}`;

  const full = [
    machine('This Mac', [
      ['Needs you', [['ny', 'qbubble', 'leoterm', '4m', 'Asks: Ship Voice-to-Agent tonight…']]],
      ['Done', [['ok', 'checkc', 'edc-blog', '1h', 'Draft saved to drafts/2026-11-leo.md']]],
      ['Running', [['', 'moon', 'autopilot-scratch', '2m']]],
    ]),
    machine('Dionysus', [
      ['Needs you', [['ny', 'qbubble', 'olympus', '12m', 'Asks: What cap for the Plex cache?']]],
      ['Done', [['ok', 'checkc', 'assistant', '41m', 'Booked Thu 2:00 PM with Dr. Patel']]],
    ]),
    machine('Hestia', [
      ['Needs you', [['ny', 'hand', 'brooklyn-cam', '27m', 'Permission: Bash']]],
      ['Error', [['er', 'warnf', 'leo', '2h', 'release.yml failed: notarization']]],
    ]),
  ].join('');

  const empty = [
    machine('This Mac', [['Running', [['', 'moon', 'leoterm', '3m'], ['', 'moon', 'edc-blog', '18m']]]]),
    machine('Dionysus', [['Running', [['', 'moon', 'olympus', '6m'], ['', 'moon', 'assistant', '1m']]]]),
    machine('Hestia', [['Running', [['', 'moon', 'brooklyn-cam', '9m']]]]),
  ].join('');

  document.querySelectorAll('aside.side').forEach((el) => {
    const isEmpty = el.dataset.state === 'empty';
    const sel = el.dataset.sel === 'inbox' ? ' sel' : '';
    el.innerHTML = `
      <div class="lights"><i></i><i></i><i></i></div>
      <div class="side-h">Agents <i class="ic" data-i="plus"></i></div>
      <div class="search"><i class="ic" data-i="search"></i>Search agents</div>
      <div class="inbox-entry${sel}"><i class="ic" data-i="tray"></i>Inbox
        ${isEmpty ? '' : '<span class="badge">3</span>'}</div>
      <div class="side-sep"></div>
      ${isEmpty ? empty : full}
      <div class="side-foot"><i class="ic" data-i="terminal"></i><i class="ic" data-i="reload"></i></div>`;
  });
})();
