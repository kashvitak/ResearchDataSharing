import { useEffect, useState } from 'react';
import { api, setToken } from './api.js';
import { createIdentity, getKey, hasKey, importKey, sign } from './crypto.js';

const saveBlob = (blob, name) => {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
};

const download = (text, name) => saveBlob(new Blob([text], { type: 'text/plain' }), name);

export default function App() {
  const [me, setMe] = useState(null);
  const [tab, setTab] = useState('assets');
  const [msg, setMsg] = useState(null);

  const notify = (type, text) => setMsg({ type, text });
  // run(): call the API, show errors in the banner, never throw
  const run = async (fn, okText) => {
    try {
      const r = await fn();
      if (okText) notify('ok', okText);
      return r;
    } catch (e) {
      notify('err', e.message);
      return undefined;
    }
  };
  const ui = { run, notify };

  useEffect(() => {
    if (localStorage.getItem('token')) api.me().then(setMe).catch(() => setToken(''));
  }, []);

  const logout = async () => {
    await run(api.logout);
    setToken('');
    setMe(null);
    setMsg(null);
  };

  const banner = msg && <div className={'banner ' + msg.type}>{msg.text}</div>;

  if (!me) return <main>{banner}<Login ui={ui} onLogin={setMe} /></main>;

  const role = me.member?.role;
  const canUpload = ['ORG_ADMIN', 'PROJECT_LEAD', 'RESEARCHER'].includes(role);
  const isAdmin = !me.member || me.governance || role === 'ORG_ADMIN';

  return (
    <>
      <header>
        <div>
          <b>Research IP Platform</b>
          <br />
          <small>
            {me.did} · {me.member ? `${me.member.org} / ${me.member.dept} / ${me.member.role}` : 'no role yet'}
            {me.governance && ' · GOVERNANCE'}
          </small>
        </div>
        <button className="secondary" onClick={logout}>Log out</button>
      </header>
      <main>
        {banner}
        {!me.member && !me.governance && (
          <div className="banner err">
            You are logged in but have no role. Ask your organisation admin to assign one to <code>{me.did}</code>.
          </div>
        )}
        <div className="tabs card">
          <button onClick={() => setTab('assets')}>Assets</button>
          {canUpload && <button onClick={() => setTab('upload')}>Upload</button>}
          {isAdmin && <button onClick={() => setTab('admin')}>Admin</button>}
        </div>
        {tab === 'assets' && <Assets ui={ui} />}
        {tab === 'upload' && <Upload ui={ui} onDone={() => setTab('assets')} />}
        {tab === 'admin' && <Admin ui={ui} me={me} />}
      </main>
    </>
  );
}

/* ------------------------------------------------------------------ login */

function Login({ ui, onLogin }) {
  const [did, setDid] = useState('did:fabric:snu:alice');
  const [backup, setBackup] = useState('');
  const org = did.split(':')[2] || '';

  const register = async () => {
    const r = await ui.run(async () => {
      const id = await createIdentity(did);
      await api.register(did, id.publicKey, org);
      return id;
    });
    if (r) {
      download(r.privateKey, `${did.replaceAll(':', '_')}.key.txt`);
      ui.notify('ok', 'DID registered on Fabric. Your private key backup was downloaded - keep it safe. You can log in now.');
    }
  };

  const login = async () => {
    const r = await ui.run(async () => {
      const { challenge } = await api.challenge(did);
      const signature = await sign(did, challenge); // signed locally with the private key
      const { token } = await api.login(did, challenge, signature);
      setToken(token);
      return api.me();
    });
    if (r) onLogin(r);
  };

  return (
    <div className="card">
      <h3>Sign in with your DID</h3>
      <p>
        Format: <code>did:fabric:&lt;organisation&gt;:&lt;name&gt;</code>. The private key stays in this browser; only the
        public key is stored on Fabric.
      </p>
      <input size={40} value={did} onChange={(e) => setDid(e.target.value.trim())} />
      <div className="row-actions">
        <button onClick={login}>Log in</button>{' '}
        <button className="secondary" onClick={register}>Register new DID</button>
      </div>
      {!hasKey(did) && (
        <details>
          <summary>Already registered on another browser? Import your key backup</summary>
          <input size={60} placeholder="paste private key backup" value={backup} onChange={(e) => setBackup(e.target.value)} />
          <button className="secondary" onClick={() => { importKey(did, backup); setBackup(''); ui.notify('ok', 'Key imported'); }}>
            Import
          </button>
        </details>
      )}
      {hasKey(did) && (
        <button className="secondary" onClick={() => download(getKey(did), 'key-backup.txt')}>Download key backup</button>
      )}
    </div>
  );
}

