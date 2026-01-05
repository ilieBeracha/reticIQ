import Toybox.Lang;
import Toybox.System;
import Toybox.Sensor;
import Toybox.Timer;
import Toybox.Math;
import Toybox.UserProfile;

// Heart rate sample for timeline
class HRSample {
    var timestamp as Number;      // ms since session start
    var heartRate as Number;      // BPM
    var shotNumber as Number;     // 0 = between shots, >0 = at shot moment
    
    function initialize(ts as Number, hr as Number, shot as Number) {
        timestamp = ts;
        heartRate = hr;
        shotNumber = shot;
    }
    
    function toDict() as Dictionary {
        return {
            "t" => timestamp,
            "hr" => heartRate,
            "shot" => shotNumber
        };
    }
}

// Breathing sample derived from HR variability
class BreathSample {
    var timestamp as Number;      // ms since session start
    var breathRate as Float;      // breaths per minute (estimated)
    var phase as String;          // "inhale", "exhale", "pause"
    var shotNumber as Number;     // 0 = between shots, >0 = at shot moment
    
    function initialize(ts as Number, rate as Float, ph as String, shot as Number) {
        timestamp = ts;
        breathRate = rate;
        phase = ph;
        shotNumber = shot;
    }
    
    function toDict() as Dictionary {
        return {
            "t" => timestamp,
            "br" => breathRate.toNumber(),
            "phase" => phase,
            "shot" => shotNumber
        };
    }
}

// Shot biometrics snapshot
class ShotBiometrics {
    var shotNumber as Number = 0;
    var timestamp as Number = 0;
    var heartRate as Number = 0;
    var heartRateAvg5s as Number = 0;    // 5-second average before shot
    var breathRate as Float = 0.0;
    var breathPhase as String = "";       // Were they in respiratory pause?
    var hrTrend as String = "";           // "rising", "falling", "stable"
    var stressScore as Number = 0;        // HRV-based stress (0-100, higher = more stressed)
    var hrvRmssd as Float = 0.0;          // Raw HRV metric
    
    function initialize() {}
    
    function toDict() as Dictionary {
        return {
            "shot" => shotNumber,
            "hr" => heartRate,
            "hrAvg" => heartRateAvg5s,
            "br" => breathRate.toNumber(),
            "breathPhase" => breathPhase,
            "hrTrend" => hrTrend,
            "stress" => stressScore,
            "rmssd" => (hrvRmssd * 10).toNumber()  // deci-ms for compactness
        };
    }
}

// Main biometrics tracker
class BiometricsTracker {

    // Configuration
    private const HR_SAMPLE_INTERVAL_MS = 1000;   // Sample HR every 1 second
    private const MAX_HR_SAMPLES = 600;           // 10 minutes of data
    private const MAX_BREATH_SAMPLES = 300;       // 5 minutes of breath data
    private const BREATH_WINDOW_SAMPLES = 10;     // Samples for breath detection
    private const TIMELINE_SAMPLE_INTERVAL_MS = 3000;  // Timeline sample every 3 seconds

    // State
    private var _isTracking as Boolean = false;
    private var _sessionStartTime as Number = 0;
    private var _sampleTimer as Timer.Timer?;
    private var _lastTimelineSampleTime as Number = 0;

    // Timeline chunker for reliable sync
    private var _timelineChunker as TimelineChunker?;
    
    // Current readings
    private var _currentHR as Number = 0;
    private var _lastHRTime as Number = 0;
    
    // HR timeline for charting
    private var _hrTimeline as Array<HRSample>;
    private var _hrBuffer as Array<Number>;       // Rolling buffer for calculations
    
    // Breathing detection
    private var _breathTimeline as Array<BreathSample>;
    private var _rrIntervals as Array<Number>;    // R-R intervals for HRV analysis
    private var _currentBreathRate as Float = 0.0;
    private var _currentBreathPhase as String = "unknown";
    private var _hasNativeRespiration as Boolean = false;  // True if device has native sensor
    private var _breathingSource as String = "none";       // "native", "estimated", or "none"
    
