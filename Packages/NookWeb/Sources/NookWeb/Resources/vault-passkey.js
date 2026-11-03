// Nook Vault Passkeys
// Licensed under GPL-3.0. See LICENSE.
//
// Page-world shim, installed only while Pawl Vault is connected, in place of the passkey
// suppression script. navigator.credentials.get/create with `publicKey` go to Nook's
// nookPasskey handler, which takes the origin from WebKit, checks the rpId, shows its own
// picker or confirmation and only then asks the vault. Everything else goes to WebKit.
(() => {
  if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nookPasskey;
  if (!handler) return;
  const post = handler.postMessage.bind(handler);
  const container = CredentialsContainer.prototype;
  const nativeGet = container.get;
  const nativeCreate = container.create;
  const failed = 'The operation either timed out or was not allowed.';

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
        post({ op: 'abort', requestId }).catch(() => {});
        reject(new DOMException('The operation was aborted.', 'AbortError'));
      };
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      post(Object.assign({ op, requestId }, payload)).then(reply => {
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
    return make(window.PublicKeyCredential, {
      id: reply.id,
      rawId: decode(reply.id),
      type: 'public-key',
      authenticatorAttachment: 'platform',
      response,
      getClientExtensionResults: () => ({}),
      toJSON: () => ({
        id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: 'platform',
        response: responseJSON, clientExtensionResults: {},
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
    const response = make(window.AuthenticatorAttestationResponse, {
      clientDataJSON: decode(reply.clientDataJSON),
      attestationObject: decode(reply.attestationObject),
      getTransports: () => ['internal'],
      getAuthenticatorData: () => decode(reply.authenticatorData),
      getPublicKeyAlgorithm: () => reply.publicKeyAlgorithm,
    });
    return credential(reply, response, {
      clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject,
      authenticatorData: reply.authenticatorData, transports: ['internal'],
      publicKeyAlgorithm: reply.publicKeyAlgorithm,
    });
  }

  container.get = function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    const key = options.publicKey;
    let payload;
    try {
      payload = {
        challenge: encode(key.challenge),
        rpId: typeof key.rpId === 'string' ? key.rpId : null,
        allowCredentials: (key.allowCredentials || []).map(c => encode(c.id)),
        userVerification: key.userVerification || 'preferred',
        mediation: options.mediation === 'conditional' ? 'conditional' : 'optional',
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
        pubKeyCredParams: (key.pubKeyCredParams || []).map(p => p.alg),
        excludeCredentials: (key.excludeCredentials || []).map(c => encode(c.id)),
      };
    } catch (error) {
      return Promise.reject(error);
    }
    return request('create', payload, options.signal).then(attestation);
  };

  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(true);
  PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(true);
})();
