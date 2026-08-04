#!/usr/bin/env node
// Does the NETWORK see our validator?
//
// Subscribes to the `validations` stream on a public rippled node that has no
// peering relationship with us, and counts how many ledgers carry a validation
// signed by our key. This is the authoritative external check: a validation
// observed at an unaffiliated node proves our validation left the box AND was
// relayed across the overlay.
//
// Why not a registry (xrpscan / VHS / livenet): registry presence and their
// `last_seen` / agreement fields are lagging, non-authoritative indicators that
// centre on published-UNL validators. A non-UNL validator can be fully healthy
// and validating while a registry shows it stale or omits it entirely. Do not
// gate operational decisions on them.
//
// IMPORTANT: the stream message type is `validationReceived`, NOT `validation`.
// Filtering on `validation` silently yields zero and reads as "we are invisible".
// That mistake is why this script exists as a committed tool rather than an
// ad-hoc one-liner: the false-negative is indistinguishable from a real outage.
//
// If the stream carries no validations at all, the run is INCONCLUSIVE (exit 2),
// never "not seen" — an endpoint that accepts the subscribe but delivers nothing
// tells you about the endpoint, not about the validator.
//
// Usage:
//   node tools/network-sees-validator.mjs [--seconds 80] [--url wss://xrplcluster.com]
// Exit codes: 0 = seen, 1 = NOT seen, 2 = inconclusive (stream carried nothing)

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};

// Our mainnet validator identity. MASTER is stable across token rotations;
// EPHEMERAL is the current signing key and changes when a new token is minted
// (the stream reports the signing key in `validation_public_key`).
//
// BOTH VALUES ARE PUBLIC. They are the validator's public keys: the master key
// is already committed in this repo (dashboard.tf, validator-recreate.md), and
// the signing key is published in our manifest, served by xrpscan, and broadcast
// in every validation we sign. The secrets are the `[validator_token]` and the
// master secret key — Secret Manager and the HSM respectively, never here.
// gitleaks flags the signing key as generic-api-key purely on entropy.
const MASTER = 'nHUQEd51hNxF3vdVHJKewxZUzXqiP78agDL2bVSiA7Ja4dRFZUGq';
const EPHEMERAL = opt('signing-key', 'n9Lx3VU74ghkm29Gg5ay3xzynDhpUqaH8BLMFYc3MBrWT8pxKWk4'); // gitleaks:allow — public validator signing key

const url = opt('url', 'wss://xrplcluster.com');
const seconds = parseInt(opt('seconds', '80'), 10);

let total = 0;
let ours = 0;
const ourLedgers = new Set();
const allLedgers = new Set();
const validators = new Set();

const ws = new WebSocket(url);
ws.onopen = () => ws.send(JSON.stringify({ id: 1, command: 'subscribe', streams: ['validations'] }));
ws.onerror = (e) => {
  console.error(`WS error against ${url}: ${e.message || e}`);
  process.exit(2);
};
ws.onmessage = (e) => {
  let m;
  try { m = JSON.parse(e.data); } catch { return; }
  if (m.type !== 'validationReceived') return;
  total++;
  if (m.ledger_index) allLedgers.add(Number(m.ledger_index));
  const signing = m.validation_public_key || '';
  const master = m.master_key || '';
  validators.add(master || signing);
  if (signing === EPHEMERAL || signing === MASTER || master === MASTER) {
    ours++;
    if (m.ledger_index) ourLedgers.add(Number(m.ledger_index));
  }
};

setTimeout(() => {
  console.log(`endpoint            : ${url}`);
  console.log(`window              : ${seconds}s`);
  console.log(`validations observed: ${total}`);
  console.log(`distinct validators : ${validators.size}`);
  console.log(`ledgers in window   : ${allLedgers.size}`);
  console.log(`OUR validations     : ${ours} (on ${ourLedgers.size} ledgers)`);

  if (total === 0) {
    console.log('\nINCONCLUSIVE: the stream carried no validations at all.');
    console.log('That is an endpoint/subscribe problem, not a validator problem.');
    console.log('Re-run, or try another endpoint, before drawing any conclusion.');
    process.exit(2);
  }
  // We are a non-UNL (untrusted) validator. A relaying node may carry only
  // TRUSTED validations in a given window — rippled drops untrusted validations
  // under load, and `[relay_validations]` can be set to trusted-only. When that
  // happens the observed validator set collapses to roughly the dUNL (~35), and
  // our absence says nothing about us. Observed live 2026-08-04: consecutive
  // runs against the same endpoint returned 112, 109, then 35 distinct
  // validators, with ours present in the first two and absent in the third.
  // Treating that third window as an outage would be a false page.
  const UNL_ONLY_CEILING = 45;
  if (ours === 0 && validators.size <= UNL_ONLY_CEILING) {
    console.log(`\nINCONCLUSIVE: only ${validators.size} distinct validators seen (~dUNL size).`);
    console.log('This endpoint was not relaying UNTRUSTED validations in this window,');
    console.log('so our absence is not evidence. Re-run, and/or use a longer --seconds.');
    process.exit(2);
  }
  if (ours === 0) {
    console.log(`\nNOT SEEN: endpoint carried untrusted validations (${validators.size} validators),`);
    console.log('but none of ours — this absence IS meaningful.');
    console.log('Check on-box: server_state must be `proposing` and');
    console.log('`pubkey_validator` must equal our master key (see validator-recreate.md).');
    console.log('If --signing-key is stale after a token rotation, pass the current one.');
    process.exit(1);
  }
  // Health measure = did we validate about one ledger per close, in an unbroken
  // run. Do NOT divide by `allLedgers`: that denominator counts every index any
  // validator reported in the window (validators sit at slightly different
  // indices), so it runs well ahead of the closes that actually happened and
  // makes full participation look like ~30%.
  const seq = [...ourLedgers].sort((a, b) => a - b);
  let best = seq.length ? 1 : 0;
  let run = best;
  for (let i = 1; i < seq.length; i++) {
    run = seq[i] === seq[i - 1] + 1 ? run + 1 : 1;
    if (run > best) best = run;
  }
  const expectedCloses = Math.floor(seconds / 4); // XRPL targets ~3-4s per ledger
  console.log(`expected closes     : ~${expectedCloses} (window / ~4s)`);
  console.log(`longest unbroken run: ${best} ledgers`);
  console.log('\nSEEN: our validations reached an unaffiliated public node.');
  if (ourLedgers.size < expectedCloses * 0.8) {
    console.log('NOTE: fewer validations than closes in this window — participation may be');
    console.log('intermittent. Re-run with a longer --seconds before concluding anything.');
  }
  process.exit(0);
}, seconds * 1000);
