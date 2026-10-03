"use strict";

/**
 * Pure helpers for the validator1 public status page.
 * Loaded as a classic script in the browser (window.CsynStatus).
 * Tests: csyn-consensus-prod docs/public/validator1/status-logic.test.js
 */
(function (root) {
  // One hour of XRPL closes is well under this many ledgers. A day or a month is not.
  var HOUR_LEDGER_CEILING = 2000;

  function ledgerCount(value) {
    if (value == null || value === "" || typeof value === "boolean") return null;
    var n = Number(value);
    if (!isFinite(n)) return null;
    return Math.trunc(n);
  }

  function hourWindowFailed(hour) {
    if (!hour) return false;
    var total = ledgerCount(hour.total);
    if (total == null) return false;
    return total <= 0 || total > HOUR_LEDGER_CEILING;
  }

  function agreementWindowUsable(win, horizon, hour) {
    if (!win) return false;
    var total = ledgerCount(win.total);
    if (horizon === "daily") return total != null && total > 0;
    if (total == null) return win.pct != null || win.score != null;
    if (total <= 0) return false;
    if (horizon === "1h" && total > HOUR_LEDGER_CEILING) return false;
    if ((horizon === "24h" || horizon === "30d") && hourWindowFailed(hour)) {
      var missedH = ledgerCount(hour.missed);
      var missedW = ledgerCount(win.missed);
      var totalH = ledgerCount(hour.total);
      if (
        missedH != null &&
        missedW != null &&
        missedH === missedW &&
        totalH === total
      ) {
        return false;
      }
    }
    return true;
  }

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

  function freshness(status, nowMs) {
    var now = nowMs != null ? nowMs : Date.now();
    var thr = (status && status.fresh_threshold_seconds) || 120;
    if (!status) {
      return {
        sampleAge: null,
        pubAge: null,
        fresh: false,
        publishStale: true,
        threshold: thr,
      };
    }
    var sampleMs = _parseMs(status.sample_time);
    var pubMs = _parseMs(status.published_at);
    var pubAge = pubMs != null ? (now - pubMs) / 1000 : null;
    // Sidecar freshness is lag at snapshot (published_at − sample_time), not
    // wall-clock since sample_time. The public file only refreshes every ~5m,
    // so comparing sample_time to now false-Degrades a proposing node.
    var sidecarLag = null;
    if (sampleMs != null && pubMs != null) sidecarLag = (pubMs - sampleMs) / 1000;
    else if (status.sample_age_seconds != null) sidecarLag = status.sample_age_seconds;
    if (sidecarLag != null && sidecarLag < 0) sidecarLag = 0;
    var sampleAge = sidecarLag;
    var fresh = sidecarLag != null && sidecarLag <= thr;
    var publishStale = pubAge != null && pubAge > STALE_PUBLISH_SECONDS;
    return {
      sampleAge: sampleAge,
      pubAge: pubAge,
      fresh: fresh,
      publishStale: publishStale,
      threshold: thr,
    };
  }

  function classifyHealth(status, nowMs) {
    if (!status) {
      return { level: "attention", label: "Attention" };
    }
    var fr = freshness(status, nowMs);
    var blocked = status.amendment_blocked === true;
    var unlDown = status.unl_active === false;
    var proposing = status.proposing === true;
    if (blocked || unlDown || fr.publishStale || (!proposing && !fr.fresh)) {
      return { level: "attention", label: "Attention" };
    }
    var gaugesKnown =
      status.amendment_blocked === false && status.unl_active === true;
    var hour = status.agreement && status.agreement.agreement_1h;
    // A window that is not one hour of ledgers is not a low score.
    var unmeasured = !!(hour && !agreementWindowUsable(hour, "1h"));
    var a1 = unmeasured ? null : _a1h(status);
    if (
      !proposing ||
      !fr.fresh ||
      !gaugesKnown ||
      (!unmeasured && (a1 == null || a1 < 98))
    ) {
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
    HOUR_LEDGER_CEILING: HOUR_LEDGER_CEILING,
    agreementWindowUsable: agreementWindowUsable,
    freshness: freshness,
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