/* ----------------------------------------------------------------- assets */

function Assets({ ui }) {
  const [assets, setAssets] = useState([]);
  const [selected, setSelected] = useState(null);
  const refresh = async () => setAssets((await ui.run(api.list)) || []);
  useEffect(() => { refresh(); }, []);

  return (
    <>
      <div className="card">
        <h3>Assets you can access</h3>
        <table>
          <thead>
            <tr><th>ID</th><th>Name</th><th>Owner</th><th>Dept</th><th>Class</th><th>Ver</th><th>Status</th></tr>
          </thead>
          <tbody>
            {assets.map((a) => (
              <tr key={a.assetId} className="row" onClick={() => setSelected(a.assetId)}>
                <td>{a.assetId}</td><td>{a.name}</td><td>{a.ownerDid}</td>
                <td>{a.org}/{a.dept}</td><td>{a.classification}</td><td>v{a.version}</td>
                <td><span className={'tag' + (a.status !== 'ACTIVE' ? ' warn' : '')}>{a.status}</span></td>
              </tr>
            ))}
            {assets.length === 0 && <tr><td colSpan={7}>Nothing here yet.</td></tr>}
          </tbody>
        </table>
        <div className="row-actions"><button className="secondary" onClick={refresh}>Refresh</button></div>
      </div>
      {selected && <AssetDetail key={selected} id={selected} ui={ui} onChange={refresh} />}
    </>
  );
}

