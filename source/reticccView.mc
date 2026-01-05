import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.Time;
import Toybox.Weather;
import Toybox.Math;
import Toybox.Attention;

// Session state enum
enum SessionState {
    STATE_IDLE,
    STATE_SESSION_ACTIVE,
    STATE_SESSION_ENDED
}

// Session page enum (for active session navigation)
enum SessionPage {
    PAGE_PERSONAL = -1,  // UP - personal/session data
    PAGE_MAIN = 0,       // Main shot counter
    PAGE_ENVIRONMENT = 1 // DOWN - wind, light, environment
}

// Watch mode enum - determines watch behavior
// PRIMARY: Watch counts shots, enforces limits (timed drills, manual)
// SUPPLEMENTARY: Watch is timer only, no limits (zeroing, grouping, scan drills)
enum WatchMode {
    WATCH_MODE_PRIMARY,      // Shot counter - enforces limits
    WATCH_MODE_SUPPLEMENTARY // Timer only - no enforcement
}

class reticccView extends WatchUi.View {

    // Session state
    private var _state as SessionState = STATE_IDLE;
    
    // Session data from phone
    private var _sessionId as String = "";
    private var _drillName as String = "";
    private var _drillGoal as String = "";
    private var _drillType as String = "";      // zeroing, grouping, timed, qualification
    private var _inputMethod as String = "";    // scan, manual, both
    private var _distance as Number = 0;
    private var _maxBullets as Number = 0;       // Max shots allowed (from phone)
    private var _timeLimit as Number = 0;
    private var _parTime as Number = 0;          // Par time in seconds (0 = none)
    private var _strings as Number = 1;          // Number of strings/stages
    
    // Watch mode - determines UI and behavior
    private var _watchMode as WatchMode = WATCH_MODE_PRIMARY;
    
    // Shot counter (user controlled)
    private var _shotsFired as Number = 0;
    
    // Timer for elapsed time
    private var _startTime as Number = 0;
    private var _timer as Timer.Timer?;
    private var _elapsedSeconds as Number = 0;
    private var _elapsedMs as Number = 0;        // More precise timing
    
    // Split time tracking
    private var _lastShotTime as Number = 0;     // System.getTimer() of last shot
    private var _splitTimes as Array<Number> = [];  // Time between shots (ms)
    private var _sessionCompleted as Boolean = false;  // True if max rounds reached
    
    // Steadiness tracking
    private var _steadinessResults as Array<SteadinessResult>;  // All shot steadiness scores
    private var _lastSteadinessGrade as String = "";            // Most recent grade for display
    private var _lastSteadinessScore as Number = 0;             // Most recent score for display
    
    // Connection status
    private var _connected as Boolean = false;
    
    // Weather/wind data
    private var _windSpeed as Number = 0;      // m/s or mph
    private var _windDirection as String = ""; // N, NE, E, etc.
    private var _windAngle as Number = 0;      // Wind angle in degrees
    private var _temperature as Number = 0;    // Celsius
    private var _humidity as Number = 0;       // Percentage
    private var _pressure as Number = 0;       // hPa/mbar
    private var _lightLevel as Number = 0;     // 0-100 (dark to bright)
    private var _altitude as Number = 0;       // meters
    
    // Personal data (from phone/profile)
    private var _shooterName as String = "";
    private var _totalSessions as Number = 0;
    private var _totalShots as Number = 0;
    private var _bestAccuracy as Number = 0;   // Percentage
    
    // Page navigation (during active session)
    private var _currentPage as SessionPage = PAGE_MAIN;
    
    // Visual feedback
    private var _shotFlashActive as Boolean = false;
    private var _shotFlashTimer as Timer.Timer?;
    
    // Temperature has been set flag (to distinguish 0°C from no data)
    private var _hasTemperature as Boolean = false;
    private var _hasHumidity as Boolean = false;
    private var _hasPressure as Boolean = false;
    
    // Debug/status tracking
    private var _lastMsg as String = "";
    private var _errorMsg as String = "";  // Full error message for display
    
    // Auto shot detection
    private var _shotDetector as ShotDetector?;
    private var _autoDetectEnabled as Boolean = false;
    private var _manualOverrides as Number = 0;  // Track manual shot additions/removals
    // Pending session (received from phone, waiting for user to start)
    private var _pendingSession as Dictionary?;
    // Preview mode - shows the pending session UI frozen until user starts
    private var _isPreview as Boolean = false;

    // Demo mode - auto-fires shots at intervals
    private var _demoMode as Boolean = false;
    private var _demoShotsRemaining as Number = 0;
    private var _demoNextShotTime as Number = 0;  // System.getTimer() when next shot should fire
    
    // Countdown before session starts (3, 2, 1, GO!)
    private var _countdownActive as Boolean = false;
    private var _countdownValue as Number = 0;        // Current countdown number (3, 2, 1, 0=GO)
    private var _countdownStartTime as Number = 0;    // When countdown started
    private var _countdownTimer as Timer.Timer?;
    private var _pendingSessionData as Dictionary?;   // Session data waiting for countdown to finish
    
    // =========================================================================
    // DYNAMIC FONT SELECTION - Pick best font for available space
    // Per Travis Vitek (Garmin) recommendations
    // =========================================================================
    
    // Select the largest font that fits text within given dimensions
    private function selectFontForText(dc as Dc, maxWidth as Number, maxHeight as Number, sampleText as String) as FontDefinition {
        // Try fonts from largest to smallest
        var fonts = [
            Graphics.FONT_NUMBER_HOT,
            Graphics.FONT_NUMBER_THAI_HOT,
            Graphics.FONT_NUMBER_MEDIUM,
            Graphics.FONT_NUMBER_MILD,
            Graphics.FONT_LARGE,
            Graphics.FONT_MEDIUM,
            Graphics.FONT_SMALL,
            Graphics.FONT_TINY,
            Graphics.FONT_XTINY
        ];
        
        for (var i = 0; i < fonts.size(); i++) {
            var font = fonts[i];
            var dims = dc.getTextDimensions(sampleText, font);
            if (dims[0] <= maxWidth && dims[1] <= maxHeight) {
                return font;
            }
        }
        
        // Fallback to smallest
        return Graphics.FONT_XTINY;
    }
    
    // Get a font size suitable for the display (based on screen width)
    private function getDisplaySizeClass(dc as Dc) as Symbol {
        var width = dc.getWidth();
        if (width >= 280) {
            return :large;      // Fenix 8 47mm+, Forerunner 965
        } else if (width >= 240) {
            return :medium;     // Fenix 8 43mm, Instinct 2
        } else if (width >= 200) {
            return :small;      // Forerunner 55, older devices
        } else {
            return :tiny;       // Edge devices, etc
        }
    }

    function initialize() {
        View.initialize();
        // Fetch initial weather data from Garmin
        fetchWeatherFromWatch();
        
        // Initialize steadiness results array
        _steadinessResults = [];
        
        // Initialize shot detector with steadiness callback
        _shotDetector = new ShotDetector();
        _shotDetector.setOnShotDetected(method(:onAutoShotDetected));
        _shotDetector.setOnShotWithSteadiness(method(:onShotWithSteadiness));
    }
    
    // Callback when a shot is detected with steadiness analysis
    function onShotWithSteadiness(steadiness as SteadinessResult) as Void {
        // Store the result locally for UI display
        _steadinessResults.add(steadiness);
        _lastSteadinessGrade = steadiness.gradeString;
        _lastSteadinessScore = steadiness.steadinessScore.toNumber();

        // Record to SessionManager for payload building
        var app = Application.getApp() as reticccApp;
        var sessionMgr = app.getSessionManager();
        sessionMgr.recordSteadinessResult(steadiness);

        System.println("[VIEW] Shot " + steadiness.shotNumber + " steadiness: " +
                      _lastSteadinessGrade + " (" + _lastSteadinessScore + ")");
    }

    // Helper: coerce various incoming types to Number (handles Number, Float, String)
    private function toNumberCoerce(v as Object, def as Number) as Number {
        if (v == null) { return def; }
        if (v instanceof Number) { return v as Number; }
        if (v instanceof Float) { return (v as Float).toNumber(); }
        if (v instanceof String) {
            try {
                return (v as String).toNumber();
            } catch (ex) {
                return def;
            }
        }
        return def;
    }

    function onLayout(dc as Dc) as Void {
    }

    function onShow() as Void {
        _timer = new Timer.Timer();
        // Use 100ms updates for smooth timer display in supplementary mode
        _timer.start(method(:onTimerTick), 100, true);
        System.println("[VIEW] onShow - timer started, demoMode: " + _demoMode + ", demoShots: " + _demoShotsRemaining);
        // Refresh weather data when view is shown
        fetchWeatherFromWatch();
    }
    
    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
        