    // Native HRV/IBI support (real beat-to-beat data)
    private var _hasNativeIBI as Boolean = false;          // True if device provides heartBeatIntervals
    private var _hrvSource as String = "estimated";        // "native" or "estimated"
    
    // Body Battery (session start readiness indicator)
    private var _sessionStartBodyBattery as Number = -1;   // -1 = not available
    
    // Shot biometrics
    private var _shotBiometrics as Array<ShotBiometrics>;
    
    // Mock biometrics for simulator testing (no real sensor data in simulator)
    private var _useMockData as Boolean = false;
    private var _mockHRBase as Number = 72;               // Base HR for simulation
    private var _mockBreathCycle as Number = 0;           // Breath cycle counter
    
    // Session stats
    private var _minHR as Number = 999;
    private var _maxHR as Number = 0;
    private var _avgHR as Float = 0.0;
    private var _hrSum as Number = 0;
    private var _hrCount as Number = 0;

    // Start/end HR for Protocol v2 summary
    private var _startHR as Number = 0;
    private var _endHR as Number = 0;
    
    function initialize() {
        _hrTimeline = [];
        _hrBuffer = [];
        _breathTimeline = [];
        _rrIntervals = [];
        _shotBiometrics = [];
        _timelineChunker = new TimelineChunker();
    }
    
    // =========================================================================
    // PUBLIC API
    // =========================================================================
    
    // Start tracking biometrics
    function startTracking(sessionId as String) as Void {
        if (_isTracking) {
            System.println("[BIO] Already tracking, skipping start");
            return;
        }

        System.println("[BIO] ========== STARTING BIOMETRICS TRACKING ==========");
        System.println("[BIO] Session ID: " + sessionId);

        _isTracking = true;
        _sessionStartTime = System.getTimer();
        _lastTimelineSampleTime = _sessionStartTime;
        
        // Capture Body Battery at session start (readiness indicator)
        // Available on Fenix 6+, Venu, etc. (API 3.3.0+)
        _sessionStartBodyBattery = -1;  // Reset
        try {
            if (Toybox has :UserProfile) {
                var profile = Toybox.UserProfile;
                if (profile has :getBodyBattery) {
                    var bb = profile.getBodyBattery();
                    if (bb != null) {
                        _sessionStartBodyBattery = bb as Number;
                        System.println("[BIO] ✓ Body Battery at start: " + _sessionStartBodyBattery + "%");
                    }
                }
            }
        } catch (ex) {
            System.println("[BIO] Body Battery not available: " + ex.getErrorMessage());
        }

        // Initialize timeline chunker for this session
        if (_timelineChunker != null) {
            _timelineChunker.reset(sessionId);
            System.println("[BIO] ✓ TimelineChunker reset for session: " + sessionId);
        } else {
            System.println("[BIO] ❌ _timelineChunker is NULL - timeline data will be LOST!");
        }
        
        // Enable heart rate sensor
        try {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            System.println("[BIO] Heart rate sensor enabled");
        } catch (ex) {
            System.println("[BIO] Failed to enable HR sensor: " + ex.getErrorMessage());
        }
        
        // Start sampling timer
        _sampleTimer = new Timer.Timer();
        _sampleTimer.start(method(:onSampleTimer), HR_SAMPLE_INTERVAL_MS, true);
        
        // *** CRITICAL: Add immediate first timeline sample at t=0 ***
        // This ensures we have data even for very short sessions
        System.println("[BIO] Adding immediate first timeline sample at t=0");
        addTimelineSample();
    }
    
    // Stop tracking
    function stopTracking() as Void {
        if (!_isTracking) {
            return;
        }
        
        System.println("[BIO] Stopping biometrics tracking");
        
        // *** CRITICAL: Add final timeline sample before stopping ***
        // This ensures we capture the end state
        System.println("[BIO] Adding final timeline sample before stop");
        addTimelineSample();
        
        _isTracking = false;
        
        if (_sampleTimer != null) {
            _sampleTimer.stop();
            _sampleTimer = null;
        }
        
        // Disable HR sensor
        try {
            Sensor.setEnabledSensors([]);
        } catch (ex) {
            // Ignore
        }
        
        // Log final stats
        if (_timelineChunker != null) {
            System.println("[BIO] ✓ Final timeline stats: " + _timelineChunker.getPointCount() + " points, " + _timelineChunker.getShotCount() + " shots");
        }
    }
    