function AssetDetail({ id, ui, onChange }) {
  const { run, notify } = ui;
  const [asset, setAsset] = useState(null);
  const [history, setHistory] = useState([]);
  const [proposal, setProposal] = useState(null);
  const [who, setWho] = useState('');
  const [file, setFile] = useState(null);
  const [verifyRes, setVerifyRes] = useState(null);

  const load = async () => {
    const a = await run(() => api.get(id));
    if (!a) return;
    setAsset(a);
    setHistory((await run(() => api.history(id))) || []);
    setProposal(null);
    if (a.status === 'PENDING_UPDATE') {
      try { setProposal(await api.proposal(id)); } catch { /* only department approvers may see it */ }
    }
  };
  useEffect(() => { load(); }, [id]);

  const act = async (fn, okText) => {
    const r = await run(fn, okText);
    if (r !== undefined) { await load(); onChange(); }
  };

  const getFile = async (pending) => {
    const r = await run(() => api.download(id, pending));
    if (!r) return;
    saveBlob(r.blob, (pending ? 'proposed-' : '') + asset.name);
    if (r.integrity === 'VALID') notify('ok', 'Downloaded. Integrity VALID: the file matches the hash registered on Fabric.');
    else notify('err', 'WARNING: integrity COMPROMISED - the file does NOT match the hash registered on Fabric.');
  };

  if (!asset) return null;
  const pending = asset.status === 'PENDING_UPDATE';

  return (
    <div className="card">
      <h3>{asset.assetId} · {asset.name}</h3>
      <p>
        Owner <code>{asset.ownerDid}</code> · {asset.org}/{asset.dept} · {asset.classification} · version {asset.version} ·{' '}
        <span className={'tag' + (pending ? ' warn' : '')}>{asset.status}</span>
        <br />IPFS CID <code>{asset.cid}</code>
        <br />SHA-256 <code>{asset.hash}</code>
      </p>
      <div className="row-actions"><button onClick={() => getFile(false)}>Download (decrypt + verify)</button></div>

      <h3>Verify a file you already have</h3>
      <input type="file" onChange={(e) => { setFile(e.target.files[0]); setVerifyRes(null); }} />
      <button className="secondary" disabled={!file}
        onClick={async () => setVerifyRes(await run(() => api.verify(id, file)))}>Check against Fabric</button>
      {verifyRes && (
        <div className={'banner ' + (verifyRes.valid ? 'ok' : 'err')}>
          {verifyRes.valid ? 'VALID - identical to the registered version' : 'COMPROMISED / different from the registered version'}
        </div>
      )}

      <h3>Change this asset (needs department approval)</h3>
      {!pending && (
        <>
          <input type="file" onChange={(e) => setFile(e.target.files[0])} />
          <button disabled={!file}
            onClick={() => act(() => api.propose(id, { file, expectedVersion: asset.version }), 'Proposal created. The asset is locked until the department votes.')}>
            Propose new version
          </button>
        </>
      )}
      {pending && !proposal && <p>An update is being voted on. You can still download the last approved version.</p>}
      {pending && proposal && (
        <div>
          <p>
            Proposal #{proposal.nonce} by <code>{proposal.proposerDid}</code> · approvals {proposal.approvals.length}/{proposal.required} ·
            deadline {proposal.deadline}
          </p>
          <button className="secondary" onClick={() => getFile(true)}>Download proposed file to review</button>{' '}
          <button onClick={() => act(() => api.approve(id, proposal.nonce), 'Approved')}>Approve</button>{' '}
          <button className="danger" onClick={() => act(() => api.reject(id, proposal.nonce, 'rejected in UI'), 'Rejected')}>Reject</button>{' '}
          <button className="secondary" onClick={() => act(() => api.expire(id), 'Lock released')}>Release expired lock</button>
        </div>
      )}

      <h3>Share / transfer</h3>
      <input size={34} placeholder="did:fabric:iitd:carol" value={who} onChange={(e) => setWho(e.target.value.trim())} />
      <button className="secondary" disabled={!who} onClick={() => act(() => api.grant(id, who), 'Read access granted')}>Grant read access</button>{' '}
      <button className="secondary" disabled={!who}
        onClick={() => act(() => api.transfer(id, who, asset.version), 'Ownership transferred')}>Transfer ownership</button>

      <h3>Provenance / audit history</h3>
      <table>
        <thead><tr><th>Time</th><th>Action</th><th>By</th><th>Ver</th></tr></thead>
        <tbody>
          {history.map((h) => (
            <tr key={h.txId}><td>{h.timestamp}</td><td>{h.action}</td><td>{h.actorDid}</td><td>{h.version}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* ----------------------------------------------------------------- upload */

function Upload({ ui, onDone }) {
  const [assetId, setAssetId] = useState('');
  const [name, setName] = useState('');
  const [classification, setClassification] = useState('INTERNAL');
  const [file, setFile] = useState(null);

  const submit = async () => {
    const r = await ui.run(() => api.upload({ assetId, name, classification, file }), 'Asset encrypted, stored on IPFS and registered on Fabric.');
    if (r) onDone();
  };

  return (
    <div className="card">
      <h3>Register a research asset</h3>
      <input placeholder="asset id e.g. DS-001" value={assetId} onChange={(e) => setAssetId(e.target.value.trim())} />
      <input placeholder="name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
      <select value={classification} onChange={(e) => setClassification(e.target.value)}>
        <option>PUBLIC</option><option>INTERNAL</option><option>CONFIDENTIAL</option>
      </select>
      <input type="file" onChange={(e) => setFile(e.target.files[0])} />
      <div className="row-actions"><button disabled={!assetId || !file} onClick={submit}>Encrypt, store and register</button></div>
    </div>
  );
}

/* ------------------------------------------------------------------ admin */

function Admin({ ui, me }) {
  const [org, setOrg] = useState('');
  const [adminDid, setAdminDid] = useState('');
  const [target, setTarget] = useState('');
  const [dept, setDept] = useState('CSE');
  const [role, setRole] = useState('RESEARCHER');

  return (
    <>
      {me.governance || !me.member ? (
        <div className="card">
          <h3>Network governance</h3>
          <p>Run once, right after deployment: the DID you are logged in as becomes the network governance.</p>
          <button onClick={() => ui.run(api.init, 'This DID is now the network governance. Log out and in again.')}>Make me governance</button>
          <h3>Add an organisation</h3>
          <input placeholder="org e.g. snu" value={org} onChange={(e) => setOrg(e.target.value.trim())} />
          <input size={30} placeholder="admin DID e.g. did:fabric:snu:admin" value={adminDid} onChange={(e) => setAdminDid(e.target.value.trim())} />
          <button onClick={() => ui.run(() => api.addOrg(org, adminDid), 'Organisation added')}>Add organisation</button>
        </div>
      ) : null}
      {me.member?.role === 'ORG_ADMIN' && (
        <div className="card">
          <h3>Manage roles in {me.member.org}</h3>
          <input size={30} placeholder="user DID" value={target} onChange={(e) => setTarget(e.target.value.trim())} />
          <input placeholder="department" value={dept} onChange={(e) => setDept(e.target.value.trim())} />
          <select value={role} onChange={(e) => setRole(e.target.value)}>
            <option>PROJECT_LEAD</option><option>RESEARCHER</option><option>COLLABORATOR</option><option>AUDITOR</option>
          </select>
          <div className="row-actions">
            <button disabled={!target} onClick={() => ui.run(() => api.assign(target, dept, role), 'Role assigned')}>Assign role</button>{' '}
            <button className="danger" disabled={!target} onClick={() => ui.run(() => api.remove(target), 'Role removed')}>Remove role</button>
          </div>
        </div>
      )}
    </>
  );
}
