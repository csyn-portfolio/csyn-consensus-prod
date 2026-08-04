#!/usr/bin/env node
// Does the NETWORK see our validator?
//
// Subscribes to the `validations` stream on SEVERAL independent public rippled
// nodes and counts how many ledger closes carry a validation signed by our key.
// A validation observed at a node with no peering relationship to us proves ours
// left the box AND crossed the overlay on at least that path.
//
// MULTI-ENDPOINT BY DESIGN. One endpoint proves one path exists, not that the
// mesh carries us. The verdict below requires agreement across >= 2 independent
// operators, because a low-centrality validator can be visible on a lucky path
// while under-propagating overall.
//
// Why not a registry (xrpscan / VHS / livenet): they are lagging and can fail as
// a class. OBSERVED 2026-08-04: all 108 domain-verified non-UNL validators on
// xrpscan were stale, 49 of them frozen within the same few minutes of
// 2026-08-01T22:0xZ across unrelated operators — a registry-side ingest break
// that looked exactly like a 63h outage of our own. Registries are INFORMATIONAL.
// Never gate a recreate, and never open an incident, on registry `last_seen`.
//
// Two footguns this tool exists to prevent, both of which read as a real outage:
//   1. The stream message type is `validationReceived`, NOT `validation`.
//      Filtering on `validation` yields zero at every endpoint.
//   2. A window where the endpoint relays only TRUSTED validations collapses the
//      observed set to roughly the dUNL (~35) and cannot show an untrusted
//      validator at all. That is INCONCLUSIVE, never NOT SEEN.
//
// KEY ROTATION: the stream carries only `validation_public_key` — the EPHEMERAL
// SIGNING key. It does NOT carry `master_key` (verified 2026-08-04), so we cannot
// match on the stable master key. After any `create_token` / manifest rotation the
// default below is stale and this tool would report a false NOT SEEN. Read the
// current value from the node and pass it:
//     xrpld validator_info   ->  .ephemeral_key
//     node tools/network-sees-validator.mjs --signing-key n9...
//
// Usage:
//   node tools/network-sees-validator.mjs [--seconds 70] [--urls a,b,c] [--signing-key n9...]
// Exit codes: 0 = SEEN (>=2 independent feeds) · 1 = NOT SEEN · 2 = INCONCLUSIVE

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

// PUBLIC values — the validator's public keys, not secrets. The master key is
// already committed in this repo (dashboard.tf, validator-recreate.md); the
// signing key is published in our manifest, served by xrpscan, and broadcast in
// every validation we sign. The secrets are the `[validator_token]` (Secret
// Manager) and the master secret key (HSM). gitleaks flags the signing key as
// generic-api-key purely on entropy.
const MASTER = 'nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq';
const DEFAULT_SIGNING = 'n9Lx3VU74ghkm29Gg5ay3xzynDhpUqaH8BLMFYc3MBrWT8pxKWk4'; // gitleaks:allow — public validator signing key
const SIGNING = opt('signing-key', DEFAULT_SIGNING);

const URLS = opt('urls', 'wss://xrplcluster.com,wss://s2.ripple.com,wss://xrpl.ws')
  .split(',').map((s) => s.trim()).filter(Boolean);
const SECONDS = parseInt(opt('seconds', '70'), 10);

// Below this many distinct validators, the endpoint is relaying trusted-only
// (dUNL is 35) and cannot show an untrusted validator. Absence proves nothing.
const UNL_ONLY_CEILING = 45;

// XRPL closes target ~3-4s but stretch under load. Bound the expectation rather
// than assuming a fixed 4s, so a slow window is not misreported as intermittent.
const CLOSE_FAST_S = 3;
const CLOSE_SLOW_S = 5;

