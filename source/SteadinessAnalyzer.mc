import Toybox.Lang;
import Toybox.System;
import Toybox.Math;

// Steadiness grade enum
enum SteadinessGrade {
    GRADE_A_PLUS = 0,
    GRADE_A = 1,
    GRADE_B = 2,
    GRADE_C = 3,
    GRADE_D = 4,
    GRADE_F = 5
}

// Single accelerometer sample with timestamp
class AccelSample {
    var timestamp as Number;  // System.getTimer() ms
    var x as Float;           // G-force
    var y as Float;
    var z as Float;
    var magnitude as Float;   // Computed magnitude
    
    function initialize(ts as Number, ax as Float, ay as Float, az as Float) {
        timestamp = ts;
        x = ax;
        y = ay;
        z = az;
        // Calculate magnitude (excluding gravity baseline ~1G)
        var magSq = (x * x) + (y * y) + (z * z);
        magnitude = Math.sqrt(magSq).toFloat();
    }
}

// Result of pre-shot steadiness analysis
class SteadinessResult {
    var shotNumber as Number = 0;
    var timestamp as Number = 0;
    
    // Individual metrics (0-100, lower = more stable)
    var tremorScore as Float = 0.0;   // High-freq micro-movements
    var swayScore as Float = 0.0;     // Low-freq body sway  
    var driftScore as Float = 0.0;    // Gradual position change
    
    // Combined score (0-100, higher = better)
    var steadinessScore as Float = 0.0;
    var grade as SteadinessGrade = GRADE_F;
    var gradeString as String = "F";
    
    // Flinch detection (anticipation)
    var flinchDetected as Boolean = false;
    var flinchMagnitude as Float = 0.0;  // G-force spike before shot
    
    // Recoil analysis
    var recoilMagnitude as Float = 0.0;  // Peak G-force at shot
    var recoilDeviation as Float = 0.0;  // Deviation from session average (consistency)
    
    // Analysis info
    var sampleCount as Number = 0;
    var windowMs as Number = 0;
    var insufficientData as Boolean = false;
    var anomalyDetected as Boolean = false;
    
    function initialize() {}
    
    // Convert to dictionary for sending to phone
    function toDict() as Dictionary {
        return {
            "shotNumber" => shotNumber,
            "score" => steadinessScore.toNumber(),
            "grade" => gradeString,
            "tremor" => tremorScore.toNumber(),
            "sway" => swayScore.toNumber(),
            "drift" => driftScore.toNumber(),
            "samples" => sampleCount,
            "anomaly" => anomalyDetected,
            "flinch" => flinchDetected,
            "flinchMag" => (flinchMagnitude * 100).toNumber(),  // centi-G
            "recoilMag" => (recoilMagnitude * 100).toNumber(),  // centi-G
            "recoilDev" => recoilDeviation.toNumber()           // % deviation
        };
    }
}

// Main analyzer class for pre-shot steadiness
class SteadinessAnalyzer {
    
    // Configuration
    private const ANALYSIS_WINDOW_MS = 1500;  // 1.5 seconds before shot
    private const MIN_WINDOW_MS = 500;        // Minimum usable window
    private const EXCLUDE_BEFORE_SHOT_MS = 50; // Exclude trigger pull
    private const FLINCH_WINDOW_MS = 150;     // Check 150ms before shot for flinch
    private const RECOIL_WINDOW_MS = 100;     // Check 100ms after shot for recoil
    
    // Scoring weights
    private const WEIGHT_TREMOR = 0.35;
    private const WEIGHT_SWAY = 0.35;
    private const WEIGHT_DRIFT = 0.30;
    
    // Sensor buffer - circular buffer for efficiency
    private var _sensorBuffer as Array<AccelSample>;
    private var _bufferSize as Number = 100;    // ~4 seconds at 25Hz
    private var _bufferIndex as Number = 0;
    private var _bufferCount as Number = 0;
    
    // Sample rate estimation
    private var _estimatedSampleRate as Float = 25.0;
    private var _lastSampleTime as Number = 0;
    private var _sampleIntervals as Array<Number>;
    
    // Session statistics
    private var _sessionScores as Array<Float>;
    private var _sessionGrades as Array<Number>;
    
    // Recoil tracking for consistency analysis
    private var _recoilMagnitudes as Array<Float>;
    private var _avgRecoil as Float = 0.0;
    
    // Flinch tracking
    private var _flinchCount as Number = 0;
    
