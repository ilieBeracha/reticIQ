import Toybox.Lang;
import Toybox.System;
import Toybox.Sensor;
import Toybox.Timer;
import Toybox.Attention;
import Toybox.Math;
import Toybox.Application;

// Sensitivity presets (in G-force) - Legacy, kept for backwards compatibility
enum ShotSensitivity {
    SENSITIVITY_LOW = 0,    // 4.5G - Less sensitive, fewer false positives
    SENSITIVITY_MEDIUM = 1, // 3.5G - Default, balanced
    SENSITIVITY_HIGH = 2    // 2.5G - More sensitive, may have false positives
}

// Weapon profile types - affects detection behavior
// Profile-specific impulse duration and validation
enum WeaponProfile {
    PROFILE_HANDGUN = 0,    // 30ms impulse, 60ms cooldown
    PROFILE_RIFLE = 1,      // 50ms impulse, 80ms cooldown  
    PROFILE_SHOTGUN = 2     // 80ms impulse, 120ms cooldown
}

// Detection config structure (from phone SESSION_START)
class DetectionConfig {
    var sensitivity as Float = 3.5;      // Primary G-force threshold
    var minThreshold as Float = 1.6;     // Reject peaks below this (false positive rejection)
    var maxThreshold as Float = 9.6;     // Expected max peak for normalization
    var cooldownMs as Number = 80;       // Minimum time between detected shots
    var profile as WeaponProfile = PROFILE_HANDGUN;
    
    function initialize() {}
    
    // Create from dictionary (from phone payload)
    static function fromDict(dict as Dictionary?) as DetectionConfig {
        var config = new DetectionConfig();
        
        if (dict == null) {
            System.println("[CONFIG] fromDict: dict is NULL!");
            return config;
        }
        
        System.println("[CONFIG] fromDict: Parsing detection dictionary...");
        
        // Parse sensitivity (JSON may send Double, Float, or Number)
        if (dict.get("sensitivity") != null) {
            var v = dict.get("sensitivity");
            System.println("[CONFIG] sensitivity raw value: " + v + " (type check: Float=" + (v instanceof Float) + ", Double=" + (v instanceof Double) + ", Number=" + (v instanceof Number) + ")");
            if (v instanceof Float) {
                config.sensitivity = v;
            } else if (v instanceof Double) {
                config.sensitivity = v.toFloat();
            } else if (v instanceof Number) {
                config.sensitivity = v.toFloat();
            }
            System.println("[CONFIG] sensitivity parsed: " + config.sensitivity);
        } else {
            System.println("[CONFIG] sensitivity key NOT found in dict!");
        }
        
        // Parse minThreshold
        if (dict.get("minThreshold") != null) {
            var v = dict.get("minThreshold");
            if (v instanceof Float) {
                config.minThreshold = v;
            } else if (v instanceof Double) {
                config.minThreshold = v.toFloat();
            } else if (v instanceof Number) {
                config.minThreshold = v.toFloat();
            }
        }
        
        // Parse maxThreshold
        if (dict.get("maxThreshold") != null) {
            var v = dict.get("maxThreshold");
            if (v instanceof Float) {
                config.maxThreshold = v;
            } else if (v instanceof Double) {
                config.maxThreshold = v.toFloat();
            } else if (v instanceof Number) {
                config.maxThreshold = v.toFloat();
            }
        }
        
        // Parse cooldownMs (may come as Double from JSON)
        if (dict.get("cooldownMs") != null) {
            var v = dict.get("cooldownMs");
            if (v instanceof Number) {
                config.cooldownMs = v;
            } else if (v instanceof Double) {
                config.cooldownMs = v.toNumber();
            } else if (v instanceof Float) {
                config.cooldownMs = v.toNumber();
            }
        }
        
        // Parse profile
        if (dict.get("profile") != null) {
            var v = dict.get("profile");
            if (v instanceof String) {
                var profileStr = v as String;
                if (profileStr.equals("rifle")) {
                    config.profile = PROFILE_RIFLE;
                } else if (profileStr.equals("shotgun")) {
                    config.profile = PROFILE_SHOTGUN;
                } else {
                    config.profile = PROFILE_HANDGUN;
                }
            } else if (v instanceof Number) {
                config.profile = v as WeaponProfile;
            }
        }
        
        // Derive minThreshold from sensitivity if not provided (50% rule)
        if (dict.get("minThreshold") == null && dict.get("sensitivity") != null) {
            config.minThreshold = config.sensitivity * 0.5;
        }
        
        // Derive maxThreshold from sensitivity if not provided (3x rule)
        if (dict.get("maxThreshold") == null && dict.get("sensitivity") != null) {
            config.maxThreshold = config.sensitivity * 3.0;
        }
        
        // SAFETY: Clamp sensitivity to reasonable range to prevent crashes
        // Values below 1.0G cause constant false positives, above 10.0G misses most shots
        if (config.sensitivity < 1.0) {
            System.println("[CONFIG] ⚠️ Clamping sensitivity from " + config.sensitivity + " to 1.0G (minimum)");
            config.sensitivity = 1.0;
            config.minThreshold = 0.5;
            config.maxThreshold = 3.0;
        } else if (config.sensitivity > 10.0) {
            System.println("[CONFIG] ⚠️ Clamping sensitivity from " + config.sensitivity + " to 10.0G (maximum)");
            config.sensitivity = 10.0;
            config.minThreshold = 5.0;
            config.maxThreshold = 30.0;
        }
        
        // Ensure minThreshold is at least 0.5G to avoid constant triggering
        if (config.minThreshold < 0.5) {
            config.minThreshold = 0.5;
        }
        
        return config;
    }
    