    // Called periodically to sample HR
    function onSampleTimer() as Void {
        var info = Sensor.getInfo();
        var gotRealHR = false;

        if (info.heartRate != null) {
            var hr = info.heartRate as Number;
            if (hr > 0 && hr < 250) {  // Sanity check
                recordHeartRate(hr, 0);  // 0 = not a shot moment
                gotRealHR = true;
                _useMockData = false;  // Real sensor working
            }
        }
        
        // SIMULATOR FALLBACK: Generate mock biometrics when no real data
        // This allows testing the full data pipeline in the simulator
        if (!gotRealHR && _hrCount < 3) {
            // After 3 attempts with no data, enable mock mode
            _useMockData = true;
            System.println("[BIO] No sensor data - enabling mock biometrics for simulator");
        }
        
        if (_useMockData) {
            // Generate realistic mock HR (72-85 BPM with some variation)
            var sessionTimeSec = (System.getTimer() - _sessionStartTime) / 1000;
            var hrVariation = (Math.sin(sessionTimeSec.toFloat() * 0.1) * 6).toNumber();  // Slow drift
            var hrNoise = (Math.rand() % 5) - 2;  // Random noise ±2
            var mockHR = _mockHRBase + hrVariation + hrNoise;
            if (mockHR < 55) { mockHR = 55; }
            if (mockHR > 120) { mockHR = 120; }
            recordHeartRate(mockHR, 0);
            
            // Generate mock RR intervals for HRV (800-900ms with realistic variability)
            var baseRR = (60000.0 / mockHR.toFloat()).toNumber();
            var rrVariation = (Math.rand() % 50) - 25;  // ±25ms HRV
            var mockRR = baseRR + rrVariation;
            if (mockRR > 200 && mockRR < 2000) {
                _rrIntervals.add(mockRR);
                if (_rrIntervals.size() > 60) {
                    var startIdx = _rrIntervals.size() - 60;
                    _rrIntervals = _rrIntervals.slice(startIdx, _rrIntervals.size()) as Array<Number>;
                }
            }
            _hrvSource = "mock";
            
            // Generate mock breathing (12-16 breaths/min with cycle phases)
            _mockBreathCycle = (_mockBreathCycle + 1) % 15;  // 15 samples = ~15 seconds breath cycle
            if (_mockBreathCycle < 4) {
                _currentBreathPhase = "inhale";
            } else if (_mockBreathCycle < 6) {
                _currentBreathPhase = "pause";  // Respiratory pause (good for shooting)
            } else if (_mockBreathCycle < 11) {
                _currentBreathPhase = "exhale";
            } else {
                _currentBreathPhase = "pause";  // Second pause
            }
            _currentBreathRate = 14.0 + (Math.rand() % 4).toFloat() - 2.0;
            _breathingSource = "mock";
        } else {
            // Try to get NATIVE Inter-Beat Intervals (IBI) for REAL HRV data
            // This is MUCH more accurate than estimating RR from HR!
            if (info has :heartBeatIntervals && info.heartBeatIntervals != null) {
                var ibis = info.heartBeatIntervals as Array<Number>;
                if (ibis.size() > 0) {
                    for (var i = 0; i < ibis.size(); i++) {
                        var ibi = ibis[i];
                        if (ibi > 200 && ibi < 2000) {  // Valid range: 30-300 BPM
                            _rrIntervals.add(ibi);
                        }
                    }
                    // Trim if too large
                    if (_rrIntervals.size() > 60) {
                        var startIdx = _rrIntervals.size() - 60;
                        _rrIntervals = _rrIntervals.slice(startIdx, _rrIntervals.size()) as Array<Number>;
                    }
                    _hasNativeIBI = true;
                    _hrvSource = "native";
                }
            }

            // Try native respiration sensor first (available on Fenix 6+, Venu 2+, etc.)
            var gotNativeBreathing = false;
            if (info has :respirationRate && info.respirationRate != null) {
                var nativeRate = info.respirationRate as Number;
                if (nativeRate > 0 && nativeRate < 60) {
                    _currentBreathRate = nativeRate.toFloat();
                    _hasNativeRespiration = true;
                    _breathingSource = "native";
                    gotNativeBreathing = true;
                    // Phase detection still uses HRV since native sensor doesn't provide it
                }
            }

            // Fall back to HRV-based estimation if no native sensor
            if (!gotNativeBreathing) {
                updateBreathingEstimate();
                if (_breathingSource.equals("none") && _currentBreathRate > 0) {
                    _breathingSource = "estimated";
                }
            }
        }

        // Add timeline sample every 3 seconds (for mobile app timeline chart)
        var now = System.getTimer();
        if (now - _lastTimelineSampleTime >= TIMELINE_SAMPLE_INTERVAL_MS) {
            _lastTimelineSampleTime = now;
            addTimelineSample();
        }
    }

