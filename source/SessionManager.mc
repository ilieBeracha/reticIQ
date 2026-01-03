// SessionManager.mc - Manages session state and raw sensor data
// Centralizes all session data collection for two-phase sync
import Toybox.Lang;
import Toybox.Time;
import Toybox.System;

class SessionManager {

    // Session identity
    private var _sessionId as String = "";
    private var _drillName as String = "";
    private var _drillType as String = "";
    private var _inputMethod as String = "";
    private var _distance as Number = 0;
    private var _targetRounds as Number = 0;
    private var _strings as Number = 1;
    private var _parTime as Number = 0;
    private var _timeLimit as Number = 0;

    // Timing
    private var _startTime as Number = 0;      // Moment.value()
    private var _endTime as Number = 0;
    private var _startTimestamp as Number = 0; // System.getTimer() at start
    private var _cachedDurationMs as Number = 0; // Cached duration when session ends

    // Shot data
    private var _shotTimestamps as Array<Number> = [];  // ms from session start
    private var _splitTimes as Array<Number> = [];      // ms between shots
    private var _hits as Number = 0;

    // Steadiness results (from SteadinessAnalyzer via ShotDetector)
    private var _steadinessResults as Array<SteadinessResult> = [];

    // Flinch tracking
    private var _flinchCount as Number = 0;

    // Detection metadata
    private var _autoDetected as Boolean = false;
    private var _sensitivity as Float = 3.5;
    private var _manualOverrides as Number = 0;

    // State
    private var _isActive as Boolean = false;
    private var _isCompleted as Boolean = false;  // Reached max shots

    // ========================================
    // LIFECYCLE
    // ========================================

    function initialize() {
        _steadinessResults = [];
    }

    function startSession(config as Dictionary) as Void {
        _sessionId = config.get("sessionId") != null ? config.get("sessionId").toString() : "";
        _drillName = config.get("drillName") != null ? config.get("drillName").toString() : "Practice";
        _drillType = config.get("drillType") != null ? config.get("drillType").toString() : "";
        _inputMethod = config.get("inputMethod") != null ? config.get("inputMethod").toString() : "";
        _distance = config.get("distance") != null ? (config.get("distance") as Number) : 0;
        _parTime = config.get("parTime") != null ? (config.get("parTime") as Number) : 0;
        _timeLimit = config.get("timeLimit") != null ? (config.get("timeLimit") as Number) : 0;
        _strings = config.get("strings") != null ? (config.get("strings") as Number) : 1;

        // Compute target rounds
        var rounds = config.get("rounds") != null ? (config.get("rounds") as Number) : 0;
        if (config.get("maxBullets") != null) {
            _targetRounds = config.get("maxBullets") as Number;
        } else if (config.get("bullets") != null) {
            _targetRounds = config.get("bullets") as Number;
        } else {
            _targetRounds = (rounds > 0) ? (rounds * _strings) : 0;
        }

        // Detection settings
        _autoDetected = false;
        if (config.get("autoDetect") != null) {
            var val = config.get("autoDetect");
            if (val instanceof Boolean) {
                _autoDetected = val;
            }
        }

        if (config.get("sensitivity") != null) {
            var sVal = config.get("sensitivity");
            if (sVal instanceof Float) {
                _sensitivity = sVal;
            } else if (sVal instanceof Number) {
                _sensitivity = sVal.toFloat();
            }
        }

        _startTime = Time.now().value();
        _startTimestamp = System.getTimer();
        _cachedDurationMs = 0;  // Reset cached duration

        // Clear arrays
        _shotTimestamps = [];
        _splitTimes = [];
        _steadinessResults = [];
        _hits = 0;
        _manualOverrides = 0;
        _flinchCount = 0;

        _isActive = true;
        _isCompleted = false;

        System.println("[SESSION] Started: " + _sessionId + " targeting " + _targetRounds + " rounds");
    }

    function endSession(completed as Boolean) as Void {
        _endTime = Time.now().value();
        // Cache the duration NOW so it doesn't change on retries
        if (_startTimestamp > 0) {
            _cachedDurationMs = System.getTimer() - _startTimestamp;
        }
        _isActive = false;
        _isCompleted = completed;
        System.println("[SESSION] Ended: " + _sessionId + " with " + _shotTimestamps.size() + " shots, completed=" + completed + ", duration=" + _cachedDurationMs + "ms");
    }

