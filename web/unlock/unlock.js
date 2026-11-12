// ATDrive's unlock page: asks a passkey for the secret that unlocks your drive, and hands it
// back to the app on this device. See Sources/ATDriveCore/DriveUnlock.swift for the whole story.
//
// The app opens this page with everything in the URL's fragment (which browsers never send to
// the server): v=1, mode (create | unlock), did, handle, pk (the app's one-time P-256 public key),
// state, return (the app's address on 127.0.0.1) and, to unlock, creds (the drive's passkeys).
//
// The passkey's PRF output is sealed to the app's one-time key before it goes anywhere, so it
// can't be read from the browser's history or a pasted address. The page makes no network
// requests of its own (its Content-Security-Policy forbids them).

/** What the PRF is evaluated on. Never change it: it's what makes each passkey's secret. */
export async function prfSalt(did) {
  return sha256(utf8(`atdrive drive key v1\n${did}`));
}

/**
 * Seals `{credentialID, prf}` to the app's public key: ECDH (P-256) with a fresh key, then
 * HKDF-SHA256 (salt: both public keys, info "atdrive unlock v1") and AES-256-GCM, bound to
 * `state`. Returns base64url of [our public key 65][nonce 12][ciphertext and tag].
 */
export async function seal(appPublicKey, state, credentialID, prf) {
  const theirs = await crypto.subtle.importKey('raw', appPublicKey, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ours = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const ourPublic = new Uint8Array(await crypto.subtle.exportKey('raw', ours.publicKey));
  const shared = await crypto.subtle.deriveBits({ name: 'ECDH', public: theirs }, ours.privateKey, 256);
  const hkdf = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
  const key = await crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: concat(ourPublic, appPublicKey), info: utf8('atdrive unlock v1') },
    hkdf, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = utf8(JSON.stringify({ credentialID, prf: base64url(prf) }));
  const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: utf8(state) }, key, plaintext);
  return base64url(concat(ourPublic, nonce, new Uint8Array(sealed)));
}

/** Reads and checks the fragment. Throws if anything's missing or odd. */
export function parseRequest(fragment) {
  const params = new URLSearchParams(fragment.replace(/^#/, ''));
  const get = (name) => {
    const value = params.get(name);
    if (!value) throw new Error(`This link is incomplete (no ${name}). Start again from ATDrive.`);
    return value;
  };
  if (get('v') !== '1') throw new Error('This link is from a newer version of ATDrive.');
  const mode = get('mode');
  if (mode !== 'create' && mode !== 'unlock') throw new Error('This link is damaged. Start again from ATDrive.');
  const did = get('did');
  if (!did.startsWith('did:')) throw new Error('This link is damaged. Start again from ATDrive.');
  const publicKey = fromBase64url(get('pk'));
  if (publicKey.length !== 65 || publicKey[0] !== 4) throw new Error('This link is damaged. Start again from ATDrive.');
  // Only ever hand the secret back to an app on this device (or, from another device, to an
  // address the user copies by hand).
  const back = get('return');
  if (!/^http:\/\/(127\.0\.0\.1|localhost|\[::1\]):\d+\/[\w/-]*$/.test(back)) {
    throw new Error('This link sends you somewhere other than ATDrive. Start again from ATDrive.');
  }
  const creds = mode === 'unlock' ? get('creds').split(',').filter(Boolean) : [];
  return { mode, did, handle: get('handle'), publicKey, state: get('state'), back, creds };
}

/** Runs the passkey ceremony and returns {credentialID (base64url), prf (bytes)}. */
export async function usePasskey(request) {
  const salt = await prfSalt(request.did);
  const extensions = { prf: { eval: { first: salt } } };
  let allow = request.creds.map((id) => fromBase64url(id));
  if (request.mode === 'create') {
    const credential = await navigator.credentials.create({
      publicKey: {
        rp: { name: 'ATDrive' }, // its ID is this page's host name
        user: { id: await sha256(utf8(request.did)), name: request.handle, displayName: `@${request.handle}` },
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
        authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required' },
        extensions,
      },
    });
    const prf = credential.getClientExtensionResults().prf;
    if (prf?.results?.first) {
      return { credentialID: base64url(new Uint8Array(credential.rawId)), prf: new Uint8Array(prf.results.first) };
    }
    if (prf?.enabled === false) throw new NoPRF();
    // Some passkey providers only evaluate the PRF when signing in, not when creating.
    allow = [new Uint8Array(credential.rawId)];
  }
  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      allowCredentials: allow.map((id) => ({ type: 'public-key', id })),
      userVerification: 'required',
      extensions,
    },
  });
  const prf = assertion.getClientExtensionResults().prf?.results?.first;
  if (!prf) throw new NoPRF();
  return { credentialID: base64url(new Uint8Array(assertion.rawId)), prf: new Uint8Array(prf) };
}

export class NoPRF extends Error {
  constructor() {
    super(
      "This passkey can't unlock ATDrive (it doesn't support the PRF extension). Try again and " +
        'save it in iCloud Keychain, Google Password Manager or 1Password, or on your phone.');
  }
}

// MARK: The page

async function main() {
  const $ = (id) => document.getElementById(id);
  const show = (id) => {
    for (const panel of document.querySelectorAll('[data-panel]')) panel.hidden = panel.id !== id;
  };
  let request;
  try {
    request = parseRequest(location.hash);
  } catch (error) {
    $('problem').textContent = error.message;
    show('broken');
    return;
  }
  // Keep the request out of the address bar and history from here on.
  history.replaceState(null, '', location.pathname);

  const creating = request.mode === 'create';
  $('title').textContent = creating ? 'Create a passkey for your drive' : 'Unlock your drive';
  $('account').textContent = `@${request.handle}`;
  $('explain-create').hidden = !creating;
  $('explain-unlock').hidden = creating;
  show('ask');

  $('go').addEventListener('click', async () => {
    $('go').disabled = true;
    $('error').hidden = true;
    try {
      const { credentialID, prf } = await usePasskey(request);
      const result = await seal(request.publicKey, request.state, credentialID, prf);
      show('done');
      location.replace(`${request.back}?state=${encodeURIComponent(request.state)}&result=${result}`);
    } catch (error) {
      $('error').textContent =
        error.name === 'NotAllowedError'
          ? 'The passkey prompt was closed or timed out. Try again when you’re ready.'
          : error.message;
      $('error').hidden = false;
      $('go').disabled = false;
    }
  });
  $('cancel').addEventListener('click', () => {
    location.replace(`${request.back}?state=${encodeURIComponent(request.state)}&error=cancelled+in+the+browser`);
  });
}

if (typeof document !== 'undefined') main();

// MARK: Bytes

function utf8(text) {
  return new TextEncoder().encode(text);
}

async function sha256(bytes) {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function base64url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64url(text) {
  const base64 = text.replace(/-/g, '+').replace(/_/g, '/');
  const binary = atob(base64 + '='.repeat((4 - (base64.length % 4)) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