    // Add a timeline sample for the chunked sync
    // Made public so we can add samples at start/stop of tracking
    function addTimelineSample() as Void {
        if (_timelineChunker == null) {
            System.println("[BIO] ❌ addTimelineSample - _timelineChunker is NULL!");
            return;
        }

        var sessionTime = System.getTimer() - _sessionStartTime;
        var stress = calculateHrvStress();
        var stressScore = stress[1] as Number;

        _timelineChunker.addSample(
            sessionTime,
            _currentHR,
            _currentBreathRate,
            stressScore
        );
        
        // Log every sample for debugging
        System.println("[BIO] Timeline sample #" + _timelineChunker.getPointCount() + " added (t=" + (sessionTime/1000) + "s, HR=" + _currentHR + ", stress=" + stressScore + ")");
    }
    
    // Record HR reading (called from timer or at shot moment)
    private function recordHeartRate(hr as Number, shotNumber as Number) as Void {
        var now = System.getTimer();
        var sessionTime = now - _sessionStartTime;
        
        _currentHR = hr;
        _lastHRTime = now;

        // Track start HR (first valid reading)
        if (_startHR == 0 && hr > 0) {
            _startHR = hr;
        }
        // Always update end HR to most recent valid reading
        if (hr > 0) {
            _endHR = hr;
        }
        
        // Add to timeline
        var sample = new HRSample(sessionTime, hr, shotNumber);
        _hrTimeline.add(sample);
        
        // Trim if too large
        if (_hrTimeline.size() > MAX_HR_SAMPLES) {
            var startIdx = _hrTimeline.size() - MAX_HR_SAMPLES;
            _hrTimeline = _hrTimeline.slice(startIdx, _hrTimeline.size()) as Array<HRSample>;
        }
        
        // Add to rolling buffer (for averages)
        _hrBuffer.add(hr);
        if (_hrBuffer.size() > 30) {  // Keep last 30 seconds
            var startIdx = _hrBuffer.size() - 30;
            _hrBuffer = _hrBuffer.slice(startIdx, _hrBuffer.size()) as Array<Number>;
        }
        
        // Update stats
        _hrSum += hr;
        _hrCount++;
        _avgHR = _hrSum.toFloat() / _hrCount;
        if (hr < _minHR) { _minHR = hr; }
        if (hr > _maxHR) { _maxHR = hr; }
        
        // Estimate R-R interval (ms between beats)
        if (hr > 0) {
            var rrInterval = (60000.0 / hr).toNumber();
            _rrIntervals.add(rrInterval);
            if (_rrIntervals.size() > 30) {
                var startIdx = _rrIntervals.size() - 30;
                _rrIntervals = _rrIntervals.slice(startIdx, _rrIntervals.size()) as Array<Number>;
            }
        }
    }
    
