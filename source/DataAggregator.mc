// DataAggregator.mc - Aggregates raw data into summary and per-shot stats
// Reduces payload size by computing stats on-device
// Protocol v2: Enhanced summaries for SESSION_SUMMARY
import Toybox.Lang;
import Toybox.Math;

class DataAggregator {

    // ========================================
    // SPLIT TIME STATISTICS
    // ========================================

    // Calculate split time stats from array of split times (ms)
    function calcSplitStats(splits as Array<Number>) as Dictionary {
        if (splits.size() == 0) {
            return {"avg" => 0, "best" => 0, "worst" => 0, "first" => 0, "stdDev" => 0};
        }

        var sum = 0;
        var best = splits[0];
        var worst = splits[0];

        for (var i = 0; i < splits.size(); i++) {
            var split = splits[i];
            sum += split;
            if (split < best) { best = split; }
            if (split > worst) { worst = split; }
        }

        var avg = sum / splits.size();

        // Calculate standard deviation (consistency metric)
        var stdDev = 0.0;
        if (splits.size() >= 2) {
            var variance = 0.0;
            for (var i = 0; i < splits.size(); i++) {
                var diff = splits[i] - avg;
                variance += (diff * diff).toFloat();
            }
            stdDev = Math.sqrt(variance / splits.size()).toFloat();
        }

        return {
            "avg" => avg,
            "best" => best,
            "worst" => worst,
            "first" => splits[0],
            "stdDev" => stdDev.toNumber()
        };
    }

    // Trim splits array to maxSize (first half + last half if too long)
    // Protocol v2: Max 20 splits in summary
    function trimSplits(splits as Array<Number>, maxSize as Number) as Array<Number> {
        if (splits.size() <= maxSize) {
            return splits;
        }

        // Take first half + last half
        var halfSize = maxSize / 2;
        var result = [] as Array<Number>;

        // First half
        for (var i = 0; i < halfSize && i < splits.size(); i++) {
            result.add(splits[i]);
        }

        // Last half
        var startIdx = splits.size() - halfSize;
        if (startIdx < halfSize) { startIdx = halfSize; }
        for (var i = startIdx; i < splits.size(); i++) {
            result.add(splits[i]);
        }

        return result;
    }

    // ========================================
    // STEADINESS STATISTICS
    // ========================================

    // Calculate steadiness stats from SteadinessResult array
    function calcSteadinessStats(results as Array<SteadinessResult>) as Dictionary {
        if (results.size() == 0) {
            return {"avg" => 0, "trend" => "unknown", "flinch" => 0};
        }

        var totalScore = 0.0;
        var flinchCount = 0;

        for (var i = 0; i < results.size(); i++) {
            totalScore += results[i].steadinessScore;
            if (results[i].flinchDetected) {
                flinchCount++;
            }
        }

        var avg = (totalScore / results.size()).toNumber();

        // Trend: compare first half to second half
        var trend = "stable";
        if (results.size() >= 4) {
            var mid = results.size() / 2;
            var firstSum = 0.0;
            var secondSum = 0.0;

            for (var i = 0; i < mid; i++) {
                firstSum += results[i].steadinessScore;
            }
            for (var i = mid; i < results.size(); i++) {
                secondSum += results[i].steadinessScore;
            }

            var firstAvg = firstSum / mid;
            var secondAvg = secondSum / (results.size() - mid);

            if (secondAvg > firstAvg + 5) { trend = "improving"; }
            else if (secondAvg < firstAvg - 5) { trend = "declining"; }
        }

        return {
            "avg" => avg,
            "trend" => trend,
            "flinch" => flinchCount
        };
    }

    // ========================================
    // BIOMETRICS STATISTICS (from BiometricsTracker)
    // Protocol v2: Enhanced summaries with start/end values
    // ========================================

