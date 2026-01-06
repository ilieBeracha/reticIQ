// PayloadBuilder.mc - Builds sync payloads from aggregated data
// Protocol v2: SESSION_SUMMARY (~1KB) contains all data, TIMELINE_CHUNK sent separately
import Toybox.Lang;
import Toybox.Time;
import Toybox.System;

class PayloadBuilder {

    private var _aggregator as DataAggregator;

    function initialize() {
        _aggregator = new DataAggregator();
    }

    // Build summary payload only (Protocol v2: no separate details phase)
    // Returns {"summary" => Dict}
    function build(
        sessionManager as SessionManager,
        biometricsTracker as BiometricsTracker?,
        steadinessAnalyzer as SteadinessAnalyzer?
    ) as Dictionary {
        return {
            "summary" => buildSummary(sessionManager, biometricsTracker, steadinessAnalyzer)
        };
    }

    // ========================================
    // PHASE 1: SESSION_SUMMARY (~1KB)
    // Protocol v2 format - all metadata in single message
    // Phone shows "Session Recorded" toast immediately
    // ========================================

    function buildSummary(
        session as SessionManager,
        bioTracker as BiometricsTracker?,
        steadyAnalyzer as SteadinessAnalyzer?
    ) as Dictionary {

        var splitTimes = session.getSplitTimes();
        var steadinessResults = session.getSteadinessResults();
        var splitStats = _aggregator.calcSplitStats(splitTimes);
        var steadyStats = _aggregator.calcSteadinessStats(steadinessResults);

        // Get biometrics summary if available
        var hrData = {"avg" => 0, "min" => 0, "max" => 0, "start" => 0, "end" => 0};
        var stressData = {"avg" => 0, "min" => 0, "max" => 0};
        var breathAvg = 0;
        var breathSource = "none";  // "native", "estimated", or "none"
        var hrvSource = "estimated";  // "native" (IBI) or "estimated"
        var bodyBattery = -1;  // Readiness at session start
        var optimalPct = 0;  // % of shots in optimal conditions

        if (bioTracker != null) {
            var bioSummary = bioTracker.getSessionSummary();
            hrData = _aggregator.extractFullHRSummary(bioSummary);
            stressData = _aggregator.extractFullStressSummary(bioSummary);
            breathAvg = _aggregator.extractBreathRate(bioSummary);
            breathSource = bioTracker.getBreathingSource();
            hrvSource = bioTracker.getHrvSource();
            bodyBattery = bioTracker.getSessionStartBodyBattery();
            optimalPct = bioSummary.get("optimalPct") != null ? bioSummary.get("optimalPct") as Number : 0;
            // NOTE: shotBiometrics removed - too large for summary, sent in TIMELINE_CHUNK
        }

        // Get steadiness metrics
        var shotSteadinessAvg = steadyStats.get("avg") as Number;
        var gradeDistribution = {} as Dictionary;
        var recoilConsistency = 0;
        
        if (steadyAnalyzer != null) {
            gradeDistribution = steadyAnalyzer.getGradeDistribution();
            recoilConsistency = steadyAnalyzer.getRecoilConsistency().toNumber();
        }

        // Get duration in milliseconds (phone expects ms, not seconds)
        var durationMs = session.getDurationMs();

        // Calculate shots per minute x10 (for precision without decimals)
        var spm = 0;
        if (durationMs > 0 && session.getShotCount() > 0) {
            spm = (session.getShotCount().toFloat() / durationMs * 60000 * 10).toNumber();
        }

        // Trim splits to max 20 (first 10 + last 10 if more)
        var trimmedSplits = _aggregator.trimSplits(splitTimes, 20);

        // Calculate average split
        var avgSplit = splitStats.get("avg") as Number;

        return {
            // === IDENTIFICATION ===
            "sid" => session.getSessionId(),

            // === CORE RESULTS ===
            "shots" => session.getShotCount(),
            "hits" => 0,  // Phone expects this field (user enters hits separately)
            "dur" => durationMs,  // Duration in milliseconds (not seconds)
            "dist" => session.getDistance(),
            "done" => session.isCompleted(),  // Phone expects "done" not "complete"

            // === SPLIT TIMES (top-level for phone compatibility) ===
            "splits" => trimmedSplits,

            // === BIOMETRICS SUMMARY ===
            "bio" => {
                "hr" => hrData,
                "stress" => stressData,
                "breath" => {
                    "avg" => breathAvg,
                    "source" => breathSource  // "native", "estimated", or "none"
                },
                "hrvSource" => hrvSource,     // "native" (real IBI) or "estimated" (from HR)
                "bodyBattery" => bodyBattery, // Readiness at session start (-1 if unavailable)
                "optimalPct" => optimalPct    // % of shots in optimal conditions (pause+stable+lowStress)
            },

            // NOTE: Per-shot biometrics (shotBio) removed from summary - too large!
            // This data is sent in TIMELINE_CHUNK instead

            // === DETECTION METADATA ===
            "detection" => {
                "auto" => session.wasAutoDetected(),
                "sens" => session.getSensitivity(),
                "overrides" => session.getManualOverrides()
            },

            // === STEADINESS METRICS ===
            "steady" => {
                "avg" => steadyStats.get("avg"),
                "trend" => steadyStats.get("trend"),  // "improving", "declining", "stable"
                "flinch" => steadyStats.get("flinch"),  // Flinch count
                "shots" => shotSteadinessAvg,           // Average steadiness at shot moments
                "grades" => gradeDistribution,          // {"A+" => 3, "A" => 5, "B" => 2, ...}
                "recoilConsistency" => recoilConsistency // Grip/stance consistency (0-100)
            },

            // === PERFORMANCE METRICS ===
            "perf" => {
                "first" => splitStats.get("first"),
                "best" => splitStats.get("best"),    // Fastest split
                "worst" => splitStats.get("worst"),  // Slowest split
                "avg" => avgSplit,                   // Average split
                "spm" => spm                         // Shots per minute x10
            },

            // === TIMESTAMP ===
            "ts" => Time.now().value() * 1000  // Unix timestamp in ms
        };
    }
}