    // Update breathing rate estimate from HRV
    private function updateBreathingEstimate() as Void {
        if (_rrIntervals.size() < BREATH_WINDOW_SAMPLES) {
            return;
        }
        
        var now = System.getTimer();
        var sessionTime = now - _sessionStartTime;
        
        // Respiratory Sinus Arrhythmia (RSA): HR increases on inhale, decreases on exhale
        // We detect breathing by looking at HR oscillations
        
        // Get recent RR intervals
        var startIdx = _rrIntervals.size() - BREATH_WINDOW_SAMPLES;
        if (startIdx < 0) { startIdx = 0; }
        var recent = _rrIntervals.slice(startIdx, _rrIntervals.size()) as Array<Number>;
        
        // Calculate variance (indicator of HRV)
        var mean = 0.0;
        for (var i = 0; i < recent.size(); i++) {
            mean += recent[i];
        }
        mean = mean / recent.size();
        
        var variance = 0.0;
        for (var i = 0; i < recent.size(); i++) {
            var diff = recent[i] - mean;
            variance += (diff * diff);
        }
        variance = variance / recent.size();
        var rmssd = Math.sqrt(variance).toFloat();  // Root mean square of successive differences
        
        // Estimate breath rate from dominant oscillation frequency
        // Simplified: count zero crossings around mean
        var crossings = 0;
        var lastAbove = recent[0] > mean;
        for (var i = 1; i < recent.size(); i++) {
            var above = recent[i] > mean;
            if (above != lastAbove) {
                crossings++;
                lastAbove = above;
            }
        }
        
        // Each breathing cycle = 2 crossings (up and down)
        // Window is ~10 seconds, so scale to per-minute
        var windowSeconds = (BREATH_WINDOW_SAMPLES * HR_SAMPLE_INTERVAL_MS) / 1000.0;
        _currentBreathRate = ((crossings / 2.0) / windowSeconds * 60.0);
        
        // Clamp to realistic range (4-30 breaths/min)
        if (_currentBreathRate < 4.0) { _currentBreathRate = 4.0; }
        if (_currentBreathRate > 30.0) { _currentBreathRate = 30.0; }
        
        // Determine phase based on current HR trend (using RSA - Respiratory Sinus Arrhythmia)
        // Use percentage-based threshold relative to mean (works across all HR ranges)
        if (recent.size() >= 3) {
            var last3Avg = (recent[recent.size()-1] + recent[recent.size()-2] + recent[recent.size()-3]) / 3.0;
            
            // Use 2% of mean RR interval as threshold (more robust than fixed 10ms)
            var threshold = mean * 0.02;
            if (threshold < 5.0) { threshold = 5.0; }  // Minimum 5ms threshold
            
            if (last3Avg > mean + threshold) {
                _currentBreathPhase = "inhale";  // HR increasing = inhaling (RR intervals decreasing)
            } else if (last3Avg < mean - threshold) {
                _currentBreathPhase = "exhale";  // HR decreasing = exhaling (RR intervals increasing)
            } else {
                _currentBreathPhase = "pause";   // Stable = respiratory pause (ideal for shooting!)
            }
        }
        
        // Record breath sample
        var breathSample = new BreathSample(sessionTime, _currentBreathRate, _currentBreathPhase, 0);
        _breathTimeline.add(breathSample);
        
        if (_breathTimeline.size() > MAX_BREATH_SAMPLES) {
            var breathStartIdx = _breathTimeline.size() - MAX_BREATH_SAMPLES;
            _breathTimeline = _breathTimeline.slice(breathStartIdx, _breathTimeline.size()) as Array<BreathSample>;
        }
    }
    
