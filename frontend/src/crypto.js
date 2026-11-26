// DID keys live in the browser. The PRIVATE key never leaves it; only the public key goes to Fabric.
// (Prototype: the key sits in localStorage. Use "Download key backup" and keep that file safe.)
const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const ALGO = { name: 'ECDSA', namedCurve: 'P-256' };

export async function createIdentity(did) {
  const kp = await crypto.subtle.generateKey(ALGO, true, ['sign', 'verify']);
  const publicKey = b64(await crypto.subtle.exportKey('spki', kp.publicKey));
  const privateKey = b64(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
  return { publicKey, privateKey };
}

export const hasKey = (did) => !!localStorage.getItem('privkey:' + did);
export const getKey = (did) => localStorage.getItem('privkey:' + did);
export const importKey = (did, privateKey) => localStorage.setItem('privkey:' + did, privateKey.trim());

export async function sign(did, message) {
  const priv = getKey(did);
  if (!priv) throw new Error('No private key for this DID in this browser. Import your key backup first.');
  const key = await crypto.subtle.importKey('pkcs8', unb64(priv), ALGO, false, ['sign']);
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(message));
  return b64(sig); // raw r||s, which the Java backend verifies as SHA256withECDSAinP1363Format
}