    function initialize() {
        _sensorBuffer = new Array<AccelSample>[_bufferSize];
        _sampleIntervals = [];
        _sessionScores = [];
        _sessionGrades = [];
        _recoilMagnitudes = [];
    }
    
    // Add a new sensor sample to the buffer
    function addSample(x as Float, y as Float, z as Float) as Void {
        var now = System.getTimer();
        
        // Estimate sample rate
        if (_lastSampleTime > 0) {
            var interval = now - _lastSampleTime;
            if (interval > 0 && interval < 200) {  // Sanity check
                _sampleIntervals.add(interval);
                if (_sampleIntervals.size() > 20) {
                    _sampleIntervals = _sampleIntervals.slice(-20, null) as Array<Number>;
                }
                // Update estimated rate
                if (_sampleIntervals.size() >= 5) {
                    var avgInterval = 0;
                    for (var i = 0; i < _sampleIntervals.size(); i++) {
                        avgInterval += _sampleIntervals[i];
                    }
                    avgInterval = avgInterval / _sampleIntervals.size();
                    if (avgInterval > 0) {
                        _estimatedSampleRate = 1000.0 / avgInterval;
                    }
                }
            }
        }
        _lastSampleTime = now;
        
        // Add sample to circular buffer
        var sample = new AccelSample(now, x, y, z);
        _sensorBuffer[_bufferIndex] = sample;
        _bufferIndex = (_bufferIndex + 1) % _bufferSize;
        if (_bufferCount < _bufferSize) {
            _bufferCount++;
        }
    }
    
    // Analyze steadiness for a shot that just occurred
    function analyzeShot(shotTimestamp as Number, shotNumber as Number) as SteadinessResult {
        var result = new SteadinessResult();
        result.shotNumber = shotNumber;
        result.timestamp = shotTimestamp;
        
        // Get samples in analysis window
        var windowStart = shotTimestamp - ANALYSIS_WINDOW_MS;
        var windowEnd = shotTimestamp - EXCLUDE_BEFORE_SHOT_MS;
        
        var windowSamples = getWindowSamples(windowStart, windowEnd);
        result.sampleCount = windowSamples.size();
        result.windowMs = ANALYSIS_WINDOW_MS;
        
        // Check for sufficient data
        var minSamples = (MIN_WINDOW_MS * _estimatedSampleRate / 1000).toNumber();
        if (minSamples < 5) { minSamples = 5; }
        
        if (windowSamples.size() < minSamples) {
            result.insufficientData = true;
            result.steadinessScore = 0.0;
            result.grade = GRADE_F;
            result.gradeString = "?";
            System.println("[STEADY] Insufficient data: " + windowSamples.size() + " samples (need " + minSamples + ")");
            return result;
        }
        
        // Calculate individual metrics
        result.tremorScore = analyzeTremor(windowSamples);
        result.swayScore = analyzeSway(windowSamples);
        result.driftScore = analyzeDrift(windowSamples);
        
        // =====================================================================
        // FLINCH DETECTION - Check 150ms before shot for anticipation spike
        // =====================================================================
        var flinchResult = analyzeFlinch(shotTimestamp);
        result.flinchDetected = flinchResult[0] as Boolean;
        result.flinchMagnitude = flinchResult[1] as Float;
        if (result.flinchDetected) {
            _flinchCount++;
        }
        
        // =====================================================================
        // RECOIL ANALYSIS - Track consistency across shots
        // =====================================================================
        var recoilResult = analyzeRecoil(shotTimestamp);
        result.recoilMagnitude = recoilResult[0] as Float;
        result.recoilDeviation = recoilResult[1] as Float;
        
        // Track recoil for consistency calculation
        if (result.recoilMagnitude > 0) {
            _recoilMagnitudes.add(result.recoilMagnitude);
            // Update average recoil
            var sum = 0.0;
            for (var i = 0; i < _recoilMagnitudes.size(); i++) {
                sum += _recoilMagnitudes[i];
            }
            _avgRecoil = sum / _recoilMagnitudes.size();
        }
        
        // Detect anomalies
        result.anomalyDetected = detectAnomalies(windowSamples);
        
        // Calculate combined instability score
        var instability = (WEIGHT_TREMOR * result.tremorScore) +
                         (WEIGHT_SWAY * result.swayScore) +
                         (WEIGHT_DRIFT * result.driftScore);
        
        // Convert to steadiness (higher = better)
        result.steadinessScore = 100.0 - instability;
        if (result.steadinessScore < 0.0) { result.steadinessScore = 0.0; }
        if (result.steadinessScore > 100.0) { result.steadinessScore = 100.0; }
        
        // Assign grade
        result.grade = scoreToGrade(result.steadinessScore);
        result.gradeString = gradeToString(result.grade);
        
        // Store for session stats
        _sessionScores.add(result.steadinessScore);
        _sessionGrades.add(result.grade);
        
        System.println("[STEADY] Shot " + shotNumber + ": " + result.gradeString + 
                      " (" + result.steadinessScore.format("%.1f") + 
                      ") T:" + result.tremorScore.format("%.0f") +
                      " S:" + result.swayScore.format("%.0f") +
                      " D:" + result.driftScore.format("%.0f") +
                      " [" + windowSamples.size() + " samples]");
        
        return result;
    }
    