    // Get profile-specific cooldown (can override config value)
    function getEffectiveCooldown() as Number {
        // Use configured cooldown, or fall back to profile defaults
        if (cooldownMs > 0) {
            return cooldownMs;
        }
        
        switch (profile) {
            case PROFILE_RIFLE:
                return 80;
            case PROFILE_SHOTGUN:
                return 120;
            case PROFILE_HANDGUN:
            default:
                return 60;
        }
    }
    
    // Get minimum vertical ratio for shot validation based on profile
    function getMinVerticalRatio() as Float {
        switch (profile) {
            case PROFILE_SHOTGUN:
                return 0.35;  // Shotgun has more horizontal spread
            case PROFILE_RIFLE:
                return 0.4;
            case PROFILE_HANDGUN:
            default:
                return 0.45;  // Handgun recoil is mostly vertical
        }
    }
    
    function toString() as String {
        return "DetectionConfig{sens=" + sensitivity.format("%.1f") + 
               ", min=" + minThreshold.format("%.1f") +
               ", max=" + maxThreshold.format("%.1f") +
               ", cd=" + cooldownMs + "ms}";
    }
}

// Callback interface for shot detection - now includes steadiness result
typedef ShotCallback as Method() as Void;
typedef ShotCallbackWithSteadiness as Method(steadiness as SteadinessResult) as Void;

class ShotDetector {
    // Detection config (from phone or defaults)
    private var _config as DetectionConfig;
    
    // Legacy parameters (for backwards compat)
    private var _threshold as Float = 3.5;      // G-force threshold (maps to _config.sensitivity)
    private var _cooldownMs as Number = 200;    // Minimum ms between shots
    private var _enabled as Boolean = true;     // Enabled by default
    private var _calibrating as Boolean = false;
    
    // Extra feature flags
    private var _emkv as Boolean = false;       // Extra mark/flag behavior (user toggle)
    private var _vrcv as Boolean = true;        // Vibrate on receive/shot
    
    // State tracking
    private var _lastShotTime as Number = 0;
    private var _isMonitoring as Boolean = false;
    
    // Adaptive threshold system
    private var _adaptiveThreshold as Float = 3.5;  // Learned from actual shots
    private var _recentPeaks as Array<Float> = [];  // Last 5 detected peak magnitudes
    private const MAX_RECENT_PEAKS = 5;
    
    // Rise time tracking for shot signature validation
    private var _previousMagnitudes as Array<Float> = [];  // Last few magnitudes for rise time calc
    private const RISE_TIME_SAMPLES = 3;  // Number of samples to track
    