    // Record biometrics at shot moment - call this from ShotDetector
    function recordShotBiometrics(shotNumber as Number) as ShotBiometrics {
        var bio = new ShotBiometrics();
        bio.shotNumber = shotNumber;
        bio.timestamp = System.getTimer() - _sessionStartTime;
        bio.heartRate = _currentHR;
        bio.breathRate = _currentBreathRate;
        bio.breathPhase = _currentBreathPhase;
        
        // Calculate 5-second average HR
        if (_hrBuffer.size() >= 5) {
            var sum = 0;
            var count = _hrBuffer.size() < 5 ? _hrBuffer.size() : 5;
            for (var i = _hrBuffer.size() - count; i < _hrBuffer.size(); i++) {
                sum += _hrBuffer[i];
            }
            bio.heartRateAvg5s = sum / count;
        } else {
            bio.heartRateAvg5s = _currentHR;
        }
        
        // Determine HR trend
        if (_hrBuffer.size() >= 3) {
            var recent = _hrBuffer[_hrBuffer.size() - 1];
            var older = _hrBuffer[_hrBuffer.size() - 3];
            if (recent > older + 3) {
                bio.hrTrend = "rising";
            } else if (recent < older - 3) {
                bio.hrTrend = "falling";
            } else {
                bio.hrTrend = "stable";
            }
        } else {
            bio.hrTrend = "stable";
        }
        
        // Calculate HRV stress score (RMSSD-based)
        var hrvResult = calculateHrvStress();
        bio.hrvRmssd = hrvResult[0] as Float;
        bio.stressScore = hrvResult[1] as Number;
        
        _shotBiometrics.add(bio);
        
        // Also mark this moment in HR timeline
        if (_currentHR > 0) {
            recordHeartRate(_currentHR, shotNumber);
        }
        
        // Mark in breath timeline
        var breathSample = new BreathSample(bio.timestamp, _currentBreathRate, _currentBreathPhase, shotNumber);
        _breathTimeline.add(breathSample);
        
        System.println("[BIO] Shot " + shotNumber + " - HR: " + bio.heartRate +
                      " (" + bio.hrTrend + "), Breath: " + bio.breathRate.format("%.1f") +
                      " bpm (" + bio.breathPhase + "), Stress: " + bio.stressScore);

        return bio;
    }

    // Record shot event for timeline (called after recordShotBiometrics with steadiness data)
    function recordShotForTimeline(
        shotNumber as Number,
        steadinessScore as Number,
        flinchDetected as Boolean,
        isHit as Boolean
    ) as Void {
        System.println("[BIO] recordShotForTimeline called - shot #" + shotNumber);
        
        if (_timelineChunker == null) {
            System.println("[BIO] ❌ _timelineChunker is NULL! Shot NOT recorded to timeline!");
            return;
        }
        
        if (_shotBiometrics.size() == 0) {
            System.println("[BIO] ❌ _shotBiometrics is empty! Shot NOT recorded to timeline!");
            return;
        }

        // Get the most recent shot biometrics
        var bio = _shotBiometrics[_shotBiometrics.size() - 1];
        var sessionTime = System.getTimer() - _sessionStartTime;

        _timelineChunker.addShotEvent(
            shotNumber,
            sessionTime,
            bio.heartRate,
            bio.breathRate,
            bio.breathPhase,
            bio.stressScore,
            steadinessScore,
            flinchDetected,
            isHit
        );

        System.println("[BIO] ✓ Shot " + shotNumber + " added to timeline (steadiness=" + steadinessScore + ", chunker shots=" + _timelineChunker.getShotCount() + ")");
    }
    
    // =========================================================================
    // HRV STRESS CALCULATION
    // RMSSD = Root Mean Square of Successive Differences
    // Lower RMSSD = Higher stress, Higher RMSSD = Lower stress (more relaxed)
    // =========================================================================
    private function calculateHrvStress() as Array {
        if (_rrIntervals.size() < 5) {
            return [0.0, 50];  // Not enough data, neutral stress
        }
        
        // Get recent R-R intervals (last 30 seconds)
        var intervals = _rrIntervals;
        if (_rrIntervals.size() > 30) {
            var intervalStartIdx = _rrIntervals.size() - 30;
            intervals = _rrIntervals.slice(intervalStartIdx, _rrIntervals.size()) as Array<Number>;
        }
        
        // Calculate RMSSD (Root Mean Square of Successive Differences)
        var sumSquaredDiffs = 0.0;
        var diffCount = 0;
        for (var i = 1; i < intervals.size(); i++) {
            var diff = intervals[i] - intervals[i-1];
            sumSquaredDiffs += (diff * diff).toFloat();
            diffCount++;
        }
        
        var rmssd = 0.0;
        if (diffCount > 0) {
            rmssd = Math.sqrt(sumSquaredDiffs / diffCount).toFloat();
        }
        
        // Convert RMSSD to stress score (0-100)
        // Higher RMSSD = more relaxed (lower stress)
        // Typical resting RMSSD: 20-60ms for adults
        // Competition stress might drop to 10-20ms
        // Very relaxed: 60-100ms+
        
        // Score calculation: 
        // RMSSD 80ms+ = stress 0-20 (very relaxed)
        // RMSSD 50ms = stress ~30 (calm)
        // RMSSD 30ms = stress ~50 (moderate)
        // RMSSD 15ms = stress ~75 (high stress)
        // RMSSD 5ms = stress 90+ (very high stress)
        
        var stressScore = 0;
        if (rmssd >= 80) {
            stressScore = 10;
        } else if (rmssd >= 50) {
            stressScore = 30 - ((rmssd - 50) / 30 * 20).toNumber();
        } else if (rmssd >= 30) {
            stressScore = 50 - ((rmssd - 30) / 20 * 20).toNumber();
        } else if (rmssd >= 15) {
            stressScore = 75 - ((rmssd - 15) / 15 * 25).toNumber();
        } else {
            stressScore = 90 + ((15 - rmssd) / 15 * 10).toNumber();
        }
        
        if (stressScore < 0) { stressScore = 0; }
        if (stressScore > 100) { stressScore = 100; }
        
        return [rmssd, stressScore];
    }
    