    // Get samples within a time window
    private function getWindowSamples(startMs as Number, endMs as Number) as Array<AccelSample> {
        var samples = [] as Array<AccelSample>;
        
        // Iterate through circular buffer
        for (var i = 0; i < _bufferCount; i++) {
            var idx = (_bufferIndex - _bufferCount + i + _bufferSize) % _bufferSize;
            var sample = _sensorBuffer[idx];
            if (sample != null && sample.timestamp >= startMs && sample.timestamp <= endMs) {
                samples.add(sample);
            }
        }
        
        return samples;
    }
    
    // Analyze high-frequency tremor (6-15 Hz micro-movements)
    private function analyzeTremor(samples as Array<AccelSample>) as Float {
        if (samples.size() < 3) { return 100.0; }
        
        // Extract magnitude values
        var magnitudes = [] as Array<Float>;
        for (var i = 0; i < samples.size(); i++) {
            magnitudes.add(samples[i].magnitude);
        }
        
        // Calculate mean
        var mean = 0.0;
        for (var i = 0; i < magnitudes.size(); i++) {
            mean += magnitudes[i];
        }
        mean = mean / magnitudes.size();
        
        // High-pass filter: compute deviation from smoothed signal
        // Simple approach: calculate sample-to-sample variation
        var highFreqEnergy = 0.0;
        for (var i = 1; i < magnitudes.size(); i++) {
            var diff = magnitudes[i] - magnitudes[i-1];
            highFreqEnergy += (diff * diff);
        }
        highFreqEnergy = Math.sqrt(highFreqEnergy / (magnitudes.size() - 1)).toFloat();
        
        // Normalize to 0-100 scale
        // Calibrated: 0.02G RMS tremor = moderate (score ~50)
        var score = (highFreqEnergy / 0.02) * 50.0;
        if (score > 100.0) { score = 100.0; }
        
        return score;
    }
    
    // Analyze low-frequency postural sway (0.3-3 Hz)
    private function analyzeSway(samples as Array<AccelSample>) as Float {
        if (samples.size() < 5) { return 100.0; }
        
        // Extract magnitude values
        var magnitudes = [] as Array<Float>;
        for (var i = 0; i < samples.size(); i++) {
            magnitudes.add(samples[i].magnitude);
        }
        
        // Simple moving average to isolate low-frequency component
        var windowSize = 5;
        if (samples.size() < windowSize * 2) { windowSize = 2; }
        
        var smoothed = [] as Array<Float>;
        for (var i = 0; i < magnitudes.size(); i++) {
            var sum = 0.0;
            var count = 0;
            for (var j = i - windowSize; j <= i + windowSize; j++) {
                if (j >= 0 && j < magnitudes.size()) {
                    sum += magnitudes[j];
                    count++;
                }
            }
            smoothed.add(sum / count);
        }
        
        // Calculate peak-to-peak amplitude of smoothed signal
        var minVal = smoothed[0];
        var maxVal = smoothed[0];
        for (var i = 1; i < smoothed.size(); i++) {
            if (smoothed[i] < minVal) { minVal = smoothed[i]; }
            if (smoothed[i] > maxVal) { maxVal = smoothed[i]; }
        }
        
        var swayAmplitude = maxVal - minVal;
        
        // Normalize to 0-100 scale
        // Calibrated: 0.1G peak-to-peak sway = moderate (score ~50)
        var score = (swayAmplitude / 0.1) * 50.0;
        if (score > 100.0) { score = 100.0; }
        
        return score;
    }
    