    // Calibration data
    private var _calibrationPeaks as Array<Float> = [];
    private var _calibrationTimer as Timer.Timer?;
    private var _calibrationCallback as Method(threshold as Float) as Void?;
    
    // Shot callbacks (basic and with steadiness)
    private var _onShotDetected as ShotCallback?;
    private var _onShotWithSteadiness as ShotCallbackWithSteadiness?;
    
    // Steadiness analyzer
    private var _steadinessAnalyzer as SteadinessAnalyzer;
    private var _lastSteadinessResult as SteadinessResult?;
    
    // Biometrics tracker (HR, breathing)
    private var _biometricsTracker as BiometricsTracker;
    private var _lastShotBiometrics as ShotBiometrics?;
    
    // Debug/stats
    private var _totalDetections as Number = 0;
    private var _lastMagnitude as Float = 0.0;
    private var _rejectedLowCount as Number = 0;    // Count of peaks below minThreshold
    private var _rejectedVerticalCount as Number = 0;  // Count of non-vertical movements

    // Optional diagnostic counters
    private var _markedShots as Number = 0;
    
    function initialize() {
        // Initialize default config
        _config = new DetectionConfig();
        
        // Load saved threshold from storage if available
        loadSettings();
        
        // Initialize adaptive threshold from config
        _adaptiveThreshold = _config.sensitivity;
        _recentPeaks = [];
        _previousMagnitudes = [];
        
        // Initialize steadiness analyzer
        _steadinessAnalyzer = new SteadinessAnalyzer();
        // Initialize biometrics tracker
        _biometricsTracker = new BiometricsTracker();
    }
    
    // =========================================================================
    // PUBLIC API
    // =========================================================================
    
    // Set the callback function to call when a shot is detected
    function setOnShotDetected(callback as ShotCallback) as Void {
        _onShotDetected = callback;
    }
    
    // Set callback that receives steadiness analysis with each shot
    function setOnShotWithSteadiness(callback as ShotCallbackWithSteadiness) as Void {
        _onShotWithSteadiness = callback;
    }
    
    // Get the steadiness analyzer for external access
    function getSteadinessAnalyzer() as SteadinessAnalyzer {
        return _steadinessAnalyzer;
    }
    
    // Get last steadiness result
    function getLastSteadinessResult() as SteadinessResult? {
        return _lastSteadinessResult;
    }
    
    // Get the biometrics tracker for external access
    function getBiometricsTracker() as BiometricsTracker {
        return _biometricsTracker;
    }
    
    // Get last shot biometrics
    function getLastShotBiometrics() as ShotBiometrics? {
        return _lastShotBiometrics;
    }
    
    // Configure detection from phone payload (new API)
    function setDetectionConfig(config as DetectionConfig) as Void {
        _config = config;
        
        // Sync legacy fields for compatibility
        _threshold = config.sensitivity;
        _cooldownMs = config.getEffectiveCooldown();
        
        // Reset adaptive threshold to new sensitivity
        _adaptiveThreshold = config.sensitivity;
        _recentPeaks = [];
        
        System.println("[SHOT] Detection config updated: " + config.toString());
    }
    
    // Configure from dictionary (convenience method for phone payloads)
    function configureFromDict(dict as Dictionary?) as Void {
        if (dict != null) {
            var config = DetectionConfig.fromDict(dict);
            setDetectionConfig(config);
        }
    }
    
    // Get current detection config
    function getDetectionConfig() as DetectionConfig {
        return _config;
    }
    