    // Get session stress stats
    function getStressStats() as Dictionary {
        var stresses = [] as Array<Number>;
        for (var i = 0; i < _shotBiometrics.size(); i++) {
            stresses.add(_shotBiometrics[i].stressScore);
        }
        
        if (stresses.size() == 0) {
            return {"avg" => 0, "min" => 0, "max" => 0, "trend" => "stable"};
        }
        
        var sum = 0;
        var minStress = 100;
        var maxStress = 0;
        for (var i = 0; i < stresses.size(); i++) {
            sum += stresses[i];
            if (stresses[i] < minStress) { minStress = stresses[i]; }
            if (stresses[i] > maxStress) { maxStress = stresses[i]; }
        }
        var avgStress = sum / stresses.size();
        
        // Trend
        var trend = "stable";
        if (stresses.size() >= 4) {
            var mid = stresses.size() / 2;
            var firstHalf = 0;
            for (var i = 0; i < mid; i++) { firstHalf += stresses[i]; }
            firstHalf = firstHalf / mid;
            
            var secondHalf = 0;
            for (var i = mid; i < stresses.size(); i++) { secondHalf += stresses[i]; }
            secondHalf = secondHalf / (stresses.size() - mid);
            
            if (secondHalf > firstHalf + 10) { trend = "increasing"; }
            else if (secondHalf < firstHalf - 10) { trend = "decreasing"; }
        }
        
        return {"avg" => avgStress, "min" => minStress, "max" => maxStress, "trend" => trend};
    }
    
    // Get current heart rate
    function getCurrentHR() as Number {
        return _currentHR;
    }
    
    // Get current breath rate
    function getCurrentBreathRate() as Float {
        return _currentBreathRate;
    }
    
    // Get current breath phase
    function getCurrentBreathPhase() as String {
        return _currentBreathPhase;
    }
    
    // Get breathing source ("native", "estimated", or "none")
    function getBreathingSource() as String {
        return _breathingSource;
    }
    
    // Check if device has native respiration sensor
    function hasNativeRespiration() as Boolean {
        return _hasNativeRespiration;
    }
    
    // Get HR timeline for charting (returns array of dictionaries)
    function getHRTimeline() as Array<Dictionary> {
        var result = [] as Array<Dictionary>;
        for (var i = 0; i < _hrTimeline.size(); i++) {
            result.add(_hrTimeline[i].toDict());
        }
        return result;
    }
    
    // Get breath timeline for charting
    function getBreathTimeline() as Array<Dictionary> {
        var result = [] as Array<Dictionary>;
        for (var i = 0; i < _breathTimeline.size(); i++) {
            result.add(_breathTimeline[i].toDict());
        }
        return result;
    }
    
    // Get all shot biometrics
    function getShotBiometrics() as Array<Dictionary> {
        var result = [] as Array<Dictionary>;
        for (var i = 0; i < _shotBiometrics.size(); i++) {
            result.add(_shotBiometrics[i].toDict());
        }
        return result;
    }
    
