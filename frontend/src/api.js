let token = localStorage.getItem('token') || '';
export const setToken = (t) => {
  token = t || '';
  if (t) localStorage.setItem('token', t);
  else localStorage.removeItem('token');
};

async function request(path, opts = {}) {
  const headers = { ...(opts.headers || {}) };
  if (token) headers.Authorization = 'Bearer ' + token;
  const res = await fetch('/api' + path, { ...opts, headers });
  if (!res.ok) {
    let msg = res.statusText || `HTTP ${res.status}`;
    try { msg = (await res.json()).error || msg; } catch { /* not json */ }
    throw new Error(msg);
  }
  return res;
}
const json = async (path, opts) => (await request(path, opts)).json();
const post = (path, body) =>
  json(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
const form = (path, fields) => {
  const f = new FormData();
  Object.entries(fields).forEach(([k, v]) => f.append(k, v));
  return json(path, { method: 'POST', body: f });
};
const q = encodeURIComponent;

export const api = {
  // auth
  register: (did, publicKey, org) => post('/auth/register', { did, publicKey, org }),
  challenge: (did) => post('/auth/challenge', { did }),
  login: (did, challenge, signature) => post('/auth/login', { did, challenge, signature }),
  logout: () => post('/logout'),
  me: () => json('/me'),
  // admin
  init: () => post('/admin/init'),
  addOrg: (org, adminDid) => post('/admin/organizations', { org, adminDid }),
  assign: (did, dept, role) => post('/admin/roles', { did, dept, role }),
  remove: (did) => json('/admin/roles?did=' + q(did), { method: 'DELETE' }),
  // assets
  list: () => json('/assets'),
  get: (id) => json('/assets/' + q(id)),
  history: (id) => json(`/assets/${q(id)}/history`),
  proposal: (id) => json(`/assets/${q(id)}/proposal`),
  upload: (fields) => form('/assets', fields),
  propose: (id, fields) => form(`/assets/${q(id)}/propose`, fields),
  verify: (id, file) => form(`/assets/${q(id)}/verify`, { file }),
  approve: (id, nonce) => post(`/assets/${q(id)}/approve`, { nonce }),
  reject: (id, nonce, reason) => post(`/assets/${q(id)}/reject`, { nonce, reason }),
  expire: (id) => post(`/assets/${q(id)}/expire`),
  grant: (id, did) => post(`/assets/${q(id)}/grant`, { did }),
  transfer: (id, newOwnerDid, expectedVersion) => post(`/assets/${q(id)}/transfer`, { newOwnerDid, expectedVersion }),
  download: async (id, pending = false) => {
    const res = await request(`/assets/${q(id)}/${pending ? 'proposal/' : ''}download`);
    return { blob: await res.blob(), integrity: res.headers.get('X-Integrity') };
  },
};