    // Start monitoring accelerometer for shots
    function startMonitoring(sessionId as String) as Void {
        if (_isMonitoring) {
            System.println("[SHOT] Already monitoring, skipping start");
            return;
        }

        System.println("[SHOT] === STARTING MONITORING ===");
        System.println("[SHOT] Config: " + _config.toString());

        try {
            // Enable sensor events callback - accel data comes through Info.accel
            Sensor.enableSensorEvents(method(:onSensorData));
            _isMonitoring = true;
            _lastShotTime = 0;
            
            // Reset adaptive threshold state
            _adaptiveThreshold = _config.sensitivity;
            _recentPeaks = [];
            _previousMagnitudes = [];
            _rejectedLowCount = 0;
            _rejectedVerticalCount = 0;

            // Start biometrics tracking (HR, breathing) with session ID for timeline
            _biometricsTracker.startTracking(sessionId);

            System.println("[SHOT] ✓ Sensor events ENABLED");
            System.println("[SHOT]   Threshold: " + _config.sensitivity + "G");
            System.println("[SHOT]   MinThreshold: " + _config.minThreshold + "G");
            System.println("[SHOT]   Cooldown: " + _config.getEffectiveCooldown() + "ms");
        } catch (ex) {
            System.println("[SHOT] ✗ FAILED to enable sensor events");
        }
    }
    
    // Stop monitoring accelerometer
    function stopMonitoring() as Void {
        if (!_isMonitoring) {
            return;
        }
        
        try {
            // Pass null to disable sensor events
            Sensor.enableSensorEvents(null);
            _isMonitoring = false;
            
            // Stop biometrics tracking
            _biometricsTracker.stopTracking();
            
            System.println("[SHOT] Accelerometer monitoring stopped");
            System.println("[SHOT]   Total detections: " + _totalDetections);
            System.println("[SHOT]   Rejected (low): " + _rejectedLowCount);
            System.println("[SHOT]   Rejected (vertical): " + _rejectedVerticalCount);
            System.println("[SHOT]   Final adaptive threshold: " + _adaptiveThreshold.format("%.2f") + "G");
        } catch (ex) {
            System.println("[SHOT] Failed to disable sensor events");
        }
    }
    
    // Check if currently monitoring
    function isMonitoring() as Boolean {
        return _isMonitoring;
    }
    
    // Enable/disable shot detection
    function setEnabled(enabled as Boolean) as Void {
        _enabled = enabled;
        if (!enabled && _isMonitoring) {
            stopMonitoring();
        }
    }
    
    function isEnabled() as Boolean {
        return _enabled;
    }
    
    // Set sensitivity preset (legacy API)
    function setSensitivity(sensitivity as ShotSensitivity) as Void {
        switch (sensitivity) {
            case SENSITIVITY_LOW:
                _threshold = 4.5;
                break;
            case SENSITIVITY_HIGH:
                _threshold = 2.5;
                break;
            case SENSITIVITY_MEDIUM:
            default:
                _threshold = 3.5;
                break;
        }
        
        // Update config to match
        _config.sensitivity = _threshold;
        _config.minThreshold = _threshold * 0.5;
        _config.maxThreshold = _threshold * 3.0;
        _adaptiveThreshold = _threshold;
        
        saveSettings();
        System.println("[SHOT] Sensitivity preset set to: " + _threshold + "G");
    }
    
    // Set custom threshold directly (legacy API)
    function setThreshold(threshold as Float) as Void {
        _threshold = threshold;
        
        // Update config to match
        _config.sensitivity = threshold;
        _config.minThreshold = threshold * 0.5;
        _config.maxThreshold = threshold * 3.0;
        _adaptiveThreshold = threshold;
        
        saveSettings();
        System.println("[SHOT] Threshold set to: " + threshold + "G");
    }
    
    function getThreshold() as Float {
        return _config.sensitivity;
    }
    
    // Get adaptive threshold (for debugging/display)
    function getAdaptiveThreshold() as Float {
        return _adaptiveThreshold;
    }
    
    // Set cooldown period (legacy API)
    function setCooldown(ms as Number) as Void {
        _cooldownMs = ms;
        _config.cooldownMs = ms;
    }
    
    // Get last detected magnitude (for debug display)
    function getLastMagnitude() as Float {
        return _lastMagnitude;
    }
    
    // Get total detections this session
    function getTotalDetections() as Number {
        return _totalDetections;
    }
    
    // Reset detection counter and steadiness data for new session
    function resetDetections() as Void {
        _totalDetections = 0;
        _lastShotTime = 0;
        _lastSteadinessResult = null;
        _lastShotBiometrics = null;
        _steadinessAnalyzer.resetSession();
        _biometricsTracker.reset();
        
        // Reset adaptive threshold
        _adaptiveThreshold = _config.sensitivity;
        _recentPeaks = [];
        _previousMagnitudes = [];
        _rejectedLowCount = 0;
        _rejectedVerticalCount = 0;
    }
    
