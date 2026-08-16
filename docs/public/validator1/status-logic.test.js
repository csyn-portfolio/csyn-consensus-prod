"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  freshness,
  classifyHealth,
  stateTone,
  agreementDelta,
  agreementYDomain,
} = require("./status-logic.js");

function base(over) {
  return Object.assign(
    {
      proposing: true,
      server_state: "proposing",
      metrics_fresh: true,
      sample_age_seconds: 20,
      fresh_threshold_seconds: 120,
      amendment_blocked: false,
      unl_active: true,
      agreement: { agreement_1h: { pct: 99.9 } },
    },
    over || {}
  );
}

test("classifyHealth: proposing + fresh + clear + UNL + ≥98% is Healthy", () => {
  const h = classifyHealth(base());
  assert.equal(h.level, "healthy");
  assert.equal(h.label, "Healthy");
});

test("classifyHealth: amendment blocked is Attention", () => {
  const h = classifyHealth(base({ amendment_blocked: true }));
  assert.equal(h.level, "attention");
  assert.equal(h.label, "Attention");
});

test("classifyHealth: UNL inactive is Attention", () => {
  const h = classifyHealth(base({ unl_active: false }));
  assert.equal(h.level, "attention");
});

test("classifyHealth: stale and not proposing is Attention", () => {
  const h = classifyHealth(
    base({
      proposing: false,
      server_state: "connected",
      metrics_fresh: false,
      sample_age_seconds: 400,
    })
  );
  assert.equal(h.level, "attention");
});

test("classifyHealth: connected but fresh is Degraded", () => {
  const h = classifyHealth(
    base({ proposing: false, server_state: "connected", metrics_fresh: true })
  );
  assert.equal(h.level, "degraded");
  assert.equal(h.label, "Degraded");
});

test("classifyHealth: 1h agreement under 98 is Degraded", () => {
  const h = classifyHealth(base({ agreement: { agreement_1h: { pct: 97.4 } } }));
  assert.equal(h.level, "degraded");
});

test("classifyHealth: missing status is Attention", () => {
  const h = classifyHealth(null);
  assert.equal(h.level, "attention");
});

test("classifyHealth: baked metrics_fresh is ignored when sample_time is stale", () => {
  const now = Date.parse("2026-08-16T16:40:00Z");
  const h = classifyHealth(
    base({
      metrics_fresh: true,
      sample_age_seconds: 20,
      sample_time: "2026-08-16T10:40:00Z",
      published_at: "2026-08-16T10:40:10Z",
    }),
    now
  );
  assert.notEqual(h.level, "healthy");
});

test("classifyHealth: published_at older than 15m is Attention", () => {
  const now = Date.parse("2026-08-16T16:40:00Z");
  const h = classifyHealth(
    base({
      metrics_fresh: true,
      sample_time: "2026-08-16T16:39:50Z",
      published_at: "2026-08-16T16:20:00Z",
    }),
    now
  );
  assert.equal(h.level, "attention");
});

test("freshness and classifyHealth agree on a future sample_time", () => {
  const now = Date.parse("2026-08-16T16:40:00Z");
  const st = base({
    sample_time: "2026-08-16T16:45:00Z",
    published_at: "2026-08-16T16:39:50Z",
  });
  const fr = freshness(st, now);
  assert.equal(fr.fresh, true);
  assert.equal(fr.sampleAge, 0);
  assert.equal(classifyHealth(st, now).level, "healthy");
});

test("classifyHealth: sample_time a few seconds in the future still Healthy", () => {
  const now = Date.parse("2026-08-16T16:40:00Z");
  const h = classifyHealth(
    base({
      sample_time: "2026-08-16T16:40:05Z",
      published_at: "2026-08-16T16:39:50Z",
    }),
    now
  );
  assert.equal(h.level, "healthy");
});

test("classifyHealth: missing UNL or amendment gauges is Degraded not Healthy", () => {
  assert.equal(classifyHealth(base({ unl_active: null })).level, "degraded");
  assert.equal(classifyHealth(base({ amendment_blocked: null })).level, "degraded");
});

test("stateTone: proposing is ok, connected is warn, blocked/unknown is bad", () => {
  assert.equal(stateTone(base()), "ok");
  assert.equal(stateTone(base({ proposing: false, server_state: "connected" })), "warn");
  assert.equal(stateTone(base({ amendment_blocked: true })), "bad");
  assert.equal(stateTone(base({ proposing: false, server_state: "unknown" })), "bad");
});

test("agreementDelta: up / down / flat / first sample", () => {
  const up = agreementDelta(99.9, 99.7);
  assert.equal(up.dir, "up");
  assert.equal(up.text, "+0.20");
  const down = agreementDelta(99.4, 99.7);
  assert.equal(down.dir, "down");
  assert.equal(down.text, "−0.30");
  const flat = agreementDelta(100, 100);
  assert.equal(flat.dir, "flat");
  assert.equal(flat.text, "0.00");
  assert.equal(agreementDelta(99.9, null), null);
});

test("agreementYDomain: stays 95–100 when healthy; opens to include 90 and data when it drops", () => {
  const tight = agreementYDomain([99.6, 99.8, 100]);
  assert.deepEqual(tight, { min: 95, max: 100 });
  const open = agreementYDomain([88.2, 96, 99]);
  assert.ok(open.min <= 88.2);
  assert.ok(open.min <= 90);
  assert.equal(open.max, 100);
});
