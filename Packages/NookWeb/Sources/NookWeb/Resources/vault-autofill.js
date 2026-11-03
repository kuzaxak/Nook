// Nook Vault Autofill
// Licensed under GPL-3.0. See LICENSE.
//
// Runs in the isolated NookAutofill world of every http(s) frame; its handler exists only in
// that world, so a page can neither post to it nor call __nookVaultFill. Reports which login
// field has focus and where, offers a save after a sign-in with a typed password, and fills
// the fields Nook passes back once the user picked an account in Nook's own popover.
(() => {
  if (window.__nookVaultAutofill) return;
  window.__nookVaultAutofill = true;
  if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookAutofill;
  if (!handler) return;
  const post = message => { try { handler.postMessage(message); } catch (_) {} };

  const textTypes = new Set(['text', 'email', 'tel', 'url', '']);
  const userHint = /user|login|email|e-mail|account|identifier|phone/i;
  const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  let field = null;
  let lastSubmit = 0;

  const autocompleteOf = input => (input.getAttribute('autocomplete') || '').toLowerCase();
  const isUsable = input => !input.disabled && !input.readOnly && input.getClientRects().length > 0;
  const scopeOf = input => input.form || input.closest('form') || input.getRootNode();
  const passwordFields = scope => [...scope.querySelectorAll('input[type=password]')].filter(isUsable);

  function usernameFor(scope, password) {
    const inputs = [...scope.querySelectorAll('input')].filter(i => textTypes.has(i.type) && isUsable(i));
    let before = null;
    for (const input of inputs) {
      if (password && (password.compareDocumentPosition(input) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      before = input;
    }
    return before || inputs.find(i => userHint.test(`${i.name} ${i.id} ${autocompleteOf(i)}`)) || null;
  }

  function kindOf(input) {
    if (!(input instanceof HTMLInputElement) || !isUsable(input)) return null;
    if (input.type === 'password') return 'password';
    if (!textTypes.has(input.type)) return null;
    const autocomplete = autocompleteOf(input);
    if (/\b(username|email|webauthn)\b/.test(autocomplete)) return 'username';
    if (passwordFields(scopeOf(input)).length) return 'username';
    return userHint.test(`${input.name} ${input.id}`) ? 'username' : null;
  }

  // The field's rect in the top frame's viewport, or null when a cross-origin parent hides it.
  function viewportRect(input) {
    const rect = input.getBoundingClientRect();
    let x = rect.left, y = rect.top;
    try {
      for (let w = window; w !== w.top; w = w.parent) {
        const frame = w.frameElement;
        if (!frame) return null;
        const outer = frame.getBoundingClientRect();
        x += outer.left + frame.clientLeft;
        y += outer.top + frame.clientTop;
      }
    } catch (_) {
      return null;
    }
    return { x, y, width: rect.width, height: rect.height };
  }

  function report(input) {
    const kind = kindOf(input);
    if (!kind) {
      if (field) post({ type: 'blur' });
      field = null;
      return;
    }
    field = input;
    post({ type: 'focus', kind, rect: viewportRect(input), webauthn: /\bwebauthn\b/.test(autocompleteOf(input)) });
  }

  function offerSave(scope) {
    if (!scope || Date.now() - lastSubmit < 1000) return;
    const password = passwordFields(scope).find(i => i.value);
    const user = password && usernameFor(scope, password);
    if (!password || !user || !user.value) return;
    lastSubmit = Date.now();
    post({ type: 'submit', username: user.value, password: password.value });
  }

  document.addEventListener('focusin', event => report(event.composedPath()[0]), true);
  // A click in the field that already has focus brings the popover back.
  document.addEventListener('mousedown', event => {
    const target = event.composedPath()[0];
    if (target === field && target.getRootNode().activeElement === target) report(target);
  }, true);
  document.addEventListener('submit', event => offerSave(event.target), true);
  document.addEventListener('keydown', event => {
    const target = event.composedPath()[0];
    if (event.key === 'Enter' && target instanceof HTMLInputElement && target.type === 'password') offerSave(scopeOf(target));
  }, true);
  document.addEventListener('click', event => {
    const button = event.composedPath().find(node => node instanceof HTMLButtonElement || node instanceof HTMLInputElement);
    if (button && button.type === 'submit' && button.form) offerSave(button.form);
  }, true);

  function setValue(input, value) {
    valueSetter.call(input, value);
    input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
  }

  // Called by Nook in this world only, with the origin it asked the vault about.
  window.__nookVaultFill = (origin, username, password) => {
    if (location.origin !== origin || !field || !field.isConnected) return false;
    const scope = scopeOf(field);
    const passwordField = field.type === 'password' ? field : passwordFields(scope)[0];
    const userField = field.type === 'password' ? usernameFor(scope, field) : field;
    if (userField && username) setValue(userField, username);
    if (passwordField) setValue(passwordField, password);
    return true;
  };
})();