    // DEBUG: Manually trigger a shot detection (for simulator testing)
    // This bypasses the enabled check for easier testing
    function simulateShot() as Void {
        if (_calibrating) {
            System.println("[SHOT] Cannot simulate - calibrating");
            return;
        }
        
        var now = System.getTimer();
        var timeSinceLastShot = now - _lastShotTime;
        
        System.println("[SHOT] simulateShot called - enabled: " + _enabled + ", callback set: " + (_onShotDetected != null));
        
        if (timeSinceLastShot >= _config.getEffectiveCooldown()) {
            _lastShotTime = now;
            _totalDetections++;
            _lastMagnitude = _config.sensitivity + 0.5;  // Fake magnitude above threshold
            
            // Analyze pre-shot steadiness (may have limited data in simulator)
            _lastSteadinessResult = _steadinessAnalyzer.analyzeShot(now, _totalDetections);

            // Record biometrics at shot moment
            _lastShotBiometrics = _biometricsTracker.recordShotBiometrics(_totalDetections);

            // Record to timeline for chunked sync (includes HR, breath, steadiness, etc.)
            _biometricsTracker.recordShotForTimeline(
                _totalDetections,
                _lastSteadinessResult.steadinessScore.toNumber(),
                _lastSteadinessResult.flinchDetected,
                false  // isHit - unknown for simulated shots
            );

            System.println("[SHOT] SIMULATED shot! Total: " + _totalDetections +
                          ", Steadiness: " + _lastSteadinessResult.gradeString);
            
            // Trigger callbacks
            if (_onShotWithSteadiness != null && _lastSteadinessResult != null) {
                _onShotWithSteadiness.invoke(_lastSteadinessResult);
            }
            if (_onShotDetected != null) {
                _onShotDetected.invoke();
            } else {
                System.println("[SHOT] WARNING: No callback registered!");
            }

            // EMKV: optional marking behavior for shots
            if (_emkv) {
                _markedShots++;
                System.println("[SHOT] EMKV: marked shot #" + _markedShots);
            }

            // VRCV: vibrate on receive if enabled
            if (_vrcv && (Attention has :vibrate)) {
                var vibeData = [
                    new Attention.VibeProfile(75, 50)
                ];
                Attention.vibrate(vibeData);
            }
        } else {
            System.println("[SHOT] Cooldown active, wait " + (_config.getEffectiveCooldown() - timeSinceLastShot) + "ms");
        }
    }
    
    // =========================================================================
    // CALIBRATION
    // =========================================================================
    
    // Start calibration mode - records peaks for 5 seconds
    function startCalibration(callback as Method(threshold as Float) as Void) as Void {
        if (_calibrating) {
            return;
        }
        
        _calibrating = true;
        _calibrationPeaks = [];
        _calibrationCallback = callback;

        // Make sure accelerometer is running
        if (!_isMonitoring) {
            startMonitoring("CALIBRATION");
        }
        
        // Set timer to end calibration after 5 seconds
        _calibrationTimer = new Timer.Timer();
        _calibrationTimer.start(method(:onCalibrationEnd), 5000, false);
        
        System.println("[SHOT] Calibration started - fire one shot within 5 seconds");
    }
    
