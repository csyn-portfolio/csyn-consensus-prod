"use strict";

/**
 * Pure helpers for the validator1 public status page.
 * Loaded as a classic script in the browser (window.CsynStatus) and required by node:test.
 */
(function (root) {
  function _a1h(status) {
    var ag = status && status.agreement;
    var win = ag && ag.agreement_1h;
    if (!win || win.pct == null) return null;
    var n = Number(win.pct);
    return isNaN(n) ? null : n;
  }

  var STALE_PUBLISH_SECONDS = 900; // 3× 5m publisher interval

  function _parseMs(t) {
    if (!t || typeof t !== "string") return null;
    var ms = Date.parse(t);
    return isNaN(ms) ? null : ms;
  }

  function classifyHealth(status, nowMs) {
    if (!status) {
      return { level: "attention", label: "Attention" };
    }
    var now = nowMs != null ? nowMs : Date.now();
    var blocked = status.amendment_blocked === true;
    var unlDown = status.unl_active === false;
    var proposing = status.proposing === true;
    var thr = status.fresh_threshold_seconds || 120;
    var sampleMs = _parseMs(status.sample_time);
    var pubMs = _parseMs(status.published_at);
    var sampleAge =
      sampleMs != null
        ? (now - sampleMs) / 1000
        : status.sample_age_seconds;
    // Browser clock a few seconds behind the publisher must not flip Healthy → Degraded.
    if (sampleAge != null && sampleAge < 0 && sampleAge >= -60) sampleAge = 0;
    var pubAge = pubMs != null ? (now - pubMs) / 1000 : null;
    var fresh =
      sampleAge != null && sampleAge >= 0 && sampleAge <= thr;
    var publishStale = pubAge != null && pubAge > STALE_PUBLISH_SECONDS;
    if (blocked || unlDown || publishStale || (!proposing && !fresh)) {
      return { level: "attention", label: "Attention" };
    }
    var gaugesKnown =
      status.amendment_blocked === false && status.unl_active === true;
    var a1 = _a1h(status);
    if (!proposing || !fresh || !gaugesKnown || a1 == null || a1 < 98) {
      return { level: "degraded", label: "Degraded" };
    }
    return { level: "healthy", label: "Healthy" };
  }

  function stateTone(status) {
    if (!status) return "bad";
    if (status.amendment_blocked === true) return "bad";
    if (status.proposing === true || status.server_state === "proposing") return "ok";
    if (status.server_state === "connected") return "warn";
    return "bad";
  }

  function agreementDelta(currentPct, previousPct) {
    if (currentPct == null || previousPct == null) return null;
    var cur = Number(currentPct);
    var prev = Number(previousPct);
    if (isNaN(cur) || isNaN(prev)) return null;
    var d = cur - prev;
    var dir = d > 0.005 ? "up" : d < -0.005 ? "down" : "flat";
    var abs = Math.abs(d).toFixed(2);
    var text = dir === "up" ? "+" + abs : dir === "down" ? "−" + abs : "0.00";
    return { dir: dir, text: text };
  }

  function agreementYDomain(values) {
    var nums = (values || []).map(Number).filter(function (n) {
      return !isNaN(n);
    });
    if (!nums.length) return { min: 95, max: 100 };
    var dataMin = Math.min.apply(null, nums);
    if (dataMin >= 95) return { min: 95, max: 100 };
    var min = Math.min(90, Math.floor(dataMin - 1));
    if (min < 0) min = 0;
    return { min: min, max: 100 };
  }

  var api = {
    classifyHealth: classifyHealth,
    stateTone: stateTone,
    agreementDelta: agreementDelta,
    agreementYDomain: agreementYDomain,
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  } else {
    root.CsynStatus = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
