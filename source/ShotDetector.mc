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
    var cooldownMs as Number = 250;      // Minimum ms between shots (prevents double-detection)
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
    // INCREASED: Short cooldowns caused double-detection on hand motions
    // Real firearms have ~200-500ms between shots minimum anyway
    function getEffectiveCooldown() as Number {
        // Use configured cooldown, or fall back to profile defaults
        if (cooldownMs > 0) {
            return cooldownMs;
        }
        
        switch (profile) {
            case PROFILE_RIFLE:
                return 300;   // Was 80ms - bolt action needs more time
            case PROFILE_SHOTGUN:
                return 400;   // Was 120ms - pump action needs more time
            case PROFILE_HANDGUN:
            default:
                return 250;   // Was 60ms - double-taps are ~200ms minimum
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
    private var _cooldownMs as Number = 250;    // Minimum ms between shots (prevents double-detection)
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
    private var _recentPeaks as Array<Float>;       // Circular buffer for peak magnitudes
    private var _recentPeaksIdx as Number = 0;      // Current write index
    private var _recentPeaksCount as Number = 0;    // Number of valid entries
    private const MAX_RECENT_PEAKS = 5;
    
    // Magnitude tracking (circular buffer)
    private var _previousMagnitudes as Array<Float>;  // Circular buffer for recent magnitudes
    private var _prevMagIdx as Number = 0;            // Current write index
    private var _prevMagCount as Number = 0;          // Number of valid entries
    private const MAGNITUDE_BUFFER_SIZE = 10;         // Larger buffer for pattern analysis
    
    // Rolling baseline (instead of hardcoded 1.0G)
    private var _baselineMagnitude as Float = 1.0;
    private const BASELINE_ALPHA as Float = 0.02;  // Slow adaptation rate
    
    // Pre-allocated scratch buffer for sorting (zero allocation during runtime)
    private var _sortScratch as Array<Float>;
    
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
        
        // Pre-allocate circular buffers (no runtime allocation)
        _recentPeaks = new [MAX_RECENT_PEAKS] as Array<Float>;
        for (var i = 0; i < MAX_RECENT_PEAKS; i++) {
            _recentPeaks[i] = 0.0;
        }
        _recentPeaksIdx = 0;
        _recentPeaksCount = 0;
        
        _previousMagnitudes = new [MAGNITUDE_BUFFER_SIZE] as Array<Float>;
        for (var i = 0; i < MAGNITUDE_BUFFER_SIZE; i++) {
            _previousMagnitudes[i] = 0.0;
        }
        _prevMagIdx = 0;
        _prevMagCount = 0;
        
        // Pre-allocate sort scratch buffer (for adaptive threshold calculation)
        _sortScratch = new [MAX_RECENT_PEAKS] as Array<Float>;
        for (var i = 0; i < MAX_RECENT_PEAKS; i++) {
            _sortScratch[i] = 0.0;
        }
        
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
        _recentPeaksIdx = 0;
        _recentPeaksCount = 0;
        
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
            // Use registerSensorDataListener for HIGH-FREQUENCY sensor data (25Hz)
            // enableSensorEvents only provides 1Hz which is too slow for steadiness analysis!
            // NOTE: Gyroscope removed - was registered but never used (battery waste)
            // If angular velocity analysis is needed later, add gyro back AND read the data
            var options = {
                :period => 1,  // 1 second batches
                :accelerometer => {
                    :enabled => true,
                    :sampleRate => 25  // 25 samples per second for proper steadiness analysis
                }
            };
            
            Sensor.registerSensorDataListener(method(:onHighFreqSensorData), options);
            
            _isMonitoring = true;
            _lastShotTime = 0;
            
            // Reset adaptive threshold state
            _adaptiveThreshold = _config.sensitivity;
            _baselineMagnitude = 1.0;
            
            // Reset circular buffer indices (no memory allocation)
            _recentPeaksIdx = 0;
            _recentPeaksCount = 0;
            _prevMagIdx = 0;
            _prevMagCount = 0;
            
            _rejectedLowCount = 0;
            _rejectedVerticalCount = 0;

            // Start biometrics tracking (HR, breathing) with session ID for timeline
            _biometricsTracker.startTracking(sessionId);

            System.println("[SHOT] ✓ High-freq sensor listener REGISTERED (25Hz)");
            System.println("[SHOT]   Threshold: " + _config.sensitivity + "G");
            System.println("[SHOT]   MinThreshold: " + _config.minThreshold + "G");
            System.println("[SHOT]   Cooldown: " + _config.getEffectiveCooldown() + "ms");
        } catch (ex) {
            System.println("[SHOT] ✗ FAILED to register sensor listener: " + ex.getErrorMessage());
            // Fallback to low-freq sensor events (1Hz) - won't have steadiness but shot detection works
            try {
                Sensor.enableSensorEvents(method(:onSensorData));
                _isMonitoring = true;
                System.println("[SHOT] ⚠ Fallback to 1Hz sensor events (no steadiness data)");
            } catch (ex2) {
                System.println("[SHOT] ✗ Fallback also failed!");
            }
        }
    }
    
    // Stop monitoring accelerometer
    function stopMonitoring() as Void {
        if (!_isMonitoring) {
            return;
        }
        
        try {
            // Unregister high-freq listener first
            Sensor.unregisterSensorDataListener();
        } catch (ex) {
            // May not have been registered if fallback was used
        }
        
        try {
            // Also disable low-freq sensor events (in case fallback was used)
            Sensor.enableSensorEvents(null);
        } catch (ex) {
            // Ignore
        }
        
        _isMonitoring = false;
        
        // Stop biometrics tracking
        _biometricsTracker.stopTracking();
        
        System.println("[SHOT] Accelerometer monitoring stopped");
        System.println("[SHOT]   Total detections: " + _totalDetections);
        System.println("[SHOT]   Rejected (low): " + _rejectedLowCount);
        System.println("[SHOT]   Rejected (vertical): " + _rejectedVerticalCount);
        System.println("[SHOT]   Final adaptive threshold: " + _adaptiveThreshold.format("%.2f") + "G");
        System.println("[SHOT]   Steadiness buffer: " + _steadinessAnalyzer.getBufferCount() + " samples");
    }
    
    // Check if currently monitoring
    function isMonitoring() as Boolean {
        return _isMonitoring;
    }
    
    // Enable/disable shot detection
    // Note: This only controls auto-detection of shots via accelerometer threshold.
    // The accelerometer keeps running for steadiness analysis even when disabled.
    function setEnabled(enabled as Boolean) as Void {
        _enabled = enabled;
        // Don't stop monitoring here - we want accelerometer data for steadiness
        // even when auto-detect is off. Use stopMonitoring() explicitly when session ends.
        System.println("[SHOT] Auto-detection " + (enabled ? "ENABLED" : "DISABLED") + " (_isMonitoring=" + _isMonitoring + ")");
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
        
        // Reset adaptive threshold and circular buffers
        _adaptiveThreshold = _config.sensitivity;
        _baselineMagnitude = 1.0;
        
        // Clear circular buffers (reset indices, don't reallocate)
        _recentPeaksIdx = 0;
        _recentPeaksCount = 0;
        _prevMagIdx = 0;
        _prevMagCount = 0;
        
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
    // HIGH-FREQUENCY SENSOR CALLBACK - For steadiness analysis (25Hz)
    // =========================================================================
    
    // Called with batches of high-frequency accelerometer data
    function onHighFreqSensorData(sensorData as Sensor.SensorData) as Void {
        var accelData = sensorData.accelerometerData;
        if (accelData == null) {
            return;
        }
        
        var xSamples = accelData.x;
        var ySamples = accelData.y;
        var zSamples = accelData.z;
        
        if (xSamples == null || ySamples == null || zSamples == null) {
            return;
        }
        
        var sampleCount = xSamples.size();
        if (sampleCount == 0) {
            return;
        }
        
        // Calculate timing for samples
        var now = System.getTimer();
        var batchDuration = 1000;  // 1 second batch
        var sampleInterval = batchDuration / sampleCount;  // ~40ms at 25Hz
        
        // Check if timestamps are available (not all devices support this)
        var hasTimestamps = false;
        var timestamps = null;
        if (accelData has :timestamps) {
            timestamps = accelData.timestamps;
            hasTimestamps = (timestamps != null && timestamps.size() >= sampleCount);
        }
        
        // Process each sample in the batch
        for (var i = 0; i < sampleCount; i++) {
            var x = xSamples[i].toFloat() / 1000.0;  // Convert milli-G to G
            var y = ySamples[i].toFloat() / 1000.0;
            var z = zSamples[i].toFloat() / 1000.0;
            
            // Use real timestamp if available, otherwise estimate
            var sampleTime;
            if (hasTimestamps && timestamps != null) {
                sampleTime = timestamps[i];
            } else {
                sampleTime = now - batchDuration + (i * sampleInterval);
            }
            
            // Use common processing function (DRY)
            processSample(x, y, z, sampleTime);
        }
    }
    
    // =========================================================================
    // LOW-FREQ SENSOR CALLBACK (1Hz fallback)
    // =========================================================================
    
    // Called when new accelerometer data is available (1Hz - fallback only)
    function onSensorData(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.accel == null) {
            return;
        }
        
        var accel = sensorInfo.accel;
        var x = accel[0].toFloat() / 1000.0;  // Convert milli-G to G
        var y = accel[1].toFloat() / 1000.0;
        var z = accel[2].toFloat() / 1000.0;
        
        // Use common processing function (DRY)
        processSample(x, y, z, System.getTimer());
    }
    
    // =========================================================================
    // COMMON SAMPLE PROCESSING (DRY - used by both high-freq and low-freq callbacks)
    // =========================================================================
    
    private function processSample(x as Float, y as Float, z as Float, sampleTime as Number) as Void {
        // Feed to steadiness analyzer
        _steadinessAnalyzer.addSample(x, y, z);
        
        // Calculate magnitude
        var magnitudeSq = (x * x) + (y * y) + (z * z);
        var magnitude = Math.sqrt(magnitudeSq).toFloat();
        
        // Update rolling baseline (only when not spiking, avoids recoil contamination)
        if (magnitude < 1.5 && magnitude > 0.5) {
            _baselineMagnitude = (_baselineMagnitude * (1.0 - BASELINE_ALPHA)) + 
                                 (magnitude * BASELINE_ALPHA);
        }
        
        // Delta from rolling baseline (not hardcoded 1.0G)
        var delta = (magnitude - _baselineMagnitude).abs();
        _lastMagnitude = delta;
        
        // Add to circular buffer (no memory allocation)
        addToPreviousMagnitudes(delta);
        
        // Calibration mode
        if (_calibrating && delta > 1.5) {
            _calibrationPeaks.add(delta);
            return;
        }
        
        // Shot detection disabled - still collecting data for steadiness
        if (!_enabled) {
            return;
        }
        
        // Cooldown check
        var timeSinceLastShot = sampleTime - _lastShotTime;
        if (timeSinceLastShot < _config.getEffectiveCooldown()) {
            return;
        }
        
        // Below minimum threshold
        if (delta < _config.minThreshold) {
            return;
        }
        
        // Detection check
        if (delta >= _adaptiveThreshold) {
            // Validate shot signature
            if (!validateShotSignature(x, y, z, magnitude, delta)) {
                _rejectedVerticalCount++;
                return;
            }
            
            // Shot detected!
            _lastShotTime = sampleTime;
            _totalDetections++;
            
            // Record peak to circular buffer
            addToRecentPeaks(delta);
            updateAdaptiveThreshold();
            
            // Analyze steadiness and biometrics
            _lastSteadinessResult = _steadinessAnalyzer.analyzeShot(sampleTime, _totalDetections);
            _lastShotBiometrics = _biometricsTracker.recordShotBiometrics(_totalDetections);
            
            _biometricsTracker.recordShotForTimeline(
                _totalDetections,
                _lastSteadinessResult.steadinessScore.toNumber(),
                _lastSteadinessResult.flinchDetected,
                false
            );
            
            System.println("[SHOT] Detected! Mag: " + delta.format("%.2f") + "G, Adaptive: " + 
                          _adaptiveThreshold.format("%.2f") + "G, Total: " + _totalDetections +
                          ", Steady: " + _lastSteadinessResult.gradeString);
            
            // Callbacks
            if (_onShotWithSteadiness != null && _lastSteadinessResult != null) {
                _onShotWithSteadiness.invoke(_lastSteadinessResult);
            }
            if (_onShotDetected != null) {
                _onShotDetected.invoke();
            }
            
            // Vibration feedback
            if (_vrcv && (Attention has :vibrate)) {
                var vibeData = [new Attention.VibeProfile(75, 50)];
                Attention.vibrate(vibeData);
            }
        }
    }
    
    // =========================================================================
    // CIRCULAR BUFFER HELPERS (no memory allocation after init)
    // =========================================================================
    
    private function addToRecentPeaks(value as Float) as Void {
        _recentPeaks[_recentPeaksIdx] = value;
        _recentPeaksIdx = (_recentPeaksIdx + 1) % MAX_RECENT_PEAKS;
        if (_recentPeaksCount < MAX_RECENT_PEAKS) {
            _recentPeaksCount++;
        }
    }
    
    private function addToPreviousMagnitudes(value as Float) as Void {
        _previousMagnitudes[_prevMagIdx] = value;
        _prevMagIdx = (_prevMagIdx + 1) % MAGNITUDE_BUFFER_SIZE;
        if (_prevMagCount < MAGNITUDE_BUFFER_SIZE) {
            _prevMagCount++;
        }
    }
    
    private function getPreviousMagnitude(offset as Number) as Float {
        if (offset >= _prevMagCount) {
            return 0.0;
        }
        var idx = (_prevMagIdx - 1 - offset + MAGNITUDE_BUFFER_SIZE) % MAGNITUDE_BUFFER_SIZE;
        return _previousMagnitudes[idx];
    }
    
    // =========================================================================
    // SHOT SIGNATURE VALIDATION
    // Real shots have specific characteristics that differentiate them from arm movement
    // =========================================================================
    
    private function validateShotSignature(x as Float, y as Float, z as Float, magnitude as Float, delta as Float) as Boolean {
        // FIXED VALIDATION - Uses delta values to remove gravity bias
        // 
        // Previous issue: Using raw magnitude included gravity (~1G on Z-axis),
        // which biased the dominant axis check.
        //
        // Rise time check REMOVED: At 25Hz (40ms samples), a gunshot impulse (1-5ms)
        // lands entirely within one sample. The check wasn't doing anything useful.
        
        // Remove gravity from calculation (use deltas, not raw values)
        var deltaX = (x).abs();
        var deltaY = (y).abs();
        var deltaZ = (z - _baselineMagnitude).abs();  // Z typically has gravity
        
        var deltaMag = Math.sqrt(deltaX*deltaX + deltaY*deltaY + deltaZ*deltaZ).toFloat();
        
        // Find dominant delta axis
        var maxDeltaAxis = deltaX;
        if (deltaY > maxDeltaAxis) { maxDeltaAxis = deltaY; }
        if (deltaZ > maxDeltaAxis) { maxDeltaAxis = deltaZ; }
        
        // Check for directional impulse (not uniform noise)
        var dominantRatio = 0.0;
        if (deltaMag > 0.1) {
            dominantRatio = maxDeltaAxis / deltaMag;
        }
        
        if (dominantRatio < 0.25) {
            System.println("[SHOT] Rejected: no dominant axis (ratio=" + dominantRatio.format("%.2f") + ")");
            return false;
        }
        
        // Optional: Verify decay pattern (post-shot samples should decrease)
        // This catches "held acceleration" like arm swings
        // Only check if we have enough history
        if (_prevMagCount >= 3) {
            var prevDelta = getPreviousMagnitude(1);  // 1 sample ago
            // If previous sample was ALSO high, this might be sustained movement, not impulse
            if (prevDelta > delta * 0.9 && prevDelta > _config.minThreshold * 2) {
                System.println("[SHOT] Rejected: sustained high magnitude (prev=" + prevDelta.format("%.2f") + ")");
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
        if (_recentPeaksCount < 2) {
            return;
        }
        
        // Copy circular buffer to pre-allocated scratch array (zero allocation)
        for (var i = 0; i < _recentPeaksCount; i++) {
            var idx = (_recentPeaksIdx - _recentPeaksCount + i + MAX_RECENT_PEAKS) % MAX_RECENT_PEAKS;
            _sortScratch[i] = _recentPeaks[idx];
        }
        
        // Simple bubble sort in-place (only _recentPeaksCount elements)
        for (var i = 0; i < _recentPeaksCount - 1; i++) {
            for (var j = 0; j < _recentPeaksCount - 1 - i; j++) {
                if (_sortScratch[j] > _sortScratch[j + 1]) {
                    var temp = _sortScratch[j];
                    _sortScratch[j] = _sortScratch[j + 1];
                    _sortScratch[j + 1] = temp;
                }
            }
        }
        
        var median = _sortScratch[_recentPeaksCount / 2];
        
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
                      "G (median: " + median.format("%.2f") + "G, samples: " + _recentPeaksCount + ")");
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