    // Called when calibration period ends
    function onCalibrationEnd() as Void {
        _calibrating = false;
        
        if (_calibrationPeaks.size() > 0) {
            // Find the maximum peak
            var maxPeak = 0.0;
            for (var i = 0; i < _calibrationPeaks.size(); i++) {
                if (_calibrationPeaks[i] > maxPeak) {
                    maxPeak = _calibrationPeaks[i];
                }
            }
            
            // Set threshold to 70% of peak (allows for variation)
            var newThreshold = maxPeak * 0.7;
            
            // Clamp to reasonable range
            if (newThreshold < 1.5) { newThreshold = 1.5; }
            if (newThreshold > 10.0) { newThreshold = 10.0; }
            
            // Update both legacy and new config
            _threshold = newThreshold;
            _config.sensitivity = newThreshold;
            _config.minThreshold = newThreshold * 0.5;
            _config.maxThreshold = maxPeak * 1.2;
            _adaptiveThreshold = newThreshold;
            
            saveSettings();
            
            System.println("[SHOT] Calibration complete. Peak: " + maxPeak + "G, New threshold: " + _threshold + "G");
            
            if (_calibrationCallback != null) {
                _calibrationCallback.invoke(_threshold);
            }
        } else {
            System.println("[SHOT] Calibration failed - no significant peaks detected");
            if (_calibrationCallback != null) {
                _calibrationCallback.invoke(-1.0);  // Indicate failure
            }
        }
        
        _calibrationCallback = null;
    }
    
    // Cancel calibration in progress
    function cancelCalibration() as Void {
        if (_calibrating) {
            _calibrating = false;
            if (_calibrationTimer != null) {
                _calibrationTimer.stop();
                _calibrationTimer = null;
            }
            _calibrationCallback = null;
            System.println("[SHOT] Calibration cancelled");
        }
    }
    
    // =========================================================================
    // SENSOR CALLBACK - Enhanced with adaptive threshold and signature validation
    // =========================================================================
    