        // Stop shot detection when view is hidden
        if (_shotDetector != null) {
            _shotDetector.stopMonitoring();
        }
    }
    
    // =========================================================================
    // WEATHER - Fetch from Garmin Watch Weather API
    // =========================================================================
    function fetchWeatherFromWatch() as Void {
        // Get current weather conditions from Garmin (API 3.2.0+)
        var conditions = Weather.getCurrentConditions();
        
        if (conditions != null) {
            // Temperature in Celsius
            if (conditions.temperature != null) {
                _temperature = conditions.temperature.toNumber();
                _hasTemperature = true;
            }
            
            // Wind speed in m/s
            if (conditions.windSpeed != null) {
                _windSpeed = conditions.windSpeed.toNumber();
            }
            
            // Wind bearing (degrees) - convert to cardinal direction
            if (conditions.windBearing != null) {
                _windAngle = conditions.windBearing;
                _windDirection = bearingToCardinal(conditions.windBearing);
            }
            
            // Humidity (0-100%)
            if (conditions has :relativeHumidity && conditions.relativeHumidity != null) {
                _humidity = conditions.relativeHumidity;
                _hasHumidity = true;
            }
            
            // Pressure in Pascals - convert to hPa (millibars)
            // Not available on all devices (e.g., Instinct 2)
            if (conditions has :pressure && conditions.pressure != null) {
                _pressure = (conditions.pressure / 100).toNumber();  // Pa to hPa
                _hasPressure = true;
            }
        }
    }
    
    // Convert wind bearing (degrees) to cardinal direction
    private function bearingToCardinal(bearing as Number) as String {
        // North = 0, East = 90, South = 180, West = 270
        if (bearing >= 337.5 || bearing < 22.5) {
            return "N";
        } else if (bearing >= 22.5 && bearing < 67.5) {
            return "NE";
        } else if (bearing >= 67.5 && bearing < 112.5) {
            return "E";
        } else if (bearing >= 112.5 && bearing < 157.5) {
            return "SE";
        } else if (bearing >= 157.5 && bearing < 202.5) {
            return "S";
        } else if (bearing >= 202.5 && bearing < 247.5) {
            return "SW";
        } else if (bearing >= 247.5 && bearing < 292.5) {
            return "W";
        } else {
            return "NW";
        }
    }
    
    // Timer callback - update elapsed time and check time limit
    function onTimerTick() as Void {
        // Demo mode check - runs even before session timer display logic
        if (_demoMode && _demoShotsRemaining > 0) {
            var now = System.getTimer();
            if (now >= _demoNextShotTime) {
                System.println("[DEMO] Firing shot, remaining: " + _demoShotsRemaining);
                var result = addShot();
                System.println("[DEMO] Shot result: " + result);
                _demoShotsRemaining--;

                if (_demoShotsRemaining > 0) {
                    // Schedule next shot: 300-600ms interval
                    var shotNum = 6 - _demoShotsRemaining;
                    var nextDelay = 300 + (shotNum * 50);  // Gets slightly slower
                    _demoNextShotTime = now + nextDelay;
                    System.println("[DEMO] Next shot in " + nextDelay + "ms");
                } else {
                    System.println("[DEMO] All shots fired!");
                    _demoMode = false;
                }
            }
        }

        if (_state == STATE_SESSION_ACTIVE && _startTime > 0) {
            var now = System.getTimer();
            _elapsedMs = now - _startTime;
            _elapsedSeconds = _elapsedMs / 1000;

            // IMPORTANT: Keep display on during active session
            // This prevents the watch from going into "gesture off" mode when wrist is tilted
            // (critical for shooters who hold their arm extended, like snipers)
            // We refresh backlight every 3 seconds to balance visibility vs battery
            if (_elapsedSeconds % 3 == 0) {
                if (Attention has :backlight) {
                    Attention.backlight(true);
                }
            }

            // Check time limit enforcement (only in PRIMARY mode)
            if (_watchMode == WATCH_MODE_PRIMARY && _timeLimit > 0 && _elapsedSeconds >= _timeLimit) {
                _sessionCompleted = false;  // Time ran out, not completed by shots
                finishSession();
                return;
            }

            WatchUi.requestUpdate();
        }
    }
    
    // Get remaining time (returns 0 if no limit or if exceeded)
    private function getTimeRemaining() as Number {
        if (_timeLimit <= 0) {
            return 0;
        }
        var remaining = _timeLimit - _elapsedSeconds;
        return remaining > 0 ? remaining : 0;
    }
    
    // Get elapsed time with decimal precision (for display)
    function getElapsedTimeFormatted() as String {
        var secs = _elapsedMs / 1000;
        var ms = (_elapsedMs % 1000) / 100;  // One decimal place
        return secs.format("%d") + "." + ms.format("%d");
    }
    
    // Get watch mode
    function getWatchMode() as WatchMode {
        return _watchMode;
    }
    
    // Check if in primary mode (shot counting enforced)
    function isPrimaryMode() as Boolean {
        return _watchMode == WATCH_MODE_PRIMARY;
    }

    // Called when session starts from phone
    // Called by the app when a phone message requests a session start.
    // Keeps the message handling path separate from the in-view start logic.
    function prepareSession(data as Dictionary) as Void {
        System.println("[RETIC] prepareSession invoked from phone message - queued (preview)");
        // Store payload and populate view fields for preview without starting
        _pendingSession = data;
        // Populate display fields so the preview shows full session info
        _sessionId = data.get("sessionId") != null ? data.get("sessionId").toString() : "";
        _drillName = data.get("drillName") != null ? data.get("drillName").toString() : "Session";
        _drillGoal = data.get("drillGoal") != null ? data.get("drillGoal").toString() : "";
        _drillType = data.get("drillType") != null ? data.get("drillType").toString() : "";
        _inputMethod = data.get("inputMethod") != null ? data.get("inputMethod").toString() : "";
        _distance = data.get("distance") != null ? (data.get("distance") as Number) : 0;
        // Compute total shots: rounds * strings (strings default 1).
        var previewRounds = toNumberCoerce(data.get("rounds"), 0);
        var previewStrings = toNumberCoerce(data.get("strings"), 1);
        _strings = previewStrings;
        if (data.get("maxBullets") != null) {
            _maxBullets = data.get("maxBullets") as Number; // explicit override
        } else if (data.get("bullets") != null) {
            _maxBullets = data.get("bullets") as Number; // explicit override
        } else {
            _maxBullets = (previewRounds > 0) ? (previewRounds * previewStrings) : 0;
        }
        _timeLimit = data.get("timeLimit") != null ? (data.get("timeLimit") as Number) : 0;
        _parTime = data.get("parTime") != null ? (data.get("parTime") as Number) : 0;

        var watchModeStr = data.get("watchMode") != null ? data.get("watchMode").toString() : "primary";
        if (watchModeStr.equals("supplementary")) {
            _watchMode = WATCH_MODE_SUPPLEMENTARY;
        } else {
            _watchMode = WATCH_MODE_PRIMARY;
        }

        // Preview detection config
        if (_shotDetector != null) {
            var detectionVal = data.get("detection");
            System.println("[RETIC-PREVIEW] detection value: " + (detectionVal != null ? "exists" : "NULL"));
            
            if (detectionVal != null && detectionVal instanceof Dictionary) {
                var detectionDict = detectionVal as Dictionary;
                System.println("[RETIC-PREVIEW] ✓ Parsing detection config...");
                _shotDetector.configureFromDict(detectionDict);
                System.println("[RETIC-PREVIEW] ✓ Preview config: " + _shotDetector.getThreshold() + "G");
            } else if (data.get("sensitivity") != null) {
                var sVal = data.get("sensitivity");
                if (sVal instanceof Float) { _shotDetector.setThreshold(sVal); }
                else if (sVal instanceof Number) { _shotDetector.setThreshold(sVal.toFloat()); }
                else if (sVal instanceof Double) { _shotDetector.setThreshold(sVal.toFloat()); }
                System.println("[RETIC-PREVIEW] Legacy preview sensitivity: " + _shotDetector.getThreshold() + "G");
            }
        }

        _lastMsg = "Preview ready - TAP to START";
        _isPreview = true;
        WatchUi.requestUpdate();
    }

    // Return true if a session payload is waiting to be started by the user
    function hasPendingSession() as Boolean {
        return _pendingSession != null;
    }

    // Called by delegate when user taps to accept and start the pending session
    function startPendingSession() as Void {
        if (_pendingSession == null) {
            return;
        }
        var data = _pendingSession as Dictionary;
        _pendingSession = null;
        _isPreview = false;
        
        // Start countdown instead of immediate session start
        startCountdown(data);
    }
    
    // =========================================================================
    // COUNTDOWN - 3, 2, 1, GO! before session starts
    // =========================================================================
    
    private function startCountdown(data as Dictionary) as Void {
        _countdownActive = true;
        _countdownValue = 3;
        _countdownStartTime = System.getTimer();
        _pendingSessionData = data;
        _lastMsg = "";
        
        // Vibrate to signal countdown start
        if (Attention has :vibrate) {
            var vibeData = [new Attention.VibeProfile(50, 100)];
            Attention.vibrate(vibeData);
        }
        
        // Start countdown timer (1 second intervals)
        _countdownTimer = new Timer.Timer();
        _countdownTimer.start(method(:onCountdownTick), 1000, true);
        
        System.println("[RETIC] Countdown started: 3...");
        WatchUi.requestUpdate();
    }
    
    // Countdown timer tick - called every 1 second
    function onCountdownTick() as Void {
        _countdownValue--;
        
        System.println("[RETIC] Countdown: " + _countdownValue);
        
        // Vibrate on each count
        if (Attention has :vibrate) {
            if (_countdownValue > 0) {
                // Short pulse for 3, 2, 1
                var vibeData = [new Attention.VibeProfile(50, 80)];
                Attention.vibrate(vibeData);
            } else {
                // Longer pulse for GO!
                var vibeData = [new Attention.VibeProfile(100, 200)];
                Attention.vibrate(vibeData);
            }
        }
        
        if (_countdownValue <= 0) {
            // Countdown complete - start the actual session
            if (_countdownTimer != null) {
                _countdownTimer.stop();
                _countdownTimer = null;
            }
            _countdownActive = false;
            
            // Now actually start the session
            if (_pendingSessionData != null) {
                var data = _pendingSessionData as Dictionary;
                _pendingSessionData = null;
                actuallyStartSession(data);
            }
        }
        
        WatchUi.requestUpdate();
    }
    
    // Cancel countdown if user backs out
    function cancelCountdown() as Void {
        if (_countdownActive) {
            _countdownActive = false;
            _countdownValue = 0;
            _pendingSessionData = null;
            if (_countdownTimer != null) {
                _countdownTimer.stop();
                _countdownTimer = null;
            }
            _lastMsg = "Countdown cancelled";
            System.println("[RETIC] Countdown cancelled");
            WatchUi.requestUpdate();
        }
    }
    
    // Check if countdown is active (for delegate to block other actions)
    function isCountdownActive() as Boolean {
        return _countdownActive;
    }

    // The actual session start (after countdown completes)
    private function actuallyStartSession(data as Dictionary) as Void {
        startSession(data);
    }

    function startSession(data as Dictionary) as Void {
        _state = STATE_SESSION_ACTIVE;
        _startTime = System.getTimer();
        _elapsedSeconds = 0;
        _elapsedMs = 0;
        _shotsFired = 0;
        _sessionCompleted = false;
        _lastShotTime = _startTime;
        _splitTimes = [];
        _currentPage = PAGE_MAIN;
        _manualOverrides = 0;

        // Keep display on during session - critical for shooters with extended arm positions
        if (Attention has :backlight) {
            Attention.backlight(true);
        }

        // Reset steadiness tracking
        _steadinessResults = [];
        _lastSteadinessGrade = "";
        _lastSteadinessScore = 0;

        // Initialize SessionManager with session config
        var app = Application.getApp() as reticccApp;
        var sessionMgr = app.getSessionManager();
        sessionMgr.startSession(data);
        
        // Extract session data
        _sessionId = data.get("sessionId") != null ? data.get("sessionId").toString() : "";
        _drillName = data.get("drillName") != null ? data.get("drillName").toString() : "Session";
        _drillGoal = data.get("drillGoal") != null ? data.get("drillGoal").toString() : "";
        _drillType = data.get("drillType") != null ? data.get("drillType").toString() : "";
        _inputMethod = data.get("inputMethod") != null ? data.get("inputMethod").toString() : "";
        _distance = data.get("distance") != null ? (data.get("distance") as Number) : 0;
        // Compute max bullets from rounds and strings (rounds==0 => unlimited)
        var roundsVal = data.get("rounds") != null ? (data.get("rounds") as Number) : 0;
        _timeLimit = data.get("timeLimit") != null ? (data.get("timeLimit") as Number) : 0;
        _parTime = data.get("parTime") != null ? (data.get("parTime") as Number) : 0;
        _strings = data.get("strings") != null ? (data.get("strings") as Number) : 1;
        // Set computed max bullets unless explicit maxBullets/bullets provided
        if (data.get("maxBullets") != null) {
            _maxBullets = data.get("maxBullets") as Number;
        } else if (data.get("bullets") != null) {
            _maxBullets = data.get("bullets") as Number;
        } else {
            _maxBullets = (roundsVal > 0) ? (roundsVal * _strings) : 0;
        }
        
        // Parse watch mode from payload
        var watchModeStr = data.get("watchMode") != null ? data.get("watchMode").toString() : "primary";
        if (watchModeStr.equals("supplementary")) {
            _watchMode = WATCH_MODE_SUPPLEMENTARY;
        } else {
            _watchMode = WATCH_MODE_PRIMARY;
        }
        
        // Also check for explicit maxBullets/bullets field
        if (data.get("maxBullets") != null) {
            _maxBullets = data.get("maxBullets") as Number;
        } else if (data.get("bullets") != null) {
            _maxBullets = data.get("bullets") as Number;
        }
        
        // Parse auto-detect settings from payload
        _autoDetectEnabled = (_watchMode == WATCH_MODE_PRIMARY);
        if (data.get("autoDetect") != null) {
            var autoDetectVal = data.get("autoDetect");
            if (autoDetectVal instanceof Boolean) {
                _autoDetectEnabled = autoDetectVal;
            }
        }
        
        System.println("[RETIC] autoDetect: " + _autoDetectEnabled);
        System.println("[RETIC] watchMode: " + _watchMode);
        System.println("[RETIC] shotDetector exists: " + (_shotDetector != null));
        
        // Configure detection from new 'detection' object or legacy 'sensitivity' field
        if (_shotDetector != null) {
            var detectionVal = data.get("detection");
            System.println("[RETIC] detection value type: " + (detectionVal != null ? detectionVal.toString() : "NULL"));
            
            if (detectionVal != null && detectionVal instanceof Dictionary) {
                // New API: full detection config from phone
                var detectionDict = detectionVal as Dictionary;
                System.println("[RETIC] ✓ Detection is Dictionary, parsing...");
                _shotDetector.configureFromDict(detectionDict);
                System.println("[RETIC] ✓ Detection config applied: " + _shotDetector.getThreshold() + "G");
            } else if (data.get("sensitivity") != null) {
                // Legacy API: just sensitivity value
                var sensitivityVal = data.get("sensitivity");
                System.println("[RETIC] Using legacy sensitivity: " + sensitivityVal);
                if (sensitivityVal instanceof Float) {
                    _shotDetector.setThreshold(sensitivityVal);
                } else if (sensitivityVal instanceof Number) {
                    _shotDetector.setThreshold(sensitivityVal.toFloat());
                } else if (sensitivityVal instanceof Double) {
                    _shotDetector.setThreshold(sensitivityVal.toFloat());
                }
                System.println("[RETIC] Legacy sensitivity set to: " + _shotDetector.getThreshold());
            } else {
                System.println("[RETIC] ⚠ No detection config found in payload!");
            }
            
            // Apply VRCV setting if provided
            if (data.get("vrcv") != null) {
                var vrcvVal = data.get("vrcv");
                if (vrcvVal instanceof Boolean) {
                    _shotDetector.setVrcv(vrcvVal);
                }
            }
        }
        
        // ALWAYS start biometrics/timeline tracking for any session
        if (_shotDetector != null) {
            _shotDetector.resetDetections();
            _shotDetector.startMonitoring(_sessionId);  // This starts biometrics + timeline
            System.println("[RETIC] Biometrics/timeline tracking STARTED");

            // Only enable auto shot DETECTION if configured
            if (_autoDetectEnabled && _watchMode == WATCH_MODE_PRIMARY) {
                _shotDetector.setEnabled(true);
                System.println("[RETIC] Auto shot detection ENABLED");
            } else {
                _shotDetector.setEnabled(false);
                System.println("[RETIC] Auto shot detection DISABLED (manual mode)");
            }
        }
        
        System.println("[RETIC] Session started - Mode: " + watchModeStr + ", Rounds: " + _maxBullets + ", Par: " + _parTime + ", AutoDetect: " + _autoDetectEnabled);
        _lastMsg = "Session started";
        WatchUi.requestUpdate();
    }
    
    // Called when session ends from phone (external end)
    function endSession(data as Dictionary) as Void {
        _sessionCompleted = false;  // Phone ended it, not completed by watch
        _state = STATE_SESSION_ENDED;
        _lastMsg = "Session ended";
        WatchUi.requestUpdate();
    }
    
    // Add a shot (called from delegate on tap)
    // Returns :added, :completed, :blocked, or :inactive
    function addShot() as Symbol {
        if (_state != STATE_SESSION_ACTIVE) {
            return :inactive;
        }

        // In PRIMARY mode, enforce shot limits
        if (_watchMode == WATCH_MODE_PRIMARY) {
            if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
                return :blocked;  // Can't add more - at max
            }
        }
        // In SUPPLEMENTARY mode, no limit enforcement - always allow taps

        _shotsFired++;

        // Track manual override if auto-detect is enabled
        if (_autoDetectEnabled) {
            _manualOverrides++;
        }

        // Capture biometrics at shot moment (HR, breathing)
        if (_shotDetector != null) {
            var tracker = _shotDetector.getBiometricsTracker();
            tracker.recordShotBiometrics(_shotsFired);
            
            // ALWAYS try to get steadiness for manual shots
            // Accelerometer keeps running even when auto-detect is off
            var steadinessScore = 0;
            var flinchDetected = false;
            
            var steadinessAnalyzer = _shotDetector.getSteadinessAnalyzer();
            if (steadinessAnalyzer != null) {
                // Analyze the pre-shot window for this manual shot
                var result = steadinessAnalyzer.analyzeShot(System.getTimer(), _shotsFired);
                if (result != null && !result.insufficientData) {
                    steadinessScore = result.steadinessScore.toNumber();
                    flinchDetected = result.flinchDetected;
                    
                    // Store result for UI display and payload building
                    _steadinessResults.add(result);
                    _lastSteadinessGrade = result.gradeString;
                    _lastSteadinessScore = steadinessScore;
                    
                    // Record to SessionManager
                    var app = Application.getApp() as reticccApp;
                    var sessionMgr = app.getSessionManager();
                    sessionMgr.recordSteadinessResult(result);
                    
                    System.println("[RETIC] Manual shot steadiness: " + steadinessScore + "% (" + result.gradeString + ")");
                } else {
                    System.println("[RETIC] Manual shot - insufficient steadiness data (need more accel samples)");
                }
            }
            
            tracker.recordShotForTimeline(_shotsFired, steadinessScore, flinchDetected, false);
            System.println("[RETIC] Captured biometrics for manual shot #" + _shotsFired + " (steadiness=" + steadinessScore + "%)");
        }

        // Record split time
        var now = System.getTimer();
        var splitMs = 0;
        if (_lastShotTime > 0 && _lastShotTime != _startTime) {
            splitMs = now - _lastShotTime;
            _splitTimes.add(splitMs);
        }
        _lastShotTime = now;

        // Record to SessionManager for payload building
        var app = Application.getApp() as reticccApp;
        var sessionMgr = app.getSessionManager();
        sessionMgr.recordShot(now - _startTime, splitMs);
        if (_autoDetectEnabled) {
            sessionMgr.recordManualOverride();
        }

        // Trigger visual flash feedback
        _shotFlashActive = true;
        if (_shotFlashTimer != null) {
            _shotFlashTimer.stop();
        }
        _shotFlashTimer = new Timer.Timer();
        _shotFlashTimer.start(method(:onShotFlashEnd), 200, false);

        WatchUi.requestUpdate();

        // In PRIMARY mode, auto-complete when reaching max bullets
        if (_watchMode == WATCH_MODE_PRIMARY && _maxBullets > 0 && _shotsFired >= _maxBullets) {
            _sessionCompleted = true;
            sendResultsToPhone();
            return :completed;
        }

        return :added;
    }
    
    // Record a split time without incrementing shot count (for supplementary mode)
    function recordSplit() as Void {
        if (_state != STATE_SESSION_ACTIVE) {
            return;
        }
        
        var now = System.getTimer();
        if (_lastShotTime > 0) {
            var splitMs = now - _lastShotTime;
            _splitTimes.add(splitMs);
        }
        _lastShotTime = now;
        
        // Visual feedback
        _shotFlashActive = true;
        if (_shotFlashTimer != null) {
            _shotFlashTimer.stop();
        }
        _shotFlashTimer = new Timer.Timer();
        _shotFlashTimer.start(method(:onShotFlashEnd), 200, false);
        
        WatchUi.requestUpdate();
    }
    
    // Callback when shot detector detects a shot automatically
    function onAutoShotDetected() as Void {
        if (_state != STATE_SESSION_ACTIVE) {
            return;
        }

        // In PRIMARY mode, auto-detected shots count toward limit
        if (_watchMode == WATCH_MODE_PRIMARY) {
            // Check if we're already at max
            if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
                return;  // Don't add more shots
            }

            _shotsFired++;

            // Capture biometrics at shot moment (HR, breathing)
            if (_shotDetector != null) {
                var tracker = _shotDetector.getBiometricsTracker();
                tracker.recordShotBiometrics(_shotsFired);
                System.println("[RETIC] Captured biometrics for auto-detected shot #" + _shotsFired);
            }

            // Record split time
            var now = System.getTimer();
            var splitMs = 0;
            if (_lastShotTime > 0 && _lastShotTime != _startTime) {
                splitMs = now - _lastShotTime;
                _splitTimes.add(splitMs);
            }
            _lastShotTime = now;

            // Record to SessionManager for payload building
            var app = Application.getApp() as reticccApp;
            var sessionMgr = app.getSessionManager();
            sessionMgr.recordShot(now - _startTime, splitMs);

            // Trigger visual flash feedback
            _shotFlashActive = true;
            if (_shotFlashTimer != null) {
                _shotFlashTimer.stop();
            }
            _shotFlashTimer = new Timer.Timer();
            _shotFlashTimer.start(method(:onShotFlashEnd), 200, false);

            WatchUi.requestUpdate();

            // Check if we've reached max bullets
            if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
                _sessionCompleted = true;
                sendResultsToPhone();
            }
        }
    }
    
    // Remove last shot (undo) - for correcting false positives from auto-detect
    function removeLastShot() as Symbol {
        if (_state != STATE_SESSION_ACTIVE) {
            return :inactive;
        }

        if (_shotsFired <= 0) {
            return :blocked;
        }

        _shotsFired--;
        _manualOverrides++;  // Track correction

        // Remove last split time if any
        if (_splitTimes.size() > 0) {
            _splitTimes = _splitTimes.slice(0, _splitTimes.size() - 1) as Array<Number>;
        }

        // Remove from SessionManager as well
        var app = Application.getApp() as reticccApp;
        var sessionMgr = app.getSessionManager();
        sessionMgr.removeLastShot();

        // Visual feedback - different flash
        _shotFlashActive = true;
        if (_shotFlashTimer != null) {
            _shotFlashTimer.stop();
        }
        _shotFlashTimer = new Timer.Timer();
        _shotFlashTimer.start(method(:onShotFlashEnd), 200, false);

        // Haptic feedback (triple short pulse for undo)
        if (Attention has :vibrate) {
            var vibeData = [
                new Attention.VibeProfile(50, 30),
                new Attention.VibeProfile(0, 30),
                new Attention.VibeProfile(50, 30),
                new Attention.VibeProfile(0, 30),
                new Attention.VibeProfile(50, 30)
            ];
            Attention.vibrate(vibeData);
        }
        
        WatchUi.requestUpdate();
        return :removed;
    }
    
    // Calculate average split time in ms
    private function calculateAvgSplit() as Number {
        if (_splitTimes.size() == 0) {
            return 0;
        }
        var total = 0;
        for (var i = 0; i < _splitTimes.size(); i++) {
            total += _splitTimes[i];
        }
        return total / _splitTimes.size();
    }
    
    // Timer callback to end shot flash
    function onShotFlashEnd() as Void {
        _shotFlashActive = false;
        WatchUi.requestUpdate();
    }
    
    // Send results back to phone and end session (TWO-PHASE SYNC)
    // Now delegates to centralized app.onSessionComplete() which uses
    // SessionManager + PayloadBuilder for compact, consistent payloads
    function sendResultsToPhone() as Void {
        var app = Application.getApp() as reticccApp;

        // Update SessionManager with final hit count
        var sessionMgr = app.getSessionManager();
        sessionMgr.setHits(_shotsFired);  // For now, hits = shots fired

        System.println("[VIEW] sendResultsToPhone - delegating to app.onSessionComplete()");
        System.println("[VIEW] Shots: " + _shotsFired + ", Completed: " + _sessionCompleted);

        // Delegate to centralized session completion handler
        // This uses SessionManager data + PayloadBuilder for two-phase sync
        app.onSessionComplete(_sessionCompleted, _shotDetector);
        
        // Move to ended state
        _state = STATE_SESSION_ENDED;
        _lastMsg = "Syncing...";
        WatchUi.requestUpdate();
    }
    
    // Build steadiness results dictionary for sending to phone
    private function buildSteadinessResults() as Dictionary {
        if (_steadinessResults.size() == 0) {
            return {
                "enabled" => _autoDetectEnabled,
                "shotCount" => 0
            };
        }
        
        // Calculate averages
        var totalScore = 0.0;
        var flinchCount = 0;
        var shotScores = [] as Array<Dictionary>;
        
        for (var i = 0; i < _steadinessResults.size(); i++) {
            var r = _steadinessResults[i];
            totalScore += r.steadinessScore;
            if (r.flinchDetected) { flinchCount++; }
            shotScores.add(r.toDict());
        }
        
        var avgScore = totalScore / _steadinessResults.size();
        
        // Get trend and advanced metrics from analyzer
        var trend = "stable";
        var recoilConsistency = 0.0;
        var flinchRate = 0.0;
        if (_shotDetector != null) {
            var analyzer = _shotDetector.getSteadinessAnalyzer();
            trend = analyzer.getSessionTrend();
            recoilConsistency = analyzer.getRecoilConsistency();
            flinchRate = analyzer.getFlinchRate();
        }
        
        // Grade distribution
        var gradeCount = {"A+" => 0, "A" => 0, "B" => 0, "C" => 0, "D" => 0, "F" => 0};
        for (var i = 0; i < _steadinessResults.size(); i++) {
            var g = _steadinessResults[i].gradeString;
            var count = gradeCount.get(g) as Number;
            if (count != null) {
                gradeCount.put(g, count + 1);
            }
        }
        
        // Find best and worst shots
        var bestShotIdx = 0;
        var worstShotIdx = 0;
        var bestScore = 0.0;
        var worstScore = 100.0;
        for (var i = 0; i < _steadinessResults.size(); i++) {
            var score = _steadinessResults[i].steadinessScore;
            if (score > bestScore) { bestScore = score; bestShotIdx = i + 1; }
            if (score < worstScore) { worstScore = score; worstShotIdx = i + 1; }
        }
        
        return {
            "enabled" => true,
            "shotCount" => _steadinessResults.size(),
            "avgScore" => avgScore.toNumber(),
            "trend" => trend,
            "gradeDistribution" => gradeCount,
            "shots" => shotScores,
            // Advanced analytics
            "flinchCount" => flinchCount,
            "flinchRate" => flinchRate.toNumber(),
            "recoilConsistency" => recoilConsistency.toNumber(),
            "bestShot" => bestShotIdx,
            "bestScore" => bestScore.toNumber(),
            "worstShot" => worstShotIdx,
            "worstScore" => worstScore.toNumber()
        };
    }
    
    // Build biometrics results dictionary for sending to phone
    private function buildBiometricsResults() as Dictionary {
        if (_shotDetector == null) {
            return {
                "enabled" => false
            };
        }
        
        var tracker = _shotDetector.getBiometricsTracker();
        
        // Get compact timeline (only need shots, not full timelines)
        var timeline = tracker.getCompactTimeline(120);
        var summary = tracker.getSessionSummary();
        
        // NOTE: hrTimeline and breathTimeline removed to reduce payload size
        // The phone was not receiving SESSION_RESULT due to Garmin's ~8-16KB message limit
        // We still have per-shot biometrics which contains HR/breath at each shot
        return {
            "enabled" => true,
            "summary" => summary,
            "shotBiometrics" => timeline.get("shots")   // Per-shot HR and breathing
        };
    }
    
    // Build performance analytics for session results
    private function buildPerformanceAnalytics(totalElapsedMs as Number) as Dictionary {
        // First shot time (time from start to first shot)
        var firstShotTime = 0;
        if (_splitTimes.size() > 0) {
            // First split is actually first shot time (from session start)
            // Need to calculate from elapsed - sum of later splits
            var sumSplits = 0;
            for (var i = 0; i < _splitTimes.size(); i++) {
                sumSplits += _splitTimes[i];
            }
            firstShotTime = totalElapsedMs - sumSplits;
        } else if (_shotsFired > 0) {
            firstShotTime = totalElapsedMs;  // Only one shot, that's the first shot time
        }
        
        // Best and worst splits
        var bestSplit = 0;
        var worstSplit = 0;
        var splitStdDev = 0.0;
        
        if (_splitTimes.size() > 0) {
            bestSplit = _splitTimes[0];
            worstSplit = _splitTimes[0];
            
            for (var i = 0; i < _splitTimes.size(); i++) {
                if (_splitTimes[i] < bestSplit) { bestSplit = _splitTimes[i]; }
                if (_splitTimes[i] > worstSplit) { worstSplit = _splitTimes[i]; }
            }
            
            // Calculate standard deviation of splits (consistency)
            if (_splitTimes.size() >= 2) {
                var avgSplit = calculateAvgSplit();
                var variance = 0.0;
                for (var i = 0; i < _splitTimes.size(); i++) {
                    var diff = _splitTimes[i] - avgSplit;
                    variance += (diff * diff).toFloat();
                }
                splitStdDev = Math.sqrt(variance / _splitTimes.size()).toFloat();
            }
        }
        
        // Shots per minute
        var shotsPerMinute = 0.0;
        if (totalElapsedMs > 0 && _shotsFired > 0) {
            shotsPerMinute = (_shotsFired.toFloat() / totalElapsedMs * 60000);
        }
        
        // Par delta
        var parDelta = 0.0;
        if (_parTime > 0) {
            parDelta = (totalElapsedMs.toFloat() / 1000.0) - _parTime;
        }
        
        // Warmup vs rest analysis (first 3 shots vs rest)
        var warmupAvg = 0.0;
        var restAvg = 0.0;
        if (_steadinessResults.size() >= 4) {
            // First 3 shots
            for (var i = 0; i < 3 && i < _steadinessResults.size(); i++) {
                warmupAvg += _steadinessResults[i].steadinessScore;
            }
            warmupAvg = warmupAvg / 3;
            
            // Rest of shots
            var restCount = 0;
            for (var i = 3; i < _steadinessResults.size(); i++) {
                restAvg += _steadinessResults[i].steadinessScore;
                restCount++;
            }
            if (restCount > 0) {
                restAvg = restAvg / restCount;
            }
        }
        
        // Last 3 shots average (fatigue indicator)
        var lastThreeAvg = 0.0;
        if (_steadinessResults.size() >= 3) {
            var start = _steadinessResults.size() - 3;
            for (var i = start; i < _steadinessResults.size(); i++) {
                lastThreeAvg += _steadinessResults[i].steadinessScore;
            }
            lastThreeAvg = lastThreeAvg / 3;
        }
        
        return {
            "firstShotTime" => firstShotTime,           // ms to first shot (draw speed)
            "bestSplit" => bestSplit,                   // fastest split (ms)
            "worstSplit" => worstSplit,                 // slowest split (ms)
            "splitStdDev" => splitStdDev.toNumber(),    // consistency (lower = better)
            "shotsPerMinute" => (shotsPerMinute * 10).toNumber(),  // x10 for precision
            "parDelta" => (parDelta * 1000).toNumber(), // ms difference from par
            "warmupAvg" => warmupAvg.toNumber(),        // first 3 shots avg steadiness
            "restAvg" => restAvg.toNumber(),            // remaining shots avg steadiness
            "lastThreeAvg" => lastThreeAvg.toNumber()   // fatigue indicator
        };
    }
    
    // Manually finish session (before hitting max bullets)
    function finishSession() as Void {
        if (_state == STATE_SESSION_ACTIVE) {
            _sessionCompleted = false;  // Manual end = not completed
            
            // Stop shot detection
            if (_shotDetector != null) {
                _shotDetector.stopMonitoring();
            }
            
            sendResultsToPhone();
        }
    }
    
    // Reset to idle state
    function resetToIdle() as Void {
        _state = STATE_IDLE;
        _elapsedSeconds = 0;
        _elapsedMs = 0;
        _startTime = 0;
        _shotsFired = 0;
        _lastMsg = "";
        _currentPage = PAGE_MAIN;
        _sessionCompleted = false;
        _splitTimes = [];
        _lastShotTime = 0;
        _parTime = 0;
        _autoDetectEnabled = false;
        _manualOverrides = 0;

        // Reset steadiness data
        _steadinessResults = [];
        _lastSteadinessGrade = "";
        _lastSteadinessScore = 0;

        // Reset SessionManager
        var app = Application.getApp() as reticccApp;
        var sessionMgr = app.getSessionManager();
        sessionMgr.reset();

        // Stop shot detection
        if (_shotDetector != null) {
            _shotDetector.stopMonitoring();
            _shotDetector.setEnabled(false);
        }

        WatchUi.requestUpdate();
    }

    // Set connection status
    function setConnected(connected as Boolean) as Void {
        _connected = connected;
        WatchUi.requestUpdate();
    }
    
    // Set last message (for status updates from app)
    function setLastMsg(msg as String) as Void {
        _lastMsg = msg;
        _errorMsg = "";  // Clear error when setting normal message
        WatchUi.requestUpdate();
    }
    
    // Set error message (full error details for display)
    function setErrorMsg(msg as String) as Void {
        _errorMsg = msg;
        _lastMsg = "";  // Clear normal msg when showing error
        WatchUi.requestUpdate();
    }
    
    // Clear error message
    function clearError() as Void {
        _errorMsg = "";
        WatchUi.requestUpdate();
    }
    
    // Update weather data (can be sent from phone or read from sensors)
    function setWeather(wind as Number, windDir as String, temp as Number) as Void {
        _windSpeed = wind;
        _windDirection = windDir;
        _temperature = temp;
        _hasTemperature = true;
        WatchUi.requestUpdate();
    }
    
    // Update full environment data
    function setEnvironment(data as Dictionary) as Void {
        if (data.get("windSpeed") != null) { _windSpeed = data.get("windSpeed") as Number; }
        if (data.get("windDirection") != null) { _windDirection = data.get("windDirection").toString(); }
        if (data.get("windAngle") != null) { _windAngle = data.get("windAngle") as Number; }
        if (data.get("temperature") != null) { 
            _temperature = data.get("temperature") as Number; 
            _hasTemperature = true;
        }
        if (data.get("humidity") != null) { 
            _humidity = data.get("humidity") as Number; 
            _hasHumidity = true;
        }
        if (data.get("pressure") != null) { 
            _pressure = data.get("pressure") as Number; 
            _hasPressure = true;
        }
        if (data.get("lightLevel") != null) { _lightLevel = data.get("lightLevel") as Number; }
        if (data.get("altitude") != null) { _altitude = data.get("altitude") as Number; }
        WatchUi.requestUpdate();
    }
    
    // Update personal/profile data
    function setPersonalData(data as Dictionary) as Void {
        if (data.get("name") != null) { _shooterName = data.get("name").toString(); }
        if (data.get("totalSessions") != null) { _totalSessions = data.get("totalSessions") as Number; }
        if (data.get("totalShots") != null) { _totalShots = data.get("totalShots") as Number; }
        if (data.get("bestAccuracy") != null) { _bestAccuracy = data.get("bestAccuracy") as Number; }
        WatchUi.requestUpdate();
    }
    
    // Get shot detector for external access (calibration, settings)
    function getShotDetector() as ShotDetector? {
        return _shotDetector;
    }
    
    // Check if auto-detection is currently enabled for session
    function isAutoDetectEnabled() as Boolean {
        return _autoDetectEnabled;
    }

    // Enable demo mode - auto-fires shots at intervals
    function startDemoMode(shotCount as Number, delayMs as Number) as Void {
        _demoMode = true;
        _demoShotsRemaining = shotCount;
        _demoNextShotTime = System.getTimer() + delayMs;
        System.println("[DEMO] Demo mode enabled: " + shotCount + " shots, first in " + delayMs + "ms");

        // Ensure timer is running (it may have been stopped by menu's onHide)
        if (_timer == null) {
            _timer = new Timer.Timer();
            _timer.start(method(:onTimerTick), 100, true);
            System.println("[DEMO] Timer restarted for demo mode");
        }
    }

    // Stop demo mode
    function stopDemoMode() as Void {
        _demoMode = false;
        _demoShotsRemaining = 0;
    }
    
    // Page navigation (called from delegate) - wraps around
    function pageUp() as Void {
        if (_state == STATE_SESSION_ACTIVE) {
            if (_currentPage == PAGE_MAIN) {
                _currentPage = PAGE_PERSONAL;
            } else if (_currentPage == PAGE_ENVIRONMENT) {
                _currentPage = PAGE_MAIN;
            } else if (_currentPage == PAGE_PERSONAL) {
                _currentPage = PAGE_ENVIRONMENT;  // Wrap around
            }
            WatchUi.requestUpdate();
        }
    }
    
    function pageDown() as Void {
        if (_state == STATE_SESSION_ACTIVE) {
            if (_currentPage == PAGE_MAIN) {
                _currentPage = PAGE_ENVIRONMENT;
            } else if (_currentPage == PAGE_PERSONAL) {
                _currentPage = PAGE_MAIN;
            } else if (_currentPage == PAGE_ENVIRONMENT) {
                _currentPage = PAGE_PERSONAL;  // Wrap around
            }
            WatchUi.requestUpdate();
        }
    }
    
    function getCurrentPage() as SessionPage {
        return _currentPage;
    }

    // Format seconds to MM:SS
    private function formatTime(seconds as Number) as String {
        var mins = seconds / 60;
        var secs = seconds % 60;
        return mins.format("%02d") + ":" + secs.format("%02d");
    }

    // Get current state (for delegate)
    function getState() as SessionState {
        return _state;
    }

    // Get current session ID
    function getSessionId() as String {
        return _sessionId;
    }

    // Get shots fired count
    function getShotsFired() as Number {
        return _shotsFired;
    }

    // Main update - choose which screen to show
    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        
        // Enable anti-aliasing for smoother graphics (API 3.2.0+)
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(true);
        }

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var centerY = height / 2;

        if (_isPreview) {
            // Render preview with session data + countdown indicator
            drawPreviewWithCountdownReady(dc, width, height, centerX, centerY);
            return;
        }

        // =====================================================================
        // COUNTDOWN OVERLAY - 3, 2, 1, GO!
        // =====================================================================
        if (_countdownActive) {
            drawCountdownOverlay(dc, width, height, centerX, centerY);
            return;
        }

        if (_state == STATE_SESSION_ACTIVE) {
            // Draw based on current page
            if (_currentPage == PAGE_PERSONAL) {
                drawPersonalPage(dc, width, height, centerX, centerY);
            } else if (_currentPage == PAGE_ENVIRONMENT) {
                drawEnvironmentPage(dc, width, height, centerX, centerY);
            } else {
                drawActiveSession(dc, width, height, centerX, centerY);
            }
        } else if (_state == STATE_SESSION_ENDED) {
            drawSessionEnded(dc, width, height, centerX, centerY);
        } else {
            drawIdleScreen(dc, width, height, centerX, centerY);
        }
    }
    
    // =========================================================================
    // PREVIEW SCREEN - Shows session data with "3" countdown indicator
    // User sees all session info, taps to start countdown
    // =========================================================================
    private function drawPreviewWithCountdownReady(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Dark background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        
        // Get actual font heights for precise positioning
        var fontSmallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var fontTinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var fontXtinyH = dc.getFontHeight(Graphics.FONT_XTINY);
        var fontNumMedH = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        
        var ringRadius = (width < height ? width : height) / 2 - 12;
        
        // Outer ring - tactical aesthetic
        dc.setColor(0x222222, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(4); }
        dc.drawCircle(centerX, centerY, ringRadius);
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        
        // =====================================================================
        // Layout from top to bottom with measured gaps
        // =====================================================================
        var currentY = 18;  // Start near top with margin
        var gap = 4;        // Minimum gap between elements
        
        // Drill name at top
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var drillText = _drillName;
        if (drillText.length() > 18) { drillText = drillText.substring(0, 16) + ".."; }
        dc.drawText(centerX, currentY, Graphics.FONT_SMALL, drillText, Graphics.TEXT_JUSTIFY_CENTER);
        currentY += fontSmallH + gap + 2;
        
        // Timer placeholder (00:00.0)
        dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, currentY, Graphics.FONT_TINY, "00:00.0", Graphics.TEXT_JUSTIFY_CENTER);
        currentY += fontTinyH + gap + 8;
        
        // =====================================================================
        // Session info lines - each with measured height
        // =====================================================================
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var lineGap = fontSmallH + gap;
        
        // Rounds/Bullets
        if (_maxBullets > 0) {
            dc.drawText(centerX, currentY, Graphics.FONT_SMALL, _maxBullets.toString() + " rounds", Graphics.TEXT_JUSTIFY_CENTER);
            currentY += lineGap;
        }
        
        // Distance
        if (_distance > 0) {
            dc.drawText(centerX, currentY, Graphics.FONT_SMALL, _distance.toString() + "m distance", Graphics.TEXT_JUSTIFY_CENTER);
            currentY += lineGap;
        }
        
        // Par time
        if (_parTime > 0) {
            dc.drawText(centerX, currentY, Graphics.FONT_SMALL, "Par: " + _parTime.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
            currentY += lineGap;
        }
        
        // Time limit
        if (_timeLimit > 0) {
            var mins = _timeLimit / 60;
            var secs = _timeLimit % 60;
            var limitStr = mins > 0 ? mins.toString() + "m " + secs.toString() + "s" : secs.toString() + "s";
            dc.drawText(centerX, currentY, Graphics.FONT_SMALL, "Limit: " + limitStr, Graphics.TEXT_JUSTIFY_CENTER);
            currentY += lineGap;
        }
        
        // Watch mode indicator (smaller font)
        dc.setColor(0x666666, Graphics.COLOR_TRANSPARENT);
        var modeText = (_watchMode == WATCH_MODE_SUPPLEMENTARY) ? "Timer Only" : "Shot Counter";
        dc.drawText(centerX, currentY, Graphics.FONT_XTINY, modeText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // Bottom section: Countdown "3" and TAP TO START
        // Position from bottom up to ensure no overlap
        // =====================================================================
        var bottomY = height - 18;  // Bottom margin
        
        // "TAP TO START" at very bottom
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, bottomY - fontXtinyH, Graphics.FONT_XTINY, "TAP TO START", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Orange circle with "3" - positioned above TAP TO START
        var circleRadius = 30;
        var circleY = bottomY - fontXtinyH - gap - 12 - circleRadius;
        
        dc.setColor(0xFF4500, Graphics.COLOR_TRANSPARENT);  // Orange
        dc.fillCircle(centerX, circleY, circleRadius);
        
        // The "3" centered in circle
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, circleY - fontNumMedH / 2, Graphics.FONT_NUMBER_MEDIUM, "3", Graphics.TEXT_JUSTIFY_CENTER);
    }
    
    // =========================================================================
    // COUNTDOWN OVERLAY - 3, 2, 1, GO! with session context visible
    // =========================================================================
    private function drawCountdownOverlay(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Dark background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        
        // Get actual font heights for precise positioning
        var fontSmallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var fontTinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var fontHotH = dc.getFontHeight(Graphics.FONT_NUMBER_THAI_HOT);
        
        var ringRadius = (width < height ? width : height) / 2 - 12;
        var gap = 4;
        
        // Outer ring with countdown progress
        dc.setColor(0x222222, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(6); }
        dc.drawCircle(centerX, centerY, ringRadius);
        
        // Progress arc - shows countdown progress (3=full, 0=empty)
        var progress = _countdownValue.toFloat() / 3.0;
        var arcDegrees = (progress * 360).toNumber();
        if (arcDegrees > 0) {
            var arcColor = 0xFF4500;  // Orange default
            if (_countdownValue == 3) { arcColor = 0xFF4500; }
            else if (_countdownValue == 2) { arcColor = 0xFFAA00; }
            else if (_countdownValue == 1) { arcColor = 0xFFDD00; }
            dc.setColor(arcColor, Graphics.COLOR_TRANSPARENT);
            if (dc has :setPenWidth) { dc.setPenWidth(6); }
            dc.drawArc(centerX, centerY, ringRadius, Graphics.ARC_CLOCKWISE, 90, 90 - arcDegrees);
        }
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        
        // =====================================================================
        // Top section: Drill name + Timer
        // =====================================================================
        var topY = 18;
        
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var drillText = _drillName;
        if (drillText.length() > 18) { drillText = drillText.substring(0, 16) + ".."; }
        dc.drawText(centerX, topY, Graphics.FONT_SMALL, drillText, Graphics.TEXT_JUSTIFY_CENTER);
        topY += fontSmallH + gap;
        
        // Timer placeholder
        dc.setColor(0x666666, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, topY, Graphics.FONT_TINY, "00:00.0", Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // CENTER - Giant countdown number
        // =====================================================================
        var displayText = "";
        var textColor = Graphics.COLOR_WHITE;
        
        if (_countdownValue > 0) {
            displayText = _countdownValue.toString();
            if (_countdownValue == 3) { textColor = 0xFF6644; }
            else if (_countdownValue == 2) { textColor = 0xFFAA44; }
            else { textColor = 0xFFDD44; }
        } else {
            displayText = "GO!";
            textColor = 0x44FF44;  // Green
        }
        
        dc.setColor(textColor, Graphics.COLOR_TRANSPARENT);
        // Center the number vertically (account for font height)
        dc.drawText(centerX, centerY - fontHotH / 2, Graphics.FONT_NUMBER_THAI_HOT, displayText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // Bottom section: Session info + GET READY
        // Position from bottom up
        // =====================================================================
        var bottomY = height - 18;
        
        // "GET READY" at bottom
        dc.setColor(0x888888, Graphics.COLOR_TRANSPARENT);
        var subText = _countdownValue > 0 ? "GET READY" : "STARTING...";
        dc.drawText(centerX, bottomY - fontSmallH, Graphics.FONT_SMALL, subText, Graphics.TEXT_JUSTIFY_CENTER);
        bottomY = bottomY - fontSmallH - gap - 6;
        
        // Compact info line above GET READY
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var infoLine = "";
        if (_maxBullets > 0) {
            infoLine = _maxBullets.toString() + " rds";
        }
        if (_distance > 0) {
            if (infoLine.length() > 0) { infoLine = infoLine + " • "; }
            infoLine = infoLine + _distance.toString() + "m";
        }
        if (_parTime > 0) {
            if (infoLine.length() > 0) { infoLine = infoLine + " • "; }
            infoLine = infoLine + "par " + _parTime.format("%.1f") + "s";
        }
        
        if (infoLine.length() > 0) {
            dc.drawText(centerX, bottomY - fontTinyH, Graphics.FONT_TINY, infoLine, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
    
    // =========================================================================
    // IDLE SCREEN - Tactical scope design
    // =========================================================================
    private function drawIdleScreen(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        
        // =====================================================================
        // Outer ring - scope aesthetic
        // =====================================================================
        var ringRadius = (width < height ? width : height) / 2 - 15;
        
        // Outer glow/ring
        dc.setColor(0x1A1A1A, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(8); }
        dc.drawCircle(centerX, centerY, ringRadius);
        
        // Main ring
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(3); }
        dc.drawCircle(centerX, centerY, ringRadius);
        
        // Accent arc - top (orange/red accent)
        dc.setColor(0xFF4500, Graphics.COLOR_TRANSPARENT);  // Orange-red
        if (dc has :setPenWidth) { dc.setPenWidth(3); }
        dc.drawArc(centerX, centerY, ringRadius, Graphics.ARC_CLOCKWISE, 70, 110);
        
        // =====================================================================
        // Crosshair lines - tactical feel
        // =====================================================================
        dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        
        // Top line
        dc.drawLine(centerX, 35, centerX, centerY - 55);
        // Bottom line  
        dc.drawLine(centerX, centerY + 55, centerX, height - 35);
        // Left line
        dc.drawLine(35, centerY, centerX - 55, centerY);
        // Right line
        dc.drawLine(centerX + 55, centerY, width - 35, centerY);
        
        // Small tick marks
        var tickLen = 6;
        dc.drawLine(centerX - tickLen, centerY - 40, centerX + tickLen, centerY - 40);
        dc.drawLine(centerX - tickLen, centerY + 40, centerX + tickLen, centerY + 40);
        dc.drawLine(centerX - 40, centerY - tickLen, centerX - 40, centerY + tickLen);
        dc.drawLine(centerX + 40, centerY - tickLen, centerX + 40, centerY + tickLen);
        
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        
        // =====================================================================
        // Center content area
        // =====================================================================
        
        // Brand name
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, centerY - 28, Graphics.FONT_MEDIUM, "RETICLE", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Time - larger, prominent
        var clockTime = System.getClockTime();
        var timeStr = clockTime.hour.format("%02d") + ":" + clockTime.min.format("%02d");
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, centerY + 2, Graphics.FONT_LARGE, timeStr, Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // Bottom info area
        // =====================================================================
        var bottomY = height - 55;
        
        // Connection indicator
        if (_connected) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(centerX, bottomY, 4);
        } else {
            dc.setColor(0x666666, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(centerX, bottomY, 4);
        }

        // =====================================================================
        // Pending session - center overlay
        // =====================================================================
        if (_pendingSession != null) {
            var pd = _pendingSession as Dictionary;
            var pName = pd.get("drillName") != null ? pd.get("drillName").toString() : "Ready";
            var pRounds = toNumberCoerce(pd.get("rounds"), 0);
            var pStrings = toNumberCoerce(pd.get("strings"), 1);
            var pAuto = pd.get("autoDetect") != null ? (pd.get("autoDetect") as Boolean) : false;

            if (pName.length() > 14) { pName = pName.substring(0, 12) + ".."; }

            // Dark overlay for center
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.fillCircle(centerX, centerY, 70);
            
            // Accent ring around content
            dc.setColor(0xFF4500, Graphics.COLOR_TRANSPARENT);
            if (dc has :setPenWidth) { dc.setPenWidth(2); }
            dc.drawCircle(centerX, centerY, 68);
            if (dc has :setPenWidth) { dc.setPenWidth(1); }
            
            // Session name
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, centerY - 30, Graphics.FONT_TINY, pName, Graphics.TEXT_JUSTIFY_CENTER);
            
            // Shot count
            var totalShots = (pRounds > 0) ? (pRounds * pStrings) : 0;
            var shotStr = totalShots > 0 ? totalShots.toString() : "∞";
            dc.setColor(0xFF4500, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, centerY - 8, Graphics.FONT_MEDIUM, shotStr, Graphics.TEXT_JUSTIFY_CENTER);
            
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, centerY + 18, Graphics.FONT_XTINY, pAuto ? "AUTO DETECT" : "MANUAL", Graphics.TEXT_JUSTIFY_CENTER);
            
            // Pulsing start hint
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, centerY + 38, Graphics.FONT_XTINY, "▶ START", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
    
    // Draw wind direction arrow inside circle (kept for potential future use)
    private function drawWindArrow(dc as Dc, cx as Number, cy as Number, radius as Number, angleDeg as Number) as Void {
        // Convert to radians (0° = North = up, clockwise)
        var angleRad = (angleDeg - 90) * Math.PI / 180.0;
        
        // Arrow tip (pointing in wind direction)
        var tipX = cx + (radius * Math.cos(angleRad)).toNumber();
        var tipY = cy + (radius * Math.sin(angleRad)).toNumber();
        
        // Arrow tail (opposite side)
        var tailX = cx - (radius * 0.5 * Math.cos(angleRad)).toNumber();
        var tailY = cy - (radius * 0.5 * Math.sin(angleRad)).toNumber();
        
        // Draw arrow line
        if (dc has :setPenWidth) {
            dc.setPenWidth(3);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(tailX, tailY, tipX, tipY);
        
        // Arrow head
        dc.fillCircle(tipX, tipY, 4);
        
        if (dc has :setPenWidth) {
            dc.setPenWidth(1);
        }
    }
    
    // =========================================================================
    // ACTIVE SESSION - Adapts based on watchMode (PRIMARY vs SUPPLEMENTARY)
    // =========================================================================
    private function drawActiveSession(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Calculate safe area for round display (inset from edges)
        var margin = width / 10;
        var safeWidth = width - (margin * 2);
        var safeTop = margin;
        var safeBottom = height - margin;
        
        // Mode indicator and drill name at top
        if (_watchMode == WATCH_MODE_SUPPLEMENTARY) {
            // SUPPLEMENTARY MODE - Timer focused
            drawSupplementarySession(dc, width, height, centerX, centerY, margin, safeWidth, safeTop, safeBottom);
        } else {
            // PRIMARY MODE - Shot counter focused
            drawPrimarySession(dc, width, height, centerX, centerY, margin, safeWidth, safeTop, safeBottom);
        }
        
        // Recording indicator (pulsing) - top left
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(margin + 10, margin + 10, 5);
        
        // Page indicator dots at bottom
        drawPageIndicator(dc, width, height, PAGE_MAIN);
    }
    
    // =========================================================================
    // PRIMARY MODE - Shot Counter Screen - Tactical Design
    // =========================================================================
    private function drawPrimarySession(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number, margin as Number, safeWidth as Number, safeTop as Number, safeBottom as Number) as Void {
        
        // =====================================================================
        // Outer scope ring - tactical aesthetic (matches idle screen)
        // =====================================================================
        var ringRadius = (width < height ? width : height) / 2 - 12;
        
        // Subtle outer ring
        dc.setColor(0x222222, Graphics.COLOR_TRANSPARENT);
        if (dc has :setPenWidth) { dc.setPenWidth(4); }
        dc.drawCircle(centerX, centerY, ringRadius);
        if (dc has :setPenWidth) { dc.setPenWidth(1); }
        
        // Progress arc - shows shots fired vs total (orange accent)
        if (_maxBullets > 0) {
            var progress = _shotsFired.toFloat() / _maxBullets.toFloat();
            if (progress > 1.0) { progress = 1.0; }
            var arcDegrees = (progress * 360).toNumber();
            if (arcDegrees > 0) {
                dc.setColor(0xFF4500, Graphics.COLOR_TRANSPARENT);  // Orange
                if (dc has :setPenWidth) { dc.setPenWidth(4); }
                dc.drawArc(centerX, centerY, ringRadius, Graphics.ARC_CLOCKWISE, 90, 90 - arcDegrees);
                if (dc has :setPenWidth) { dc.setPenWidth(1); }
            }
        }
        
        // =====================================================================
        // Top - Drill name (compact at very top)
        // =====================================================================
        var topY = height * 8 / 100;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var drillText = _drillName;
        if (drillText.length() > 16) { drillText = drillText.substring(0, 14) + ".."; }
        dc.drawText(centerX, topY, Graphics.FONT_XTINY, drillText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // Distance badge - more gap below drill name
        if (_distance > 0) {
            dc.setColor(0x666666, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, topY + 24, Graphics.FONT_XTINY, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // CENTER - Giant shot count (true center)
        // =====================================================================
        var fontHotHeight = dc.getFontHeight(Graphics.FONT_NUMBER_THAI_HOT);
        var fontTinyHeight = dc.getFontHeight(Graphics.FONT_TINY);
        
        // Center the shot count + "of X" as a group
        var groupHeight = fontHotHeight + 12 + fontTinyHeight;  // shot + gap + "of X"
        var shotY = centerY - groupHeight / 2 - 10;  // Shift up slightly
        
        // Shot count number - BIG
        var shotColor = Graphics.COLOR_WHITE;
        if (_shotFlashActive) {
            shotColor = 0xFF4500;  // Flash orange on shot
        } else if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            shotColor = Graphics.COLOR_GREEN;  // Complete = green
        }
        dc.setColor(shotColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, shotY, Graphics.FONT_NUMBER_THAI_HOT, _shotsFired.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        
        // "of X" to the right of center
        if (_maxBullets > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX + 55, centerY - fontTinyHeight / 2, Graphics.FONT_TINY, "of " + _maxBullets.toString(), Graphics.TEXT_JUSTIFY_LEFT);
        }
        
        // =====================================================================
        // Timer section - lower, more separation from count
        // =====================================================================
        var timerY = height * 72 / 100;
        
        // Elapsed time - prominent
        var timeText = getElapsedTimeFormatted();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, timerY, Graphics.FONT_MEDIUM, timeText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // Par time comparison (if set) - more gap below timer
        if (_parTime > 0) {
            var parY = timerY + dc.getFontHeight(Graphics.FONT_MEDIUM) + 6;
            var elapsed = _elapsedMs.toFloat() / 1000.0;
            var parDiff = elapsed - _parTime;
            
            if (_shotsFired > 0) {
                // Show difference from par
                var parColor = parDiff <= 0 ? Graphics.COLOR_GREEN : Graphics.COLOR_RED;
                var parSign = parDiff <= 0 ? "" : "+";
                dc.setColor(parColor, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, parY, Graphics.FONT_TINY, parSign + parDiff.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                // Show par target
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, parY, Graphics.FONT_TINY, "Par: " + _parTime.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
        
        // =====================================================================
        // Steadiness indicator - bottom left (pushed out more)
        // =====================================================================
        if (_autoDetectEnabled && _lastSteadinessGrade.length() > 0) {
            var steadyX = width * 20 / 100;
            var steadyY = height * 78 / 100;
            
            // Grade with color
            var gradeColor = Graphics.COLOR_WHITE;
            if (_lastSteadinessGrade.equals("A+") || _lastSteadinessGrade.equals("A")) {
                gradeColor = Graphics.COLOR_GREEN;
            } else if (_lastSteadinessGrade.equals("B")) {
                gradeColor = Graphics.COLOR_YELLOW;
            } else if (_lastSteadinessGrade.equals("C") || _lastSteadinessGrade.equals("D")) {
                gradeColor = 0xFF4500;
            } else {
                gradeColor = Graphics.COLOR_RED;
            }
            
            dc.setColor(gradeColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(steadyX, steadyY, Graphics.FONT_MEDIUM, _lastSteadinessGrade, Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(steadyX, steadyY + 26, Graphics.FONT_XTINY, "STEADY", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // Split time - bottom right (pushed out more)
        // =====================================================================
        if (_splitTimes.size() > 0) {
            var splitX = width * 80 / 100;
            var splitY = height * 78 / 100;
            
            var lastSplit = _splitTimes[_splitTimes.size() - 1];
            var splitSec = lastSplit.toFloat() / 1000.0;
            
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(splitX, splitY, Graphics.FONT_MEDIUM, splitSec.format("%.2f"), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(splitX, splitY + 26, Graphics.FONT_XTINY, "SPLIT", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // Status indicator - complete (at very bottom)
        // =====================================================================
        if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - 24, Graphics.FONT_XTINY, "● COMPLETE", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // =====================================================================
        // DEBUG: Show detection threshold and last magnitude (top right)
        // =====================================================================
        if (_autoDetectEnabled && _shotDetector != null) {
            var dbgX = width - margin - 5;
            var dbgY = margin + 25;
            var thresh = _shotDetector.getThreshold();
            var lastMag = _shotDetector.getLastMagnitude();
            var adaptive = _shotDetector.getAdaptiveThreshold();

            // Show: "T:3.5 A:3.2 M:1.8"
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dbgX, dbgY, Graphics.FONT_XTINY, "T:" + thresh.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);
            dc.drawText(dbgX, dbgY + 14, Graphics.FONT_XTINY, "A:" + adaptive.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);

            // Magnitude - color based on threshold
            var magColor = Graphics.COLOR_DK_GRAY;
            if (lastMag >= thresh) {
                magColor = Graphics.COLOR_GREEN;  // Would trigger
            } else if (lastMag >= thresh * 0.7) {
                magColor = Graphics.COLOR_YELLOW;  // Close
            }
            dc.setColor(magColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dbgX, dbgY + 28, Graphics.FONT_XTINY, "M:" + lastMag.format("%.1f"), Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }
    
    // =========================================================================
    // SUPPLEMENTARY MODE - Timer-focused, optional taps
    // Uses font heights to calculate proper spacing and prevent collisions
    // =========================================================================
    private function drawSupplementarySession(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number, margin as Number, safeWidth as Number, safeTop as Number, safeBottom as Number) as Void {
        // =====================================================================
        // STEP 1: Get actual font heights for precise layout
        // =====================================================================
        var fontSmallH = dc.getFontHeight(Graphics.FONT_SMALL);
        var fontTinyH = dc.getFontHeight(Graphics.FONT_TINY);
        var fontXtinyH = dc.getFontHeight(Graphics.FONT_XTINY);
        var fontHotH = dc.getFontHeight(Graphics.FONT_NUMBER_HOT);
        var padding = 4;
        
        // =====================================================================
        // STEP 2: Calculate vertical zones
        // =====================================================================
        // TOP ZONE: Header + Distance
        var topZoneStart = safeTop;
        var headerY = topZoneStart;
        var distY = headerY + fontSmallH + padding;
        var topZoneEnd = (_distance > 0) ? distY + fontTinyH + padding : headerY + fontSmallH + padding;
        
        // BOTTOM ZONE: Hint
        var bottomZoneEnd = safeBottom;
        var hintY = bottomZoneEnd - fontXtinyH - padding;
        var bottomZoneStart = hintY - padding;
        
        // MIDDLE ZONE: Timer, taps, split
        var middleZoneStart = topZoneEnd;
        var middleZoneEnd = bottomZoneStart;
        var middleZoneHeight = middleZoneEnd - middleZoneStart;
        var middleCenterY = middleZoneStart + (middleZoneHeight / 2);
        
        // =====================================================================
        // STEP 3: Draw TOP ZONE - Header + Distance
        // =====================================================================
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var headerText = _drillName;
        if (headerText.length() > 14) {
            headerText = headerText.substring(0, 12) + "..";
        }
        dc.drawText(centerX, headerY, Graphics.FONT_SMALL, headerText, Graphics.TEXT_JUSTIFY_CENTER);
        
        if (_distance > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, distY, Graphics.FONT_TINY, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // STEP 4: Calculate MIDDLE ZONE layout
        // =====================================================================
        var timerH = fontHotH;
        var tapsH = (_shotsFired > 0) ? fontSmallH : 0;
        var splitH = (_splitTimes.size() > 0) ? fontXtinyH : 0;
        var innerTextTotal = timerH;
        if (tapsH > 0) { innerTextTotal += padding + tapsH; }
        if (splitH > 0) { innerTextTotal += padding + splitH; }
        
        // Arc calculations
        var minDim = (width < height) ? width : height;
        var maxArcRadius = (middleZoneHeight / 2) - 10;
        var arcRadius = minDim / 3;
        if (arcRadius > maxArcRadius) { arcRadius = maxArcRadius; }
        var arcPenWidth = arcRadius / 10;
        if (arcPenWidth < 3) { arcPenWidth = 3; }
        if (arcPenWidth > 8) { arcPenWidth = 8; }
        
        // Position timer so inner content is centered
        var timerY = middleCenterY - (innerTextTotal / 2);
        var tapsY = timerY + timerH + padding;
        var splitY = tapsY + tapsH + padding;
        
        // =====================================================================
        // STEP 5: Draw ARC
        // =====================================================================
        if (dc has :drawArc) {
            if (dc has :setPenWidth) {
                dc.setPenWidth(arcPenWidth);
            }
            
            // Background arc
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(centerX, middleCenterY, arcRadius, Graphics.ARC_COUNTER_CLOCKWISE, 225, -45);
            
            // Progress or decorative arc
            if (_timeLimit > 0) {
                var progress = _elapsedSeconds.toFloat() / _timeLimit.toFloat();
                if (progress > 1.0) { progress = 1.0; }
                var sweepAngle = (270.0 * progress).toNumber();
                var endAngle = 225 - sweepAngle;
                
                if (sweepAngle > 0) {
                    var arcColor = Graphics.COLOR_LT_GRAY;
                    if (progress > 0.75) { arcColor = Graphics.COLOR_WHITE; }
                    if (progress > 0.9) { arcColor = Graphics.COLOR_WHITE; }
                    if (_shotFlashActive) { arcColor = Graphics.COLOR_WHITE; }
                    dc.setColor(arcColor, Graphics.COLOR_TRANSPARENT);
                    dc.drawArc(centerX, middleCenterY, arcRadius, Graphics.ARC_COUNTER_CLOCKWISE, 225, endAngle);
                }
            } else {
                var accentColor = _shotFlashActive ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY;
                dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
                dc.drawArc(centerX, middleCenterY, arcRadius, Graphics.ARC_COUNTER_CLOCKWISE, 225, 180);
            }
            
            if (dc has :setPenWidth) {
                dc.setPenWidth(1);
            }
        }
        
        // =====================================================================
        // STEP 6: Draw TIMER (big number)
        // =====================================================================
        var timerColor = _shotFlashActive ? Graphics.COLOR_LT_GRAY : Graphics.COLOR_WHITE;
        dc.setColor(timerColor, Graphics.COLOR_TRANSPARENT);
        var secs = _elapsedMs / 1000;
        var tenths = (_elapsedMs % 1000) / 100;
        var timeText = secs.format("%02d") + "." + tenths.format("%d");
        dc.drawText(centerX, timerY, Graphics.FONT_NUMBER_HOT, timeText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // STEP 7: Draw TAPS counter (if any)
        // =====================================================================
        if (_shotsFired > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, tapsY, Graphics.FONT_SMALL, "Taps: " + _shotsFired.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // STEP 8: Draw SPLIT time (if any)
        // =====================================================================
        if (_splitTimes.size() > 0) {
            var lastSplit = _splitTimes[_splitTimes.size() - 1];
            var splitSecs = lastSplit.toFloat() / 1000.0;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, splitY, Graphics.FONT_XTINY, "Split: " + splitSecs.format("%.2f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // STEP 9: Draw BOTTOM ZONE - Hint
        // =====================================================================
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, hintY, Graphics.FONT_XTINY, "TAP for split time", Graphics.TEXT_JUSTIFY_CENTER);
    }
    
    // =========================================================================
    // PERSONAL PAGE - Session info and shooter stats (UP from main)
    // =========================================================================
    private function drawPersonalPage(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Calculate safe area for round display
        var margin = width / 10;
        var safeTop = margin;
        var lineHeight = height / 8;  // Proportional line height
        
        // Header with shooter name if available
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (!_shooterName.equals("")) {
            dc.drawText(centerX, safeTop, Graphics.FONT_SMALL, _shooterName, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, safeTop, Graphics.FONT_SMALL, "SESSION", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        var y = safeTop + lineHeight;
        
        var labelValueGap = height / 14;  // Gap between label and value
        
        // Drill name (truncate if too long)
        if (!_drillName.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "DRILL", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var displayName = _drillName.length() > 16 ? _drillName.substring(0, 14) + ".." : _drillName;
            dc.drawText(centerX, y + labelValueGap, Graphics.FONT_TINY, displayName, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
        
        // Goal (truncate if too long)
        if (!_drillGoal.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "GOAL", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var displayGoal = _drillGoal.length() > 16 ? _drillGoal.substring(0, 14) + ".." : _drillGoal;
            dc.drawText(centerX, y + labelValueGap, Graphics.FONT_TINY, displayGoal, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
        
        // Distance and time limit in a row
        var colOffset = width / 4;
        if (_distance > 0 || _timeLimit > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_distance > 0) {
                dc.drawText(centerX - colOffset, y, Graphics.FONT_XTINY, "DIST", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX - colOffset, y + labelValueGap, Graphics.FONT_TINY, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
            }
            if (_timeLimit > 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y, Graphics.FONT_XTINY, "LIMIT", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y + labelValueGap, Graphics.FONT_TINY, formatTime(_timeLimit), Graphics.TEXT_JUSTIFY_CENTER);
            }
            y += lineHeight;
        }
        
        // Shooter stats row (sessions, shots, best accuracy)
        if (_totalSessions > 0 || _totalShots > 0 || _bestAccuracy > 0) {
            y += 5;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            
            if (_totalSessions > 0) {
                dc.drawText(centerX - colOffset, y, Graphics.FONT_XTINY, "SESS", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX - colOffset, y + labelValueGap, Graphics.FONT_XTINY, _totalSessions.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            }
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_totalShots > 0) {
                dc.drawText(centerX, y, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, y + labelValueGap, Graphics.FONT_XTINY, _totalShots.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            }
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_bestAccuracy > 0) {
                dc.drawText(centerX + colOffset, y, Graphics.FONT_XTINY, "BEST", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y + labelValueGap, Graphics.FONT_XTINY, _bestAccuracy.toString() + "%", Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
        
        // Recording indicator
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(margin + 10, margin + 10, 5);
        
        // Timer in corner
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width - margin - 5, safeTop, Graphics.FONT_XTINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_RIGHT);
        
        // Page indicator
        drawPageIndicator(dc, width, height, PAGE_PERSONAL);
    }
    
    // =========================================================================
    // ENVIRONMENT PAGE - Wind, light, weather (DOWN from main)
    // =========================================================================
    private function drawEnvironmentPage(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        var margin = width / 10;
        var colOffset = width / 4;
        var leftCol = centerX - colOffset;
        var rightCol = centerX + colOffset;
        var rowHeight = height / 5;
        
        // Timer top right (proportional)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width - margin - 5, margin, Graphics.FONT_XTINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_RIGHT);
        
        // Recording indicator top left (proportional)
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(margin + 10, margin + 10, 5);
        
        // Header
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, margin, Graphics.FONT_SMALL, "ENVIRON", Graphics.TEXT_JUSTIFY_CENTER);
        
        var envLabelGap = height / 12;  // Gap between label and value
        
        // WIND - top row
        var y = margin + rowHeight;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, y, Graphics.FONT_XTINY, "WIND", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_windSpeed > 0) {
            var windText = _windSpeed.toString() + " m/s  " + _windDirection;
            if (_windAngle > 0) {
                windText = _windSpeed.toString() + " m/s  " + _windAngle.toString() + "°";
            }
            dc.drawText(centerX, y + envLabelGap, Graphics.FONT_SMALL, windText, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, y + envLabelGap, Graphics.FONT_SMALL, "-- m/s", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Middle row: LIGHT and TEMP
        y += rowHeight;
        
        // Light
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y, Graphics.FONT_XTINY, "LIGHT", Graphics.TEXT_JUSTIFY_CENTER);
        var lightText = "--";
        var lightColor = Graphics.COLOR_WHITE;
        if (_lightLevel > 0) {
            if (_lightLevel < 30) { lightText = "LOW"; lightColor = Graphics.COLOR_DK_GRAY; }
            else if (_lightLevel < 70) { lightText = "MED"; lightColor = Graphics.COLOR_LT_GRAY; }
            else { lightText = "HIGH"; lightColor = Graphics.COLOR_WHITE; }
        }
        dc.setColor(lightColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y + envLabelGap, Graphics.FONT_TINY, lightText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // Temp - fixed 0°C bug using _hasTemperature flag
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y, Graphics.FONT_XTINY, "TEMP", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y + envLabelGap, Graphics.FONT_TINY, _hasTemperature ? _temperature.toString() + "°C" : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Bottom row: HUM and PRESS/ALT
        y += rowHeight;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y, Graphics.FONT_XTINY, "HUM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y + envLabelGap, Graphics.FONT_TINY, _humidity > 0 ? _humidity.toString() + "%" : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y, Graphics.FONT_XTINY, "PRESS", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y + envLabelGap, Graphics.FONT_TINY, _pressure > 0 ? _pressure.toString() : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Altitude row (if available)
        if (_altitude > 0) {
            y += rowHeight - 10;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "ALT", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y + envLabelGap, Graphics.FONT_TINY, _altitude.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Page indicator at bottom
        drawPageIndicator(dc, width, height, PAGE_ENVIRONMENT);
    }
    
    // =========================================================================
    // PAGE INDICATOR - Shows current page position (3 dots)
    // =========================================================================
    private function drawPageIndicator(dc as Dc, width as Number, height as Number, currentPage as SessionPage) as Void {
        var margin = width / 10;
        var dotY = height - margin - 5;  // Proportional from bottom
        var dotSpacing = width / 15;     // Proportional spacing
        var dotRadius = 3;
        var startX = (width / 2) - dotSpacing;
        
        // Left dot (Personal)
        dc.setColor(currentPage == PAGE_PERSONAL ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(startX, dotY, currentPage == PAGE_PERSONAL ? dotRadius + 1 : dotRadius);
        
        // Center dot (Main)
        dc.setColor(currentPage == PAGE_MAIN ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(startX + dotSpacing, dotY, currentPage == PAGE_MAIN ? dotRadius + 1 : dotRadius);
        
        // Right dot (Environment)
        dc.setColor(currentPage == PAGE_ENVIRONMENT ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(startX + (dotSpacing * 2), dotY, currentPage == PAGE_ENVIRONMENT ? dotRadius + 1 : dotRadius);
    }
    
    // =========================================================================
    // SESSION ENDED - Clean horizontal layout (max 4 elements spread evenly)
    // =========================================================================
    private function drawSessionEnded(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        var margin = width / 10;
        
        // =====================================================================
        // 1. TOP - "COMPLETE" header
        // =====================================================================
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, margin, Graphics.FONT_SMALL, "COMPLETE", Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // 2. MIDDLE ROW - Spread TIME, SHOTS, SPLIT horizontally
        // =====================================================================
        var hasAvgSplit = _splitTimes.size() > 0;
        
        var labelGap = height / 10;  // Gap between label and value
        
        if (hasAvgSplit) {
            // 3 items: TIME | SHOTS | SPLIT - spread across width
            var col1 = margin + (width - 2 * margin) / 6;
            var col2 = centerX;
            var col3 = width - margin - (width - 2 * margin) / 6;
            
            // TIME (left)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col1, centerY - labelGap, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col1, centerY + 5, Graphics.FONT_TINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
            
            // SHOTS (center)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col2, centerY - labelGap, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var shotsText = _maxBullets > 0 ? _shotsFired.toString() + "/" + _maxBullets.toString() : _shotsFired.toString();
            dc.drawText(col2, centerY + 5, Graphics.FONT_TINY, shotsText, Graphics.TEXT_JUSTIFY_CENTER);
            
            // AVG SPLIT (right)
            var avgSplit = calculateAvgSplit();
            var avgSplitSecs = avgSplit.toFloat() / 1000.0;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col3, centerY - labelGap, Graphics.FONT_XTINY, "SPLIT", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col3, centerY + 5, Graphics.FONT_TINY, avgSplitSecs.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            // 2 items: TIME | SHOTS - spread left and right
            var colLeft = centerX - width / 4;
            var colRight = centerX + width / 4;
            
            // TIME (left)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colLeft, centerY - labelGap, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colLeft, centerY + 5, Graphics.FONT_MEDIUM, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
            
            // SHOTS (right)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colRight, centerY - labelGap, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var shotsText = _maxBullets > 0 ? _shotsFired.toString() + "/" + _maxBullets.toString() : _shotsFired.toString();
            dc.drawText(colRight, centerY + 5, Graphics.FONT_MEDIUM, shotsText, Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // 2.5 STEADINESS SUMMARY - Show average grade if available
        // =====================================================================
        if (_steadinessResults.size() > 0) {
            var steadyY = centerY + labelGap + 20;
            
            // Calculate average score
            var totalScore = 0.0;
            for (var i = 0; i < _steadinessResults.size(); i++) {
                totalScore += _steadinessResults[i].steadinessScore;
            }
            var avgScore = (totalScore / _steadinessResults.size()).toNumber();
            
            // Determine average grade
            var avgGrade = "F";
            if (avgScore >= 95) { avgGrade = "A+"; }
            else if (avgScore >= 85) { avgGrade = "A"; }
            else if (avgScore >= 70) { avgGrade = "B"; }
            else if (avgScore >= 55) { avgGrade = "C"; }
            else if (avgScore >= 40) { avgGrade = "D"; }
            
            // Color code
            var gradeColor = Graphics.COLOR_WHITE;
            if (avgGrade.equals("A+") || avgGrade.equals("A")) {
                gradeColor = Graphics.COLOR_GREEN;
            } else if (avgGrade.equals("B")) {
                gradeColor = Graphics.COLOR_YELLOW;
            } else if (avgGrade.equals("C")) {
                gradeColor = Graphics.COLOR_ORANGE;
            } else {
                gradeColor = Graphics.COLOR_RED;
            }
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, steadyY, Graphics.FONT_XTINY, "STEADINESS", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(gradeColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, steadyY + 15, Graphics.FONT_TINY, avgGrade + " (" + avgScore + ")", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // 3. BOTTOM - Sync status / Error display and tap to reset
        // =====================================================================
        
        // Show FULL ERROR MESSAGE if present (takes priority)
        if (_errorMsg != null && !_errorMsg.equals("")) {
            // Error display - RED, multi-line capable
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            
            // Split error message if too long
            var errorLen = _errorMsg.length();
            if (errorLen > 25) {
                // Find a good split point (space near middle)
                var splitIdx = 0;
                var midPoint = errorLen / 2;
                for (var i = midPoint; i < errorLen && i < midPoint + 10; i++) {
                    if (_errorMsg.substring(i, i + 1).equals(" ") || 
                        _errorMsg.substring(i, i + 1).equals(":") ||
                        _errorMsg.substring(i, i + 1).equals("-")) {
                        splitIdx = i;
                        break;
                    }
                }
                if (splitIdx == 0) {
                    // No good split, try before midpoint
                    for (var i = midPoint; i > 5; i--) {
                        if (_errorMsg.substring(i, i + 1).equals(" ") ||
                            _errorMsg.substring(i, i + 1).equals(":")) {
                            splitIdx = i;
                            break;
                        }
                    }
                }
                
                if (splitIdx > 0) {
                    // Two lines
                    var line1 = _errorMsg.substring(0, splitIdx);
                    var line2 = _errorMsg.substring(splitIdx + 1, errorLen);
                    dc.drawText(centerX, height - margin - 45, Graphics.FONT_XTINY, line1, Graphics.TEXT_JUSTIFY_CENTER);
                    dc.drawText(centerX, height - margin - 30, Graphics.FONT_XTINY, line2, Graphics.TEXT_JUSTIFY_CENTER);
                } else {
                    // Single line with smaller font
                    dc.drawText(centerX, height - margin - 35, Graphics.FONT_XTINY, _errorMsg, Graphics.TEXT_JUSTIFY_CENTER);
                }
            } else {
                // Short error - single line
                dc.drawText(centerX, height - margin - 35, Graphics.FONT_XTINY, _errorMsg, Graphics.TEXT_JUSTIFY_CENTER);
            }
            
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - margin - 10, Graphics.FONT_XTINY, "TAP to clear", Graphics.TEXT_JUSTIFY_CENTER);
        }
        // Show normal sync status
        else if (_lastMsg != null && !_lastMsg.equals("")) {
            var syncColor = Graphics.COLOR_LT_GRAY;
            if (_lastMsg.find("✓") != null || _lastMsg.find("Synced") != null) {
                syncColor = Graphics.COLOR_GREEN;
            } else if (_lastMsg.find("Retry") != null || _lastMsg.find("Syncing") != null) {
                syncColor = Graphics.COLOR_YELLOW;
            } else if (_lastMsg.find("offline") != null || _lastMsg.find("Failed") != null) {
                syncColor = Graphics.COLOR_RED;
            }
            dc.setColor(syncColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - margin - 28, Graphics.FONT_TINY, _lastMsg, Graphics.TEXT_JUSTIFY_CENTER);
            
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - margin - 10, Graphics.FONT_XTINY, "TAP to reset", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - margin - 10, Graphics.FONT_XTINY, "TAP to reset", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