function watch(url) {
  return new Promise((resolve) => {
    const seen = { url, total: 0, ours: 0, validators: new Set(), ourLedgers: new Set(), error: null, acked: false };
    let ws, timer, settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws && ws.close(); } catch { /* already closed */ }
      resolve(seen);
    };
    try { ws = new WebSocket(url); } catch (e) { seen.error = String(e.message || e); return finish(); }

    // Hard timeout: covers a half-open TCP that never errors and never delivers.
    timer = setTimeout(finish, SECONDS * 1000);

    ws.onopen = () => ws.send(JSON.stringify({ id: 1, command: 'subscribe', streams: ['validations'] }));
    ws.onerror = (e) => { seen.error = String(e.message || 'websocket error'); finish(); };
    ws.onclose = () => { if (!settled) { seen.error = seen.error || 'closed early'; finish(); } };
    ws.onmessage = (e) => {
      let m;
      try { m = JSON.parse(e.data); } catch { return; }
      if (m.type === 'response' && m.id === 1) {
        seen.acked = m.status === 'success';
        if (!seen.acked) { seen.error = `subscribe rejected: ${JSON.stringify(m.error || m).slice(0, 120)}`; finish(); }
        return;
      }
      if (m.type !== 'validationReceived') return;
      seen.total++;
      const key = m.validation_public_key || '';
      seen.validators.add(key);
      // `master_key` is absent from this stream; keep the comparison anyway so a
      // future endpoint that adds it still matches, but never depend on it.
      if (key === SIGNING || key === MASTER || m.master_key === MASTER) {
        seen.ours++;
        if (m.ledger_index) seen.ourLedgers.add(Number(m.ledger_index));
      }
    };
  });
}

const longestRun = (set) => {
  const seq = [...set].sort((a, b) => a - b);
  let best = seq.length ? 1 : 0, run = best;
  for (let i = 1; i < seq.length; i++) {
    run = seq[i] === seq[i - 1] + 1 ? run + 1 : 1;
    if (run > best) best = run;
  }
  return best;
};

const results = await Promise.all(URLS.map(watch));

let sawUs = 0, couldHaveSeenUs = 0;
for (const r of results) {
  const relaysUntrusted = r.validators.size > UNL_ONLY_CEILING;
  if (r.ours > 0) sawUs++;
  if (relaysUntrusted) couldHaveSeenUs++;
  const note = r.error ? `ERROR: ${r.error}`
    : r.total === 0 ? 'no validations delivered — endpoint problem, not ours'
    : !relaysUntrusted ? `trusted-only window (${r.validators.size} validators) — cannot show us`
    : r.ours > 0 ? `seen on ${r.ourLedgers.size} ledgers, unbroken run ${longestRun(r.ourLedgers)}`
    : 'carried untrusted validations but NOT ours';
  console.log(`${r.url}`);
  console.log(`  validations=${r.total} validators=${r.validators.size} ours=${r.ours} :: ${note}`);
}

const lo = Math.floor(SECONDS / CLOSE_SLOW_S), hi = Math.ceil(SECONDS / CLOSE_FAST_S);
console.log(`\nendpoints: ${URLS.length} | window ${SECONDS}s | expected closes ~${lo}-${hi}`);
if (SIGNING === DEFAULT_SIGNING) {
  console.log('signing key: repo default — if the token was rotated, pass --signing-key from `validator_info`.');
}

if (sawUs >= 2) {
  console.log(`\nSEEN on ${sawUs}/${URLS.length} independent feeds. Mesh propagation confirmed.`);
  process.exit(0);
}
if (sawUs === 1) {
  console.log(`\nINCONCLUSIVE: seen on only 1 feed. One path exists, but that does not`);
  console.log('establish mesh-wide propagation. Re-run; if it stays single-path,');
  console.log('treat it as a real fan-out/topology problem, not a registry issue.');
  process.exit(2);
}
if (couldHaveSeenUs >= 2) {
  console.log(`\nNOT SEEN: ${couldHaveSeenUs} feeds carried untrusted validations and none showed us.`);
  console.log('This absence IS meaningful. Check on-box: `server_state` must be `proposing`');
  console.log('and `pubkey_validator` must equal our master key (see validator-recreate.md).');
  console.log('If the token was rotated, re-run with the current --signing-key first.');
  process.exit(1);
}
console.log('\nINCONCLUSIVE: fewer than 2 feeds were in a state that could have shown us.');
console.log('Re-run, or widen --seconds / --urls. Do NOT read this as an outage.');
process.exit(2);
