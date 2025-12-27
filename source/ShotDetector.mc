import Toybox.Lang;
import Toybox.System;
import Toybox.Sensor;
import Toybox.Timer;
import Toybox.Attention;
import Toybox.Math;
import Toybox.Application;

// Sensitivity presets (in G-force)
enum ShotSensitivity {
    SENSITIVITY_LOW = 0,    // 4.5G - Less sensitive, fewer false positives
    SENSITIVITY_MEDIUM = 1, // 3.5G - Default, balanced
    SENSITIVITY_HIGH = 2    // 2.5G - More sensitive, may have false positives
}

// Callback interface for shot detection
typedef ShotCallback as Method() as Void;

class ShotDetector {
    // Detection parameters
    private var _threshold as Float = 3.5;      // G-force threshold
    private var _cooldownMs as Number = 200;    // Minimum ms between shots
    private var _enabled as Boolean = true;     // Enabled by default
    private var _calibrating as Boolean = false;
    
    // State tracking
    private var _lastShotTime as Number = 0;
    private var _isMonitoring as Boolean = false;
    
    // Calibration data
    private var _calibrationPeaks as Array<Float> = [];
    private var _calibrationTimer as Timer.Timer?;
    private var _calibrationCallback as Method(threshold as Float) as Void?;
    
    // Shot callback
    private var _onShotDetected as ShotCallback?;
    
    // Debug/stats
    private var _totalDetections as Number = 0;
    private var _lastMagnitude as Float = 0.0;
    
    function initialize() {
        // Load saved threshold from storage if available
        loadSettings();
    }
    
    // =========================================================================
    // PUBLIC API
    // =========================================================================
    
    // Set the callback function to call when a shot is detected
    function setOnShotDetected(callback as ShotCallback) as Void {
        _onShotDetected = callback;
    }
    
    // Start monitoring accelerometer for shots
    function startMonitoring() as Void {
        if (_isMonitoring) {
            System.println("[SHOT] Already monitoring, skipping start");
            return;
        }
        
        System.println("[SHOT] === STARTING MONITORING ===");
        
        try {
            // Enable sensor events callback - accel data comes through Info.accel
            Sensor.enableSensorEvents(method(:onSensorData));
            _isMonitoring = true;
            _lastShotTime = 0;
            System.println("[SHOT] ✓ Sensor events ENABLED, threshold: " + _threshold + "G");
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
            System.println("[SHOT] Accelerometer monitoring stopped. Total detections: " + _totalDetections);
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
    
    // Set sensitivity preset
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
        saveSettings();
        System.println("[SHOT] Sensitivity set to: " + _threshold + "G");
    }
    
    // Set custom threshold directly
    function setThreshold(threshold as Float) as Void {
        _threshold = threshold;
        saveSettings();
    }
    
    function getThreshold() as Float {
        return _threshold;
    }
    
    // Set cooldown period
    function setCooldown(ms as Number) as Void {
        _cooldownMs = ms;
    }
    
    // Get last detected magnitude (for debug display)
    function getLastMagnitude() as Float {
        return _lastMagnitude;
    }
    
    // Get total detections this session
    function getTotalDetections() as Number {
        return _totalDetections;
    }
    
    // Reset detection counter
    function resetDetections() as Void {
        _totalDetections = 0;
        _lastShotTime = 0;
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
        
        if (timeSinceLastShot >= _cooldownMs) {
            _lastShotTime = now;
            _totalDetections++;
            _lastMagnitude = _threshold + 0.5;  // Fake magnitude above threshold
            
            System.println("[SHOT] SIMULATED shot! Total: " + _totalDetections);
            
            if (_onShotDetected != null) {
                _onShotDetected.invoke();
            } else {
                System.println("[SHOT] WARNING: No callback registered!");
            }
            
            if (Attention has :vibrate) {
                var vibeData = [
                    new Attention.VibeProfile(75, 50)
                ];
                Attention.vibrate(vibeData);
            }
        } else {
            System.println("[SHOT] Cooldown active, wait " + (_cooldownMs - timeSinceLastShot) + "ms");
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
            startMonitoring();
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
            
            _threshold = newThreshold;
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
    // SENSOR CALLBACK
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
        
        // Calculate magnitude: sqrt(x² + y² + z²)
        var magnitudeSq = (x * x) + (y * y) + (z * z);
        var magnitude = Math.sqrt(magnitudeSq).toFloat();
        
        // Subtract baseline gravity (~1G) to get delta
        var delta = magnitude - 1.0;
        if (delta < 0) {
            delta = -delta;  // abs()
        }
        _lastMagnitude = delta;
        
        // During calibration, record peaks above 1.5G
        if (_calibrating && delta > 1.5) {
            _calibrationPeaks.add(delta);
            return;  // Don't trigger shots during calibration
        }
        
        // Check if this is a shot
        if (!_enabled) {
            return;
        }
        
        var now = System.getTimer();
        var timeSinceLastShot = now - _lastShotTime;
        
        // Check threshold and cooldown
        if (delta >= _threshold && timeSinceLastShot >= _cooldownMs) {
            // Shot detected!
            _lastShotTime = now;
            _totalDetections++;
            
            System.println("[SHOT] Detected! Magnitude: " + delta.format("%.2f") + "G, Total: " + _totalDetections);
            
            // Trigger callback
            if (_onShotDetected != null) {
                _onShotDetected.invoke();
            }
            
            // Haptic feedback (short pulse)
            if (Attention has :vibrate) {
                var vibeData = [
                    new Attention.VibeProfile(75, 50)  // Short 50ms pulse
                ];
                Attention.vibrate(vibeData);
            }
        }
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
            } else if (savedThreshold != null && savedThreshold instanceof Number) {
                _threshold = savedThreshold.toFloat();
            }
            var savedEnabled = app.getProperty("autoDetectEnabled");
            if (savedEnabled != null && savedEnabled instanceof Boolean) {
                _enabled = savedEnabled;
            }
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
        } catch (ex) {
            System.println("[SHOT] Failed to save settings: " + ex.getErrorMessage());
        }
    }
}