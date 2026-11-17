import Foundation

/// Input for a WebKit host that can't post native events into its web view
/// (iOS: UIKit can't synthesize touches or keys into WKWebView, B-305).
/// Each script runs in the snapshot's content world, finds its element by
/// ref like `locateRef`, and dispatches the DOM events a real tap or key
/// press would, then performs what the browser would do by default
/// (follow the link, insert the text, submit the form). The events are
/// untrusted (`isTrusted` is false), so a page that checks for that may
/// ignore them; the tool contract is the Mac's either way.
extension LeoBrowserScripts {
    /// The element for `ref`, scrolled into view, and its centre in
    /// viewport pixels; `stale` when the ref is gone.
    private static let resolveTarget = #"""
    const state = globalThis.__leoAgent;
    const el = state && state.refs.get(ref);
    if (!el || !el.isConnected) return { stale: true };
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const box = el.getBoundingClientRect();
    const x = box.left + box.width / 2, y = box.top + box.height / 2;
    const hit = document.elementFromPoint(x, y);
    const target = hit && (hit === el || el.contains(hit)) ? hit : el;
    const mouse = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button: 0 };
    const pointer = { ...mouse, pointerId: 1, pointerType: 'touch', isPrimary: true, width: 1, height: 1 };
    const enter = () => {
      target.dispatchEvent(new PointerEvent('pointerover', pointer));
      target.dispatchEvent(new PointerEvent('pointerenter', { ...pointer, bubbles: false }));
      target.dispatchEvent(new MouseEvent('mouseover', mouse));
      target.dispatchEvent(new MouseEvent('mouseenter', { ...mouse, bubbles: false }));
      target.dispatchEvent(new PointerEvent('pointermove', pointer));
      target.dispatchEvent(new MouseEvent('mousemove', mouse));
    };

    """#

    /// Body of an async function with argument `ref`: a tap on the centre
    /// of the element (pointer, mouse and click events, focusing what takes
    /// focus). `click()` runs the element's activation behaviour, so links
    /// follow, checkboxes toggle and submit buttons submit. Returns
    /// `{clicked: true}` or `{stale: true}`.
    public static let tapRef = resolveTarget + #"""
    enter();
    const pressed = target.dispatchEvent(new PointerEvent('pointerdown', { ...pointer, buttons: 1 }));
    if (pressed) target.dispatchEvent(new MouseEvent('mousedown', { ...mouse, buttons: 1 }));
    const focusable = target.closest('input,textarea,select,button,a[href],[tabindex],[contenteditable=""],[contenteditable="true"]');
    if (pressed && focusable && typeof focusable.focus === 'function') focusable.focus({ preventScroll: true });
    target.dispatchEvent(new PointerEvent('pointerup', pointer));
    if (pressed) target.dispatchEvent(new MouseEvent('mouseup', mouse));
    target.click();
    return { clicked: true };
    """#

    /// Body of an async function with argument `ref`: the pointer moves onto
    /// the element's centre and stays (`:hover` styles don't follow script
    /// events; menus that open on `mouseover` do). Returns `{hovered: true}`
    /// or `{stale: true}`.
    public static let hoverRef = resolveTarget + #"""
    enter();
    return { hovered: true };
    """#

    /// Body of an async function with arguments `startRef`, `endRef` and
    /// `steps`: a pointer drag from the start element's centre to the end's
    /// (press, `steps` moves with the button down, release), for a source
    /// that isn't HTML5-draggable (`html5Drag` covers those). The start is
    /// scrolled into view first and the end located once the button is down,
    /// as a finger would find it. Returns `{dragged: true}` or
    /// `{stale: <the ref that is gone>}`.
    public static let pointerDragRefs = #"""
    const state = globalThis.__leoAgent;
    const find = r => {
      const el = state && state.refs.get(r);
      return el && el.isConnected ? el : null;
    };
    const start = find(startRef);
    if (!start) return { stale: startRef };
    if (!find(endRef)) return { stale: endRef };
    const centre = el => {
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    };
    const fire = (type, point, buttons) => {
      const target = document.elementFromPoint(point.x, point.y) || document.body;
      const mouse = { bubbles: true, cancelable: true, composed: true, view: window, clientX: point.x, clientY: point.y, button: 0, buttons };
      const isPointer = type.startsWith('pointer');
      const event = isPointer ? new PointerEvent(type, { ...mouse, pointerId: 1, pointerType: 'touch', isPrimary: true }) : new MouseEvent(type, mouse);
      target.dispatchEvent(event);
    };
    start.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const from = centre(start);
    fire('pointerdown', from, 1);
    fire('mousedown', from, 1);
    const end = find(endRef);
    const to = end ? centre(end) : from;
    for (let i = 1; i <= steps; i++) {
      const point = { x: from.x + (to.x - from.x) * i / steps, y: from.y + (to.y - from.y) * i / steps };
      fire('pointermove', point, 1);
      fire('mousemove', point, 1);
      await new Promise(resolve => requestAnimationFrame(resolve));
    }
    fire('pointerup', to, 0);
    fire('mouseup', to, 0);
    return end ? { dragged: true } : { stale: endRef };
    """#

    /// Key events with default actions, shared by `typeRef` and `pressKey`:
    /// `press(target, key, mods)` dispatches keydown, keypress (printable
    /// keys and Enter) and keyup, and unless the page cancelled keydown does
    /// what the key does (insert, delete, Enter submits the form or adds a
    /// line, Tab moves focus, Space activates a button, the page keys scroll).
    private static let keyHelpers = #"""
    const keyCodes = { Enter: 13, Tab: 9, Backspace: 8, Escape: 27, ' ': 32, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39,
      ArrowDown: 40, Delete: 46, Home: 36, End: 35, PageUp: 33, PageDown: 34 };
    const codeOf = key => key === ' ' ? 'Space' : /^[a-z]$/i.test(key) ? 'Key' + key.toUpperCase()
      : /^[0-9]$/.test(key) ? 'Digit' + key : key;
    const keyCodeOf = key => keyCodes[key] ?? (/^F([0-9]+)$/.test(key) ? 111 + Number(key.slice(1)) : key.toUpperCase().charCodeAt(0));
    const isText = el => el && (el.isContentEditable || el instanceof HTMLTextAreaElement
      || (el instanceof HTMLInputElement && !['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'image', 'range', 'color'].includes(el.type)));
    const focusables = () => [...document.querySelectorAll('a[href],button,input,select,textarea,[tabindex],[contenteditable=""],[contenteditable="true"]')]
      .filter(el => !el.disabled && el.tabIndex >= 0 && el.getClientRects().length > 0);
    const defaultAction = (target, key, mods) => {
      const command = mods.metaKey || mods.ctrlKey;
      if (command && key.toLowerCase() === 'a') return document.execCommand('selectAll');
      if (command || mods.altKey) return;
      if (key === 'Enter') {
        if (target instanceof HTMLTextAreaElement || target.isContentEditable) return document.execCommand('insertLineBreak');
        if (target instanceof HTMLInputElement && target.form) return target.form.requestSubmit();
        if (target instanceof HTMLAnchorElement || target instanceof HTMLButtonElement) return target.click();
        return;
      }
      if (key === ' ' && (target instanceof HTMLButtonElement || (target instanceof HTMLInputElement && ['checkbox', 'radio', 'button', 'submit'].includes(target.type)))) return target.click();
      if (key.length === 1 && isText(target)) return document.execCommand('insertText', false, key);
      if (key === 'Backspace' && isText(target)) return document.execCommand('delete');
      if (key === 'Delete' && isText(target)) return document.execCommand('forwardDelete');
      if (key === 'Tab') {
        const list = focusables();
        const at = list.indexOf(document.activeElement);
        const next = list[(at + (mods.shiftKey ? -1 : 1) + list.length) % list.length];
        if (next) next.focus();
        return;
      }
      if (isText(target)) return;
      const page = innerHeight * 0.9;
      const scroll = { ArrowDown: [0, 40], ArrowUp: [0, -40], ArrowRight: [40, 0], ArrowLeft: [-40, 0], PageDown: [0, page],
        PageUp: [0, -page], ' ': [0, mods.shiftKey ? -page : page] }[key];
      if (scroll) return scrollBy(scroll[0], scroll[1]);
      if (key === 'Home') return scrollTo(scrollX, 0);
      if (key === 'End') return scrollTo(scrollX, document.documentElement.scrollHeight);
    };
    const press = (target, key, mods) => {
      const init = { key, code: codeOf(key), keyCode: keyCodeOf(key), which: keyCodeOf(key), bubbles: true, cancelable: true, composed: true, ...mods };
      let proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
      if (proceed && (key.length === 1 || key === 'Enter') && !mods.metaKey && !mods.ctrlKey) {
        proceed = target.dispatchEvent(new KeyboardEvent('keypress', { ...init, charCode: key === 'Enter' ? 13 : key.charCodeAt(0) }));
      }
      if (proceed) defaultAction(target, key, mods);
      target.dispatchEvent(new KeyboardEvent('keyup', init));
    };

    """#

    /// Body of an async function with arguments `ref`, `text` and `submit`:
    /// focuses the element, replaces its contents with `text` as typing
    /// would (WebKit's insertText fires beforeinput and input, so frameworks
    /// see it), fires change, and with `submit` presses Enter. Returns
    /// `{value}`, `{stale: true}`, or `{error}` for an element that takes no
    /// text.
    public static let typeRef = keyHelpers + #"""
    const state = globalThis.__leoAgent;
    const el = state && state.refs.get(ref);
    if (!el || !el.isConnected) return { stale: true };
    if (!isText(el)) return { error: `ref ${ref} is not a text field` };
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    el.focus({ preventScroll: true });
    if (typeof el.select === 'function') {
      el.select();
    } else {
      const range = document.createRange();
      range.selectNodeContents(el);
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    }
    let typed = text === '' ? document.execCommand('delete') : document.execCommand('insertText', false, text);
    const current = () => el.isContentEditable ? el.textContent : el.value;
    if (!typed || current() !== text) {
      const setter = !el.isContentEditable && Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
      if (setter) setter.call(el, text); else el.textContent = text;
      el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
    if (submit) press(el, 'Enter', {});
    return { value: current() };
    """#

    /// Body of an async function with arguments `key` (a `LeoBrowserKeyCombo`
    /// key) and `shift`, `ctrl`, `alt`, `meta`: the key pressed in whatever
    /// has focus. Returns `{pressed: true}`.
    public static let pressKey = keyHelpers + #"""
    const target = document.activeElement && document.activeElement !== document.documentElement ? document.activeElement : document.body;
    press(target || document.documentElement, key, { shiftKey: shift, ctrlKey: ctrl, altKey: alt, metaKey: meta });
    return { pressed: true };
    """#

    /// A user script for Leo's content world: reports the user's own key
    /// presses (trusted keydown, hardware or on-screen keyboard) to the
    /// `userInputHandlerName` handler, so the user takes control. Script
    /// events, the agent's included, are untrusted and never reported.
    /// Scrolling, zooming and finding send no keydown.
    public static let userKeyInput = #"""
    addEventListener('keydown', event => {
      if (!event.isTrusted) return;
      try { webkit.messageHandlers.\#(userInputHandlerName).postMessage('key'); } catch (_) {}
    }, true);
    """#

    /// The message handler, in Leo's world, that `userKeyInput` posts to.
    public static let userInputHandlerName = "leoUserInput"
}