    // Extract HR summary from BiometricsTracker session summary (legacy format)
    function extractHRSummary(bioSummary as Dictionary) as Dictionary {
        return {
            "avg" => bioSummary.get("avgHR") != null ? (bioSummary.get("avgHR") as Number) : 0,
            "min" => bioSummary.get("minHR") != null ? (bioSummary.get("minHR") as Number) : 0,
            "max" => bioSummary.get("maxHR") != null ? (bioSummary.get("maxHR") as Number) : 0
        };
    }

    // Extract full HR summary with start/end (Protocol v2 format)
    function extractFullHRSummary(bioSummary as Dictionary) as Dictionary {
        return {
            "avg" => bioSummary.get("avgHR") != null ? (bioSummary.get("avgHR") as Number) : 0,
            "min" => bioSummary.get("minHR") != null ? (bioSummary.get("minHR") as Number) : 0,
            "max" => bioSummary.get("maxHR") != null ? (bioSummary.get("maxHR") as Number) : 0,
            "start" => bioSummary.get("startHR") != null ? (bioSummary.get("startHR") as Number) : 0,
            "end" => bioSummary.get("endHR") != null ? (bioSummary.get("endHR") as Number) : 0
        };
    }

    // Extract breath rate from BiometricsTracker session summary
    function extractBreathRate(bioSummary as Dictionary) as Number {
        return bioSummary.get("avgBreathRate") != null ? (bioSummary.get("avgBreathRate") as Number) : 0;
    }

    // Extract stress summary from BiometricsTracker (legacy format)
    function extractStressSummary(bioSummary as Dictionary) as Dictionary {
        return {
            "avg" => bioSummary.get("stressAvg") != null ? (bioSummary.get("stressAvg") as Number) : 0,
            "trend" => bioSummary.get("stressTrend") != null ? bioSummary.get("stressTrend").toString() : "stable"
        };
    }

    // Extract full stress summary with min/max (Protocol v2 format)
    function extractFullStressSummary(bioSummary as Dictionary) as Dictionary {
        return {
            "avg" => bioSummary.get("stressAvg") != null ? (bioSummary.get("stressAvg") as Number) : 0,
            "min" => bioSummary.get("stressMin") != null ? (bioSummary.get("stressMin") as Number) : 0,
            "max" => bioSummary.get("stressMax") != null ? (bioSummary.get("stressMax") as Number) : 0
        };
    }

    // ========================================
    // PER-SHOT DATA BUILDING
    // ========================================

    // Build compact per-shot data array from steadiness results and biometrics
    // Format: [{n, t, st, fl, hr}, ...]
    function buildPerShotData(
        steadinessResults as Array<SteadinessResult>,
        shotBiometrics as Array<Dictionary>
    ) as Array<Dictionary> {
        var shots = [] as Array<Dictionary>;

        for (var i = 0; i < steadinessResults.size(); i++) {
            var sr = steadinessResults[i];

            // Find matching biometrics by shot number
            var hr = 0;
            for (var j = 0; j < shotBiometrics.size(); j++) {
                var bio = shotBiometrics[j];
                if (bio.get("shot") != null && (bio.get("shot") as Number) == sr.shotNumber) {
                    hr = bio.get("hr") != null ? (bio.get("hr") as Number) : 0;
                    break;
                }
            }

            var shotData = {
                "n" => sr.shotNumber,
                "t" => sr.timestamp,
                "st" => sr.steadinessScore.toNumber(),
                "fl" => sr.flinchDetected ? 1 : 0,
                "hr" => hr
            };

            shots.add(shotData);
        }

        return shots;
    }

    // Build compact steadiness data per shot (without biometrics)
    function buildSteadinessPerShot(results as Array<SteadinessResult>) as Array<Dictionary> {
        var shots = [] as Array<Dictionary>;

        for (var i = 0; i < results.size(); i++) {
            var r = results[i];
            shots.add({
                "n" => r.shotNumber,
                "score" => r.steadinessScore.toNumber(),
                "grade" => r.gradeString,
                "fl" => r.flinchDetected ? 1 : 0,
                "tremor" => r.tremorScore.toNumber(),
                "sway" => r.swayScore.toNumber(),
                "drift" => r.driftScore.toNumber()
            });
        }

        return shots;
    }