    // Get session summary
    function getSessionSummary() as Dictionary {
        var stressStats = getStressStats();
        
        // Count optimal shots (respiratory pause + stable HR + low stress)
        var optimalCount = 0;
        for (var i = 0; i < _shotBiometrics.size(); i++) {
            var bio = _shotBiometrics[i];
            var isOptimal = bio.breathPhase.equals("pause") && 
                           bio.hrTrend.equals("stable") && 
                           bio.stressScore < 50;
            if (isOptimal) { optimalCount++; }
        }
        var optimalPct = _shotBiometrics.size() > 0 ? 
            (optimalCount.toFloat() / _shotBiometrics.size() * 100).toNumber() : 0;
        
        return {
            "minHR" => _minHR == 999 ? 0 : _minHR,
            "maxHR" => _maxHR,
            "avgHR" => _avgHR.toNumber(),
            "startHR" => _startHR,                     // Protocol v2
            "endHR" => _endHR,                         // Protocol v2
            "avgBreathRate" => _currentBreathRate.toNumber(),
            "breathSource" => _breathingSource,        // "native", "estimated", or "none"
            "hrvSource" => _hrvSource,                 // "native" (IBI) or "estimated" (from HR)
            "bodyBattery" => _sessionStartBodyBattery, // Readiness at session start (-1 if unavailable)
            "hrSamples" => _hrTimeline.size(),
            "breathSamples" => _breathTimeline.size(),
            "shotCount" => _shotBiometrics.size(),
            "stressAvg" => stressStats.get("avg"),
            "stressMin" => stressStats.get("min"),
            "stressMax" => stressStats.get("max"),
            "stressTrend" => stressStats.get("trend"),
            "optimalShots" => optimalCount,
            "optimalPct" => optimalPct
        };
    }
    
    // Get HRV source ("native" or "estimated")
    function getHrvSource() as String {
        return _hrvSource;
    }
    
    // Get Body Battery at session start (-1 if not available)
    function getSessionStartBodyBattery() as Number {
        return _sessionStartBodyBattery;
    }
    
    // Get compact data for sending to phone (reduces payload size)
    function getCompactTimeline(maxPoints as Number) as Dictionary {
        // Downsample if too many points
        var hrData = [] as Array<Array<Number>>;
        var breathData = [] as Array<Array<Number>>;
        
        // HR: [timestamp, hr, shotNumber] arrays
        var hrStep = _hrTimeline.size() <= maxPoints ? 1 : (_hrTimeline.size() / maxPoints);
        for (var i = 0; i < _hrTimeline.size(); i += hrStep) {
            var s = _hrTimeline[i];
            hrData.add([s.timestamp, s.heartRate, s.shotNumber]);
        }
        
        // Breath: [timestamp, breathRate, shotNumber] arrays
        var brStep = _breathTimeline.size() <= maxPoints ? 1 : (_breathTimeline.size() / maxPoints);
        for (var i = 0; i < _breathTimeline.size(); i += brStep) {
            var s = _breathTimeline[i];
            breathData.add([s.timestamp, s.breathRate.toNumber(), s.shotNumber]);
        }
        
        return {
            "hr" => hrData,
            "breath" => breathData,
            "shots" => getShotBiometrics()
        };
    }
    
    // Reset for new session
    function reset() as Void {
        _hrTimeline = [];
        _hrBuffer = [];
        _breathTimeline = [];
        _rrIntervals = [];
        _shotBiometrics = [];
        _minHR = 999;
        _maxHR = 0;
        _avgHR = 0.0;
        _hrSum = 0;
        _hrCount = 0;
        _startHR = 0;                 // Protocol v2
        _endHR = 0;                   // Protocol v2
        _currentHR = 0;
        _currentBreathRate = 0.0;
        _currentBreathPhase = "unknown";
        _hasNativeRespiration = false;
        _breathingSource = "none";
        _lastTimelineSampleTime = 0;
        if (_timelineChunker != null) {
            _timelineChunker.reset("");
        }
    }

    // Get timeline chunker for sync
    function getTimelineChunker() as TimelineChunker? {
        return _timelineChunker;
    }
    
    // Check if tracking
    function isTracking() as Boolean {
        return _isTracking;
    }
}