    // Analyze gradual position drift (linear trend)
    private function analyzeDrift(samples as Array<AccelSample>) as Float {
        if (samples.size() < 5) { return 100.0; }
        
        // Simple linear regression on magnitude over time
        var n = samples.size();
        var sumX = 0.0;
        var sumY = 0.0;
        var sumXY = 0.0;
        var sumX2 = 0.0;
        
        var startTime = samples[0].timestamp;
        for (var i = 0; i < n; i++) {
            var x = (samples[i].timestamp - startTime).toFloat() / 1000.0;  // Seconds
            var y = samples[i].magnitude;
            sumX += x;
            sumY += y;
            sumXY += x * y;
            sumX2 += x * x;
        }
        
        // Calculate slope (drift rate)
        var denom = (n * sumX2) - (sumX * sumX);
        var slope = 0.0;
        if (denom.abs() > 0.0001) {
            slope = ((n * sumXY) - (sumX * sumY)) / denom;
        }
        
        var driftRate = slope.abs();
        
        // Normalize to 0-100 scale
        // Calibrated: 0.05G/sec drift = moderate (score ~50)
        var score = (driftRate / 0.05) * 50.0;
        if (score > 100.0) { score = 100.0; }
        
        return score;
    }
    
    // Detect anomalies (sudden movements, glitches)
    private function detectAnomalies(samples as Array<AccelSample>) as Boolean {
        if (samples.size() < 5) { return false; }
        
        // Calculate mean and std of magnitudes
        var mean = 0.0;
        for (var i = 0; i < samples.size(); i++) {
            mean += samples[i].magnitude;
        }
        mean = mean / samples.size();
        
        var variance = 0.0;
        for (var i = 0; i < samples.size(); i++) {
            var diff = samples[i].magnitude - mean;
            variance += (diff * diff);
        }
        var std = Math.sqrt(variance / samples.size()).toFloat();
        
        // Count samples > 3 standard deviations
        var threshold = mean + (3.0 * std);
        var spikeCount = 0;
        for (var i = 0; i < samples.size(); i++) {
            if (samples[i].magnitude > threshold) {
                spikeCount++;
            }
        }
        
        return spikeCount > 2;
    }
    
    // =========================================================================
    // FLINCH DETECTION - Anticipation spike before trigger break
    // Returns [flinchDetected, flinchMagnitude]
    // =========================================================================
    private function analyzeFlinch(shotTimestamp as Number) as Array {
        // Get samples in the flinch window (150ms before shot)
        var flinchStart = shotTimestamp - FLINCH_WINDOW_MS;
        var flinchEnd = shotTimestamp - 10;  // Exclude very last moment
        
        var samples = getWindowSamples(flinchStart, flinchEnd);
        if (samples.size() < 3) {
            return [false, 0.0];
        }
        
        // Get baseline from earlier samples (500-200ms before shot)
        var baselineStart = shotTimestamp - 500;
        var baselineEnd = shotTimestamp - 200;
        var baselineSamples = getWindowSamples(baselineStart, baselineEnd);
        
        var baselineMean = 1.0;  // Default ~1G (gravity)
        if (baselineSamples.size() >= 3) {
            var sum = 0.0;
            for (var i = 0; i < baselineSamples.size(); i++) {
                sum += baselineSamples[i].magnitude;
            }
            baselineMean = sum / baselineSamples.size();
        }
        
        // Find peak in flinch window
        var peakMag = 0.0;
        for (var i = 0; i < samples.size(); i++) {
            if (samples[i].magnitude > peakMag) {
                peakMag = samples[i].magnitude;
            }
        }
        
        // Flinch = spike > 0.3G above baseline in pre-shot window
        var flinchMagnitude = peakMag - baselineMean;
        var flinchDetected = flinchMagnitude > 0.3;
        
        if (flinchDetected) {
            System.println("[STEADY] FLINCH detected! Peak: " + peakMag.format("%.2f") + 
                          "G, baseline: " + baselineMean.format("%.2f") + "G");
        }
        
        return [flinchDetected, flinchMagnitude > 0 ? flinchMagnitude : 0.0];
    }
    
    // =========================================================================
    // RECOIL ANALYSIS - Track consistency across shots
    // Returns [recoilMagnitude, deviationPercent]
    // =========================================================================
    private function analyzeRecoil(shotTimestamp as Number) as Array {
        // Get samples around the shot (including shot moment)
        var recoilStart = shotTimestamp - 20;
        var recoilEnd = shotTimestamp + RECOIL_WINDOW_MS;
        
        var samples = getWindowSamples(recoilStart, recoilEnd);
        if (samples.size() < 2) {
            return [0.0, 0.0];
        }
        
        // Find peak magnitude (the recoil spike)
        var peakMag = 0.0;
        for (var i = 0; i < samples.size(); i++) {
            if (samples[i].magnitude > peakMag) {
                peakMag = samples[i].magnitude;
            }
        }
        
        // Calculate deviation from session average
        var deviation = 0.0;
        if (_avgRecoil > 0 && _recoilMagnitudes.size() >= 2) {
            deviation = ((peakMag - _avgRecoil) / _avgRecoil * 100).abs();
        }
        
        return [peakMag, deviation];
    }
    
