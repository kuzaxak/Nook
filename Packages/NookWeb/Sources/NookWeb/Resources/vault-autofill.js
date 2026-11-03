// Nook Vault Autofill
// Licensed under GPL-3.0. See LICENSE.
//
// Runs in the isolated NookAutofill world of every http(s) frame; its handler exists only in
// that world, so a page can neither post to it nor call __nookVaultFill. Asks Nook for its
// account popover only after a real click or ArrowDown in a login or one-time-code field (never
// on focus, never for an event the page made), offers a save after a sign-in with a typed
// password, and fills the fields or code Nook passes back once the user picked an account in
// that popover. A split code field (4–8 adjacent one-character boxes) gets one digit per box.
(() => {
  if (window.__nookVaultAutofill) return;
  window.__nookVaultAutofill = true;
  if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookAutofill;
  if (!handler) return;
  const post = message => { try { handler.postMessage(message); } catch (_) {} };

  const textTypes = new Set(['text', 'email', 'tel', 'url', '']);
  const userHint = /user|login|email|e-mail|account|identifier|phone/i;
  const codeTypes = new Set(['text', 'tel', 'number']);
  const codeHint = /otp|totp|2fa|mfa|one.?time|verification.?code|security.?code|auth(entication)?.?code|2-?step/i;
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

  const isCodeBox = input =>
    input instanceof HTMLInputElement && codeTypes.has(input.type) && input.maxLength === 1 && isUsable(input);

  function codeBoxes(input) {
    if (!isCodeBox(input)) return null;
    const inputs = [...scopeOf(input).querySelectorAll('input')];
    let start = inputs.indexOf(input), end = start + 1;
    while (start > 0 && isCodeBox(inputs[start - 1])) start--;
    while (end < inputs.length && isCodeBox(inputs[end])) end++;
    return end - start >= 4 && end - start <= 8 ? inputs.slice(start, end) : null;
  }

  function isCodeField(input) {
    if (/\bone-time-code\b/.test(autocompleteOf(input))) return true;
    if (!codeTypes.has(input.type)) return false;
    if (codeBoxes(input)) return true;
    const labels = [...(input.labels || [])].map(label => label.textContent).join(' ');
    const hint = `${input.name} ${input.id} ${input.getAttribute('placeholder') || ''} ${input.getAttribute('aria-label') || ''} ${labels}`;
    const numeric = (input.maxLength >= 4 && input.maxLength <= 8)
      || (input.getAttribute('inputmode') || '').toLowerCase() === 'numeric';
    return numeric && codeHint.test(hint);
  }

  function kindOf(input) {
    if (!(input instanceof HTMLInputElement) || !isUsable(input)) return null;
    if (input.type === 'password') return 'password';
    if (isCodeField(input)) return 'code';
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

  function open(event) {
    if (!event.isTrusted) return;
    const input = event.composedPath()[0];
    const kind = kindOf(input);
    if (!kind) return;
    field = input;
    post({ type: 'open', kind, rect: viewportRect(input), webauthn: /\bwebauthn\b/.test(autocompleteOf(input)) });
  }

  function offerSave(scope) {
    if (!scope || Date.now() - lastSubmit < 1000) return;
    const password = passwordFields(scope).find(i => i.value);
    const user = password && usernameFor(scope, password);
    if (!password || !user || !user.value) return;
    lastSubmit = Date.now();
    post({ type: 'submit', username: user.value, password: password.value });
  }

  document.addEventListener('mousedown', open, true);
  document.addEventListener('keydown', event => { if (event.key === 'ArrowDown') open(event); }, true);
  // Focus moving to anything else closes the popover; focus never opens it.
  document.addEventListener('focusin', event => {
    if (!field || event.composedPath()[0] === field) return;
    field = null;
    post({ type: 'blur' });
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

  // Called by Nook in this world only, with the code for the field its picker opened for.
  window.__nookVaultFillCode = (origin, code) => {
    if (location.origin !== origin || !field || !field.isConnected || kindOf(field) !== 'code') return false;
    const boxes = codeBoxes(field);
    if (boxes) boxes.forEach((box, i) => setValue(box, code[i] || ''));
    else setValue(field, code);
    return true;
  };
})();