    // ========================================
    // PERFORMANCE ANALYTICS
    // ========================================

    // Calculate performance metrics
    function calcPerformanceStats(
        totalElapsedMs as Number,
        shotCount as Number,
        splitTimes as Array<Number>,
        parTime as Number,
        steadinessResults as Array<SteadinessResult>
    ) as Dictionary {

        // First shot time calculation
        var firstShotTime = 0;
        if (splitTimes.size() > 0) {
            var sumSplits = 0;
            for (var i = 0; i < splitTimes.size(); i++) {
                sumSplits += splitTimes[i];
            }
            firstShotTime = totalElapsedMs - sumSplits;
        } else if (shotCount > 0) {
            firstShotTime = totalElapsedMs;
        }

        // Shots per minute
        var shotsPerMinute = 0.0;
        if (totalElapsedMs > 0 && shotCount > 0) {
            shotsPerMinute = (shotCount.toFloat() / totalElapsedMs * 60000);
        }

        // Par delta (ms)
        var parDelta = 0;
        if (parTime > 0) {
            parDelta = totalElapsedMs - (parTime * 1000);  // parTime is in seconds
        }

        // Warmup vs rest analysis (first 3 shots vs rest)
        var warmupAvg = 0;
        var restAvg = 0;
        if (steadinessResults.size() >= 4) {
            var warmupSum = 0.0;
            for (var i = 0; i < 3 && i < steadinessResults.size(); i++) {
                warmupSum += steadinessResults[i].steadinessScore;
            }
            warmupAvg = (warmupSum / 3).toNumber();

            var restSum = 0.0;
            var restCount = 0;
            for (var i = 3; i < steadinessResults.size(); i++) {
                restSum += steadinessResults[i].steadinessScore;
                restCount++;
            }
            if (restCount > 0) {
                restAvg = (restSum / restCount).toNumber();
            }
        }

        // Last 3 shots average (fatigue indicator)
        var lastThreeAvg = 0;
        if (steadinessResults.size() >= 3) {
            var sum = 0.0;
            var start = steadinessResults.size() - 3;
            for (var i = start; i < steadinessResults.size(); i++) {
                sum += steadinessResults[i].steadinessScore;
            }
            lastThreeAvg = (sum / 3).toNumber();
        }

        return {
            "first" => firstShotTime,
            "spm" => (shotsPerMinute * 10).toNumber(),  // x10 for precision
            "parDelta" => parDelta,
            "warmup" => warmupAvg,
            "rest" => restAvg,
            "fatigue" => lastThreeAvg
        };
    }

    // ========================================
    // GRADE DISTRIBUTION
    // ========================================

    function calcGradeDistribution(results as Array<SteadinessResult>) as Dictionary {
        var dist = {
            "A+" => 0,
            "A" => 0,
            "B" => 0,
            "C" => 0,
            "D" => 0,
            "F" => 0
        };

        for (var i = 0; i < results.size(); i++) {
            var g = results[i].gradeString;
            var count = dist.get(g);
            if (count != null) {
                dist.put(g, (count as Number) + 1);
            }
        }

        return dist;
    }

    // Find best and worst shots
    function findBestWorstShots(results as Array<SteadinessResult>) as Dictionary {
        if (results.size() == 0) {
            return {"bestIdx" => 0, "bestScore" => 0, "worstIdx" => 0, "worstScore" => 0};
        }

        var bestIdx = 1;
        var worstIdx = 1;
        var bestScore = 0.0;
        var worstScore = 100.0;

        for (var i = 0; i < results.size(); i++) {
            var score = results[i].steadinessScore;
            if (score > bestScore) {
                bestScore = score;
                bestIdx = i + 1;
            }
            if (score < worstScore) {
                worstScore = score;
                worstIdx = i + 1;
            }
        }

        return {
            "bestIdx" => bestIdx,
            "bestScore" => bestScore.toNumber(),
            "worstIdx" => worstIdx,
            "worstScore" => worstScore.toNumber()
        };
    }
}
