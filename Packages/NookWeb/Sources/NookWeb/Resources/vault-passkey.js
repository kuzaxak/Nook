// Nook Vault Passkeys
// Licensed under GPL-3.0. See LICENSE.
//
// Page-world shim, installed in place of the passkey suppression script while Pawl Vault is
// connected or security keys are on. navigator.credentials.get/create with `publicKey` go to
// Nook's nookPasskey handler, which takes the origin from WebKit, checks the rpId, shows its
// own picker, confirmation or security key sheet and only then asks the vault or the key.
// Everything else goes to WebKit. `platform` is true while the vault is connected: only then
// does the page see a platform authenticator and conditional mediation.
(() => {
  const platform = __NOOK_PLATFORM__;
  if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookPasskey;
  if (!handler) return;
  const post = handler.postMessage.bind(handler);
  const container = CredentialsContainer.prototype;
  const nativeGet = container.get;
  const nativeCreate = container.create;
  const failed = 'The operation either timed out or was not allowed.';
  // Taken before page script runs, so a frame reports the ancestors WebKit gives it.
  const here = window.location;
  const ancestorsGetter = typeof Location === 'function'
    && (Object.getOwnPropertyDescriptor(Location.prototype, 'ancestorOrigins') || {}).get;
  const listLength = typeof DOMStringList === 'function'
    && (Object.getOwnPropertyDescriptor(DOMStringList.prototype, 'length') || {}).get;
  const listItem = typeof DOMStringList === 'function' && DOMStringList.prototype.item;
  function ancestorOrigins() {
    if (!ancestorsGetter || !listLength || !listItem) return null;
    const list = ancestorsGetter.call(here);
    const out = [];
    for (let i = 0, count = listLength.call(list); i < count; i++) out.push(listItem.call(list, i));
    return out;
  }

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected a BufferSource.');
  }
  function encode(source) {
    let binary = '';
    for (const byte of bytes(source)) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(text) {
    const base64 = text.replace(/-/g, '+').replace(/_/g, '/');
    const binary = atob(base64 + '==='.slice((base64.length + 3) % 4));
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out.buffer;
  }

  let nextRequest = 0;
  function request(op, payload, signal) {
    if (signal && signal.aborted) return Promise.reject(new DOMException('The operation was aborted.', 'AbortError'));
    const requestId = ++nextRequest;
    return new Promise((resolve, reject) => {
      let settled = false;
      const onAbort = () => {
        if (settled) return;
        settled = true;
        post({ op: 'abort', requestId, ancestorOrigins: ancestorOrigins() }).catch(() => {});
        reject(new DOMException('The operation was aborted.', 'AbortError'));
      };
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      post(Object.assign({ op, requestId, ancestorOrigins: ancestorOrigins() }, payload)).then(reply => {
        if (settled) return;
        settled = true;
        if (signal) signal.removeEventListener('abort', onAbort);
        if (!reply || reply.error) reject(new DOMException(failed, (reply && reply.error) || 'NotAllowedError'));
        else resolve(reply);
      }, () => {
        if (settled) return;
        settled = true;
        reject(new DOMException(failed, 'NotAllowedError'));
      });
    });
  }

  // Own data properties on the real prototypes, so `instanceof` holds and nothing reaches the
  // native getters, which only accept WebKit's own objects.
  function make(type, values) {
    const object = Object.create(type ? type.prototype : Object.prototype);
    for (const key of Object.keys(values)) Object.defineProperty(object, key, { value: values[key], enumerable: true });
    return object;
  }
  function credential(reply, response, responseJSON) {
    const attachment = reply.authenticatorAttachment || 'platform';
    const extensions = () => JSON.parse(JSON.stringify(reply.clientExtensionResults || {}));
    return make(window.PublicKeyCredential, {
      id: reply.id,
      rawId: decode(reply.id),
      type: 'public-key',
      authenticatorAttachment: attachment,
      response,
      getClientExtensionResults: extensions,
      toJSON: () => ({
        id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment,
        response: responseJSON, clientExtensionResults: extensions(),
      }),
    });
  }
  function assertion(reply) {
    const response = make(window.AuthenticatorAssertionResponse, {
      clientDataJSON: decode(reply.clientDataJSON),
      authenticatorData: decode(reply.authenticatorData),
      signature: decode(reply.signature),
      userHandle: reply.userHandle ? decode(reply.userHandle) : null,
    });
    return credential(reply, response, {
      clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData,
      signature: reply.signature, userHandle: reply.userHandle || undefined,
    });
  }
  function attestation(reply) {
    const transports = reply.transports || ['internal'];
    const values = {
      clientDataJSON: decode(reply.clientDataJSON),
      attestationObject: decode(reply.attestationObject),
      getTransports: () => transports.slice(),
      getAuthenticatorData: () => decode(reply.authenticatorData),
      getPublicKeyAlgorithm: () => reply.publicKeyAlgorithm,
    };
    const json = {
      clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject,
      authenticatorData: reply.authenticatorData, transports: transports.slice(),
      publicKeyAlgorithm: reply.publicKeyAlgorithm,
    };
    if ('publicKey' in reply) {
      values.getPublicKey = () => (reply.publicKey ? decode(reply.publicKey) : null);
      if (reply.publicKey) json.publicKey = reply.publicKey;
    }
    return credential(reply, make(window.AuthenticatorAttestationResponse, values), json);
  }

  container.get = function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    const key = options.publicKey;
    if (options.mediation === 'conditional' && !platform) {
      return Promise.reject(new DOMException('Conditional mediation is not supported.', 'NotSupportedError'));
    }
    let payload;
    try {
      payload = {
        challenge: encode(key.challenge),
        rpId: typeof key.rpId === 'string' ? key.rpId : null,
        allowCredentials: (key.allowCredentials || []).map(c => encode(c.id)),
        userVerification: key.userVerification || 'preferred',
        mediation: options.mediation === 'conditional' ? 'conditional' : 'optional',
        timeout: typeof key.timeout === 'number' ? key.timeout : null,
      };
    } catch (error) {
      return Promise.reject(error);
    }
    return request('get', payload, options.signal).then(assertion);
  };

  container.create = function create(options) {
    if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
    const key = options.publicKey;
    let payload;
    try {
      payload = {
        challenge: encode(key.challenge),
        rp: { id: key.rp && typeof key.rp.id === 'string' ? key.rp.id : null, name: (key.rp && key.rp.name) || '' },
        user: { id: encode(key.user.id), name: key.user.name || '', displayName: key.user.displayName || '' },
        pubKeyCredParams: algorithms(key.pubKeyCredParams),
        excludeCredentials: (key.excludeCredentials || []).map(c => encode(c.id)),
        authenticatorSelection: selection(key.authenticatorSelection),
        credProps: !!(key.extensions && key.extensions.credProps),
        timeout: typeof key.timeout === 'number' ? key.timeout : null,
      };
    } catch (error) {
      return Promise.reject(error);
    }
    return request('create', payload, options.signal).then(attestation);
  };

  // WebIDL: each entry needs a string type and an integer alg; types other than public-key
  // are skipped, and a list left with none is not supported.
  function algorithms(list) {
    if (list === undefined) return [];
    if (!Array.isArray(list)) throw new TypeError('pubKeyCredParams must be a sequence.');
    const out = [];
    for (const entry of list) {
      if (!entry || typeof entry !== 'object' || typeof entry.type !== 'string' || !Number.isInteger(entry.alg)) {
        throw new TypeError('Each pubKeyCredParams entry needs a type and an integer alg.');
      }
      if (entry.type === 'public-key') out.push(entry.alg);
    }
    if (list.length && !out.length) {
      throw new DOMException('None of the requested credential types is supported.', 'NotSupportedError');
    }
    return out;
  }

  function selection(value) {
    const out = {};
    if (!value) return out;
    for (const name of ['authenticatorAttachment', 'residentKey', 'userVerification']) {
      if (typeof value[name] === 'string') out[name] = value[name];
    }
    if (typeof value.requireResidentKey === 'boolean') out.requireResidentKey = value.requireResidentKey;
    return out;
  }

  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(platform);
  PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(platform);
})();