    // Called when new accelerometer data is available
    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.accel == null) {
            // First few calls might be null - that's OK, but log it occasionally
            return;
        }
        
        // Get acceleration values (in milli-G)
        var accel = sensorInfo.accel;
        var x = accel[0].toFloat() / 1000.0;  // Convert to G
        var y = accel[1].toFloat() / 1000.0;
        var z = accel[2].toFloat() / 1000.0;
        
        // Always feed samples to steadiness analyzer (buffering for analysis)
        _steadinessAnalyzer.addSample(x, y, z);
        
        // Calculate magnitude: sqrt(x² + y² + z²)
        var magnitudeSq = (x * x) + (y * y) + (z * z);
        var magnitude = Math.sqrt(magnitudeSq).toFloat();
        
        // Subtract baseline gravity (~1G) to get delta
        var delta = magnitude - 1.0;
        if (delta < 0) {
            delta = -delta;  // abs()
        }
        _lastMagnitude = delta;
        
        // Track previous magnitudes for rise time calculation
        _previousMagnitudes.add(delta);
        if (_previousMagnitudes.size() > RISE_TIME_SAMPLES) {
            var newMags = [] as Array<Float>;
            var startIdx = _previousMagnitudes.size() - RISE_TIME_SAMPLES;
            for (var i = startIdx; i < _previousMagnitudes.size(); i++) {
                newMags.add(_previousMagnitudes[i]);
            }
            _previousMagnitudes = newMags;
        }
        
        // During calibration, record peaks above 1.5G
        if (_calibrating && delta > 1.5) {
            _calibrationPeaks.add(delta);
            return;  // Don't trigger shots during calibration
        }
        
        // Check if detection is enabled
        if (!_enabled) {
            return;
        }
        
        var now = System.getTimer();
        var timeSinceLastShot = now - _lastShotTime;
        var effectiveCooldown = _config.getEffectiveCooldown();
        
        // 1. Cooldown check - prevent double-counting
        if (timeSinceLastShot < effectiveCooldown) {
            return;
        }
        
        // 2. Below minimum threshold - definitely not a shot (false positive rejection)
        if (delta < _config.minThreshold) {
            return;
        }
        
        // 3. Detection check against adaptive threshold
        if (delta >= _adaptiveThreshold) {
            // 4. Validate shot signature
            if (!validateShotSignature(x, y, z, delta)) {
                _rejectedVerticalCount++;
                return;
            }
            
            // Shot detected!
            _lastShotTime = now;
            _totalDetections++;
            
            // 5. Record peak for adaptive threshold learning
            _recentPeaks.add(delta);
            if (_recentPeaks.size() > MAX_RECENT_PEAKS) {
                var newPeaks = [] as Array<Float>;
                var startIdx = _recentPeaks.size() - MAX_RECENT_PEAKS;
                for (var i = startIdx; i < _recentPeaks.size(); i++) {
                    newPeaks.add(_recentPeaks[i]);
                }
                _recentPeaks = newPeaks;
            }
            
            // 6. Update adaptive threshold based on actual shots
            updateAdaptiveThreshold();
            
            // Analyze pre-shot steadiness
            _lastSteadinessResult = _steadinessAnalyzer.analyzeShot(now, _totalDetections);

            // Record biometrics at shot moment (HR, breathing)
            _lastShotBiometrics = _biometricsTracker.recordShotBiometrics(_totalDetections);

            // Record to timeline for chunked sync (includes HR, breath, steadiness, etc.)
            _biometricsTracker.recordShotForTimeline(
                _totalDetections,
                _lastSteadinessResult.steadinessScore.toNumber(),
                _lastSteadinessResult.flinchDetected,
                false  // isHit - will be updated by view if known
            );

            System.println("[SHOT] Detected! Mag: " + delta.format("%.2f") + "G, Adaptive: " + 
                          _adaptiveThreshold.format("%.2f") + "G, Total: " + _totalDetections +
                          ", Steady: " + _lastSteadinessResult.gradeString);
            
            // Trigger callbacks
            if (_onShotWithSteadiness != null && _lastSteadinessResult != null) {
                _onShotWithSteadiness.invoke(_lastSteadinessResult);
            }
            if (_onShotDetected != null) {
                _onShotDetected.invoke();
            }
            
            // VRCV: only vibrate when enabled by setting
            if (_vrcv && (Attention has :vibrate)) {
                var vibeData = [
                    new Attention.VibeProfile(75, 50)  // Short 50ms pulse
                ];
                Attention.vibrate(vibeData);
            }
        }
    }
    
    // =========================================================================
    // SHOT SIGNATURE VALIDATION
    // Real shots have specific characteristics that differentiate them from arm movement
    // =========================================================================
    
    private function validateShotSignature(x as Float, y as Float, z as Float, magnitude as Float) as Boolean {
        // RELAXED VALIDATION - previous version was too strict and rejected real shots
        // 
        // The problem: watch orientation varies greatly based on grip, stance, etc.
        // We can't reliably assume which axis the recoil will be on.
        //
        // For now, just do a basic sanity check that there's SOME directional component
        // (not just noise across all axes equally)
        
        // 1. Check that at least one axis dominates (not equal noise)
        var absX = (x < 0) ? -x : x;
        var absY = (y < 0) ? -y : y;
        var absZ = (z < 0) ? -z : z;
        
        // Find the dominant axis
        var maxAxis = absX;
        if (absY > maxAxis) { maxAxis = absY; }
        if (absZ > maxAxis) { maxAxis = absZ; }
        
        // The dominant axis should be at least 30% of total magnitude
        // This is MUCH more relaxed than before (was 40-45%)
        var dominantRatio = 0.0;
        if (magnitude > 0) {
            dominantRatio = maxAxis / magnitude;
        }
        
        if (dominantRatio < 0.25) {
            // All axes equally noisy - probably not a real impulse
            System.println("[SHOT] Rejected: no dominant axis (ratio=" + dominantRatio.format("%.2f") + ")");
            return false;
        }
        
        // 2. Rise time check - RELAXED
        // Only reject if it's VERY gradual (walking, etc.)
        if (_previousMagnitudes.size() >= 2) {
            var previousMag = _previousMagnitudes[_previousMagnitudes.size() - 2];
            var riseRatio = 0.0;
            if (previousMag > 0.2) {
                riseRatio = magnitude / previousMag;
            } else {
                // Previous was very low, this is definitely a spike
                riseRatio = 10.0;
            }
            
            // Only reject if rise is VERY gradual (< 1.2x means almost no change)
            // Real shots are typically 2-10x, but some light recoil might be 1.3-2x
            if (riseRatio < 1.2) {
                System.println("[SHOT] Rejected: gradual rise (ratio=" + riseRatio.format("%.2f") + ")");
                return false;
            }
        }
        
        return true;
    }
    
    // =========================================================================
    // ADAPTIVE THRESHOLD LEARNING
    // Adjusts detection threshold based on actual shot data
    // =========================================================================
    
    private function updateAdaptiveThreshold() as Void {
        // Need at least 2 shots to adapt
        if (_recentPeaks.size() < 2) {
            return;
        }
        
        // Calculate median of recent peaks (more robust than average)
        var sorted = [] as Array<Float>;
        for (var i = 0; i < _recentPeaks.size(); i++) {
            sorted.add(_recentPeaks[i]);
        }
        
        // Simple bubble sort (array is small)
        for (var i = 0; i < sorted.size() - 1; i++) {
            for (var j = 0; j < sorted.size() - 1 - i; j++) {
                if (sorted[j] > sorted[j + 1]) {
                    var temp = sorted[j];
                    sorted[j] = sorted[j + 1];
                    sorted[j + 1] = temp;
                }
            }
        }
        
        var median = sorted[sorted.size() / 2];
        
        // Set threshold at 60% of median (allows for shot variation)
        var newThreshold = median * 0.6;
        
        // Clamp to reasonable range based on config
        if (newThreshold < _config.minThreshold) {
            newThreshold = _config.minThreshold;
        }
        if (newThreshold > _config.sensitivity * 1.5) {
            newThreshold = _config.sensitivity * 1.5;
        }
        
        // Smooth transition (don't jump too quickly)
        _adaptiveThreshold = (_adaptiveThreshold * 0.7) + (newThreshold * 0.3);
        
        System.println("[SHOT] Adaptive threshold: " + _adaptiveThreshold.format("%.2f") + 
                      "G (median: " + median.format("%.2f") + "G, samples: " + _recentPeaks.size() + ")");
    }
    
    // =========================================================================
    // PERSISTENCE
    // =========================================================================
    
    // Load settings from storage
    private function loadSettings() as Void {
        try {
            var app = Application.getApp();
            var savedThreshold = app.getProperty("shotThreshold");
            if (savedThreshold != null && savedThreshold instanceof Float) {
                _threshold = savedThreshold;
                _config.sensitivity = savedThreshold;
            } else if (savedThreshold != null && savedThreshold instanceof Number) {
                _threshold = savedThreshold.toFloat();
                _config.sensitivity = _threshold;
            }
            var savedEnabled = app.getProperty("autoDetectEnabled");
            if (savedEnabled != null && savedEnabled instanceof Boolean) {
                _enabled = savedEnabled;
            }
            var savedEmkv = app.getProperty("emkvEnabled");
            if (savedEmkv != null && savedEmkv instanceof Boolean) {
                _emkv = savedEmkv;
            }
            var savedVrcv = app.getProperty("vrcvEnabled");
            if (savedVrcv != null && savedVrcv instanceof Boolean) {
                _vrcv = savedVrcv;
            }
            
            // Update derived config values
            _config.minThreshold = _config.sensitivity * 0.5;
            _config.maxThreshold = _config.sensitivity * 3.0;
            _adaptiveThreshold = _config.sensitivity;
        } catch (ex) {
            // Use defaults
        }
    }
    
    // Save settings to storage
    private function saveSettings() as Void {
        try {
            var app = Application.getApp();
            app.setProperty("shotThreshold", _threshold);
            app.setProperty("autoDetectEnabled", _enabled);
            app.setProperty("emkvEnabled", _emkv);
            app.setProperty("vrcvEnabled", _vrcv);
        } catch (ex) {
            System.println("[SHOT] Failed to save settings: " + ex.getErrorMessage());
        }
    }

    // =========================================================================
    // EMKV / VRCV API
    // =========================================================================

    function setEmkv(enabled as Boolean) as Void {
        _emkv = enabled;
        saveSettings();
        System.println("[SHOT] EMKV set to: " + _emkv);
    }

    function isEmkv() as Boolean {
        return _emkv;
    }

    function setVrcv(enabled as Boolean) as Void {
        _vrcv = enabled;
        saveSettings();
        System.println("[SHOT] VRCV (vibrate) set to: " + _vrcv);
    }

    function isVrcv() as Boolean {
        return _vrcv;
    }
}