    // Get recoil consistency score (0-100, higher = more consistent)
    function getRecoilConsistency() as Float {
        if (_recoilMagnitudes.size() < 3) {
            return 0.0;  // Not enough data
        }
        
        // Calculate coefficient of variation (CV)
        var mean = _avgRecoil;
        var variance = 0.0;
        for (var i = 0; i < _recoilMagnitudes.size(); i++) {
            var diff = _recoilMagnitudes[i] - mean;
            variance += (diff * diff);
        }
        var std = Math.sqrt(variance / _recoilMagnitudes.size()).toFloat();
        var cv = (mean > 0) ? (std / mean * 100) : 100.0;
        
        // Convert to score: lower CV = higher consistency
        // CV of 10% = score of 90, CV of 30% = score of 70, etc.
        var score = 100.0 - cv;
        if (score < 0) { score = 0.0; }
        if (score > 100) { score = 100.0; }
        
        return score;
    }
    
    // Get flinch rate (percentage of shots with flinch)
    function getFlinchRate() as Float {
        if (_sessionScores.size() == 0) {
            return 0.0;
        }
        return (_flinchCount.toFloat() / _sessionScores.size() * 100);
    }
    
    // Convert score to grade
    private function scoreToGrade(score as Float) as SteadinessGrade {
        if (score >= 95.0) { return GRADE_A_PLUS; }
        if (score >= 85.0) { return GRADE_A; }
        if (score >= 70.0) { return GRADE_B; }
        if (score >= 55.0) { return GRADE_C; }
        if (score >= 40.0) { return GRADE_D; }
        return GRADE_F;
    }
    
    // Convert grade to string
    private function gradeToString(grade as SteadinessGrade) as String {
        switch (grade) {
            case GRADE_A_PLUS: return "A+";
            case GRADE_A: return "A";
            case GRADE_B: return "B";
            case GRADE_C: return "C";
            case GRADE_D: return "D";
            default: return "F";
        }
    }
    
    // Get session average score
    function getSessionAverage() as Float {
        if (_sessionScores.size() == 0) { return 0.0; }
        var total = 0.0;
        for (var i = 0; i < _sessionScores.size(); i++) {
            total += _sessionScores[i];
        }
        return total / _sessionScores.size();
    }
    
    // Get grade distribution for session
    function getGradeDistribution() as Dictionary {
        var dist = {
            "A+" => 0,
            "A" => 0,
            "B" => 0,
            "C" => 0,
            "D" => 0,
            "F" => 0
        };
        
        for (var i = 0; i < _sessionGrades.size(); i++) {
            var g = gradeToString(_sessionGrades[i] as SteadinessGrade);
            var count = dist.get(g) as Number;
            dist.put(g, count + 1);
        }
        
        return dist;
    }
    
    // Get steadiness trend: "improving", "declining", "stable"
    function getSessionTrend() as String {
        if (_sessionScores.size() < 4) { return "stable"; }
        
        var mid = _sessionScores.size() / 2;
        
        var firstHalf = 0.0;
        for (var i = 0; i < mid; i++) {
            firstHalf += _sessionScores[i];
        }
        firstHalf = firstHalf / mid;
        
        var secondHalf = 0.0;
        var secondCount = _sessionScores.size() - mid;
        for (var i = mid; i < _sessionScores.size(); i++) {
            secondHalf += _sessionScores[i];
        }
        secondHalf = secondHalf / secondCount;
        
        var diff = secondHalf - firstHalf;
        if (diff > 5.0) { return "improving"; }
        if (diff < -5.0) { return "declining"; }
        return "stable";
    }
    
    // Reset for new session
    function resetSession() as Void {
        _sessionScores = [];
        _sessionGrades = [];
        _recoilMagnitudes = [];
        _avgRecoil = 0.0;
        _flinchCount = 0;
        clearBuffer();
    }
    
    // Clear the sensor buffer
    function clearBuffer() as Void {
        _bufferCount = 0;
        _bufferIndex = 0;
        _sampleIntervals = [];
    }
    
    // Get estimated sample rate
    function getSampleRate() as Float {
        return _estimatedSampleRate;
    }
    
    // Get current buffer count
    function getBufferCount() as Number {
        return _bufferCount;
    }
}