    // ========================================
    // DATA RECORDING (called during session)
    // ========================================

    // Record a shot with timestamp and split time
    function recordShot(timestamp as Number, splitMs as Number) as Void {
        _shotTimestamps.add(timestamp);
        if (splitMs > 0) {
            _splitTimes.add(splitMs);
        }
        System.println("[SESSION] Shot " + _shotTimestamps.size() + " at " + timestamp + "ms, split=" + splitMs + "ms");
    }

    // Record steadiness result for a shot
    function recordSteadinessResult(result as SteadinessResult) as Void {
        _steadinessResults.add(result);
        if (result.flinchDetected) {
            _flinchCount++;
        }
    }

    // Track manual override (correction)
    function recordManualOverride() as Void {
        _manualOverrides++;
    }

    // Remove last shot (undo)
    function removeLastShot() as Void {
        if (_shotTimestamps.size() > 0) {
            _shotTimestamps = _shotTimestamps.slice(0, _shotTimestamps.size() - 1) as Array<Number>;
        }
        if (_splitTimes.size() > 0) {
            _splitTimes = _splitTimes.slice(0, _splitTimes.size() - 1) as Array<Number>;
        }
        if (_steadinessResults.size() > 0) {
            var lastResult = _steadinessResults[_steadinessResults.size() - 1];
            if (lastResult.flinchDetected) {
                _flinchCount--;
            }
            _steadinessResults = _steadinessResults.slice(0, _steadinessResults.size() - 1) as Array<SteadinessResult>;
        }
        _manualOverrides++;
    }

    function setHits(count as Number) as Void {
        _hits = count;
    }

    // ========================================
    // GETTERS
    // ========================================

    function getSessionId() as String { return _sessionId; }
    function getDrillName() as String { return _drillName; }
    function getDrillType() as String { return _drillType; }
    function getInputMethod() as String { return _inputMethod; }
    function getDistance() as Number { return _distance; }
    function getTargetRounds() as Number { return _targetRounds; }
    function getParTime() as Number { return _parTime; }
    function getTimeLimit() as Number { return _timeLimit; }
    function getShotCount() as Number { return _shotTimestamps.size(); }
    function getHits() as Number { return _hits; }
    function isActive() as Boolean { return _isActive; }
    function isCompleted() as Boolean { return _isCompleted; }
    function wasAutoDetected() as Boolean { return _autoDetected; }
    function getSensitivity() as Float { return _sensitivity; }
    function getManualOverrides() as Number { return _manualOverrides; }
    function getFlinchCount() as Number { return _flinchCount; }
    function getStartTimestamp() as Number { return _startTimestamp; }

    function getDurationMs() as Number {
        // If session has ended, return the cached duration (prevents drift on retries)
        if (_cachedDurationMs > 0) {
            return _cachedDurationMs;
        }
        // Session still active - calculate live
        if (_startTimestamp == 0) { return 0; }
        return System.getTimer() - _startTimestamp;
    }

    function getSplitTimes() as Array<Number> { return _splitTimes; }
    function getShotTimestamps() as Array<Number> { return _shotTimestamps; }
    function getSteadinessResults() as Array<SteadinessResult> { return _steadinessResults; }

    // Reset for new session
    function reset() as Void {
        _sessionId = "";
        _drillName = "";
        _drillType = "";
        _inputMethod = "";
        _distance = 0;
        _targetRounds = 0;
        _strings = 1;
        _parTime = 0;
        _timeLimit = 0;
        _startTime = 0;
        _endTime = 0;
        _startTimestamp = 0;
        _cachedDurationMs = 0;
        _shotTimestamps = [];
        _splitTimes = [];
        _steadinessResults = [];
        _hits = 0;
        _flinchCount = 0;
        _manualOverrides = 0;
        _autoDetected = false;
        _sensitivity = 3.5;
        _isActive = false;
        _isCompleted = false;
    }
}
