// Shared fixtures + tiny renderer for the Usage plugin mockups.
// Theme: append #dark to the URL.
document.documentElement.dataset.theme = location.hash === '#dark' ? 'dark' : 'light';

// Simplified stand-ins for SF Symbols (the real renderer uses the named symbols).
const ICONS = {
  sparkle: '<path class="f" d="M7 1.5c.4 2.9 1.6 4.1 4.5 4.5v.2C8.6 6.6 7.4 7.8 7 10.7h-.1C6.5 7.8 5.3 6.6 2.4 6.2V6C5.3 5.6 6.5 4.4 6.9 1.5z" transform="translate(0 1)"/>',
  terminal: '<rect x="1.5" y="2.5" width="11" height="9" rx="2"/><path d="M4 6l1.8 1.5L4 9M7.2 9.2h2.6"/>',
  chevronDown: '<path d="M3.5 5.5L7 9l3.5-3.5"/>',
  chevronRight: '<path d="M5.5 3.5L9 7l-3.5 3.5"/>',
  chevronLeft: '<path d="M8.5 3.5L5 7l3.5 3.5"/>',
  plus: '<path d="M7 2.5v9M2.5 7h9"/>',
  ellipsis: '<circle cx="7" cy="7" r="5.5"/><circle class="f" cx="4.6" cy="7" r=".8"/><circle class="f" cx="7" cy="7" r=".8"/><circle class="f" cx="9.4" cy="7" r=".8"/>',
  gauge: '<path d="M2 10a5 5 0 1 1 10 0"/><path d="M7 10l2.6-3"/>',
  warn: '<path d="M7 1.8l5.6 9.7H1.4z"/><path d="M7 5.4v2.8M7 9.9v.1"/>',
  xmarkPerson: '<circle cx="6" cy="4.6" r="2.2"/><path d="M1.8 12c.3-2.4 2-3.8 4.2-3.8 1 0 1.8.2 2.5.7"/><path d="M9.6 9.4l2.6 2.6M12.2 9.4l-2.6 2.6"/>',
  lock: '<rect x="3" y="6.3" width="8" height="6" rx="1.5"/><path d="M4.8 6.3V4.6a2.2 2.2 0 0 1 4.4 0v1.7"/>',
  refresh: '<path d="M11.5 7A4.5 4.5 0 1 1 10 3.6"/><path d="M10.3 1.6v2.3H8"/>',
  copy: '<rect x="4.5" y="4.5" width="7" height="7.5" rx="1.5"/><path d="M9.5 4.5V3.2c0-.8-.6-1.4-1.4-1.4H3.4c-.8 0-1.4.6-1.4 1.4v5.1c0 .8.6 1.4 1.4 1.4h1.1"/>',
  stale: '<path d="M11.5 7A4.5 4.5 0 1 1 10 3.6"/><path d="M10.3 1.6v2.3H8"/><path d="M7 5v2.3M7 9.2v.1"/>',
  moon: '<path d="M10.8 9.3A4.8 4.8 0 0 1 4.7 3.2 4.8 4.8 0 1 0 10.8 9.3z"/>',
  search: '<circle cx="6" cy="6" r="3.8"/><path d="M8.8 8.8L12 12"/>',
  return: '<path d="M11.5 3v4.2H3M5.5 4.7L3 7.2l2.5 2.5"/>',
};
const icon = (name, cls = '') =>
  `<svg class="i ${cls}" viewBox="0 0 14 14">${ICONS[name].replace(/class="f"/g, 'style="fill:currentColor;stroke:none"')}</svg>`;

const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[c]);

// Meter {label, value, valueText?, detail?, tone}
const meter = (m) => `
  <div class="meter ${m.tone}" role="meter">
    <span class="m-label">${esc(m.label)}</span>
    <span class="m-track">${m.value > 0 ? `<span class="m-fill" style="width:${Math.round(Math.min(1, m.value) * 1000) / 10}%"></span>` : ''}</span>
    <span class="m-value">${esc(m.valueText ?? '')}</span>
    ${m.detail ? `<span class="m-detail">${m.detail}</span>` : ''}
  </div>`;

const accessory = (a) => a ? `<span class="acc ${a.color}">${a.sfSymbol ? icon(a.sfSymbol) : ''}${esc(a.text ?? '')}</span>` : '';

const toneFor = (pct) => (pct >= 90 ? 'failure' : pct >= 75 ? 'warning' : 'success');
const win = (label, pct, detail) => ({ label, value: pct / 100, valueText: `${pct}%`, detail, tone: toneFor(pct) });

// Fixture accounts. `top` is the highest window (what the sidebar shows).
const ACCOUNTS = [
  { label: 'blackpaw-leo', kind: 'claude', path: '~/.claude-blackpaw-leo', updated: 'Updated 3m ago',
    windows: [win('Session', 42, 'Resets in 2h 14m'), win('Weekly', 56, 'Resets Thu 9:00 PM'),
      win('Weekly Opus', 12, 'Resets Thu 9:00 PM'), win('Weekly Sonnet', 61, 'Resets Thu 9:00 PM')], top: 0 },
  { label: 'blackpaw-evan', kind: 'claude', path: '~/.claude-blackpaw-evan', updated: 'Updated 3m ago',
    windows: [win('Session', 34, 'Resets in 4h 02m'), win('Weekly', 91, 'Resets Mon 9:00 AM'),
      win('Weekly Sonnet', 79, 'Resets Mon 9:00 AM')], top: 1 },
  { label: 'jackie', kind: 'claude', path: '~/.claude-jackie', state: 'expired' },
  { label: 'codex', kind: 'codex', path: '~/.codex', updated: 'Updated 3m ago',
    windows: [win('Session', 18, 'Resets in 3h 40m'), win('Weekly', 9, 'Resets Nov 27')], top: 0 },
];

const EXPIRED = { accessory: { sfSymbol: 'xmarkPerson', text: 'Expired', color: 'failure' },
  subtitle: (a) => `Signed out — run <code>${a.kind}</code> with this account to refresh`,
  action: { title: 'Copy Sign-in Command', sfSymbol: 'copy' } };
const NEEDS_AUTH = { accessory: { sfSymbol: 'lock', text: 'Locked', color: 'warning' },
  subtitle: () => 'Leo needs Keychain access to read this account',
  action: { title: 'Grant Access…', sfSymbol: 'lock' } };
const STALE = { accessory: { sfSymbol: 'stale', text: 'Stale', color: 'warning' } };

const glyphFor = (kind) => icon(kind === 'codex' ? 'terminal' : 'sparkle');

// Meters in one slot share a label column sized to the widest label (capped at
// 40% of the meter width) so their tracks start on the same x.
function alignLabels(root) {
  const meters = [...root.querySelectorAll('.meter')];
  if (!meters.length) return;
  const widest = Math.max(...meters.map((m) => {
    const l = m.querySelector('.m-label'); l.style.width = 'max-content';
    const w = l.getBoundingClientRect().width; l.style.width = ''; return w; }));
  const cap = meters[0].getBoundingClientRect().width * 0.4;
  root.style.setProperty('--label-col', Math.ceil(Math.min(widest, cap)) + 'px');
}
