import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.Time;

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
    
    // Debug
    private var _lastMsg as String = "";

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Dc) as Void {
    }

    function onShow() as Void {
        _timer = new Timer.Timer();
        _timer.start(method(:onTimerTick), 1000, true);
    }
    
    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }
    
    // Timer callback - update elapsed time and check time limit
    function onTimerTick() as Void {
        if (_state == STATE_SESSION_ACTIVE && _startTime > 0) {
            var now = System.getTimer();
            _elapsedMs = now - _startTime;
            _elapsedSeconds = _elapsedMs / 1000;
            
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
        
        // Extract session data
        _sessionId = data.get("sessionId") != null ? data.get("sessionId").toString() : "";
        _drillName = data.get("drillName") != null ? data.get("drillName").toString() : "Session";
        _drillGoal = data.get("drillGoal") != null ? data.get("drillGoal").toString() : "";
        _drillType = data.get("drillType") != null ? data.get("drillType").toString() : "";
        _inputMethod = data.get("inputMethod") != null ? data.get("inputMethod").toString() : "";
        _distance = data.get("distance") != null ? (data.get("distance") as Number) : 0;
        _maxBullets = data.get("rounds") != null ? (data.get("rounds") as Number) : 0;
        _timeLimit = data.get("timeLimit") != null ? (data.get("timeLimit") as Number) : 0;
        _parTime = data.get("parTime") != null ? (data.get("parTime") as Number) : 0;
        _strings = data.get("strings") != null ? (data.get("strings") as Number) : 1;
        
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
        
        System.println("[RETIC] Session started - Mode: " + watchModeStr + ", Rounds: " + _maxBullets + ", Par: " + _parTime);
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
        
        // Record split time
        var now = System.getTimer();
        if (_lastShotTime > 0 && _lastShotTime != _startTime) {
            var splitMs = now - _lastShotTime;
            _splitTimes.add(splitMs);
        }
        _lastShotTime = now;
        
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
    
    // Send results back to phone and end session
    function sendResultsToPhone() as Void {
        var app = Application.getApp() as reticccApp;
        
        // Calculate final elapsed time with precision
        var finalElapsedMs = System.getTimer() - _startTime;
        var elapsedSecs = finalElapsedMs.toFloat() / 1000.0;
        
        var results = {
            "sessionId" => _sessionId,
            "shotsFired" => _shotsFired,
            "elapsedTime" => elapsedSecs,           // Seconds with decimals
            "completed" => _sessionCompleted,        // True only if max rounds reached
            "distance" => _distance,
            "splitTimes" => _splitTimes,             // Array of ms between shots
            "avgSplit" => calculateAvgSplit()        // Average split in ms
        };
        
        System.println("[RETIC] Sending results - Shots: " + _shotsFired + ", Time: " + elapsedSecs + "s, Completed: " + _sessionCompleted);
        app.sendMessage("SESSION_RESULT", results);
        
        // Move to ended state
        _state = STATE_SESSION_ENDED;
        _lastMsg = _sessionCompleted ? "Complete!" : "Results sent";
        WatchUi.requestUpdate();
    }
    
    // Manually finish session (before hitting max bullets)
    function finishSession() as Void {
        if (_state == STATE_SESSION_ACTIVE) {
            _sessionCompleted = false;  // Manual end = not completed
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
        WatchUi.requestUpdate();
    }

    // Set connection status
    function setConnected(connected as Boolean) as Void {
        _connected = connected;
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
        if (data.get("humidity") != null) { _humidity = data.get("humidity") as Number; }
        if (data.get("pressure") != null) { _pressure = data.get("pressure") as Number; }
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
    // IDLE SCREEN - Minimal sniper info (wind, weather)
    // =========================================================================
    private function drawIdleScreen(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        var margin = width / 10;  // Proportional margin
        var colOffset = width / 4;  // Proportional column spacing
        
        // App name at top center
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, margin, Graphics.FONT_TINY, "reticIQ", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Connection indicator (top right, proportional)
        dc.setColor(_connected ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(width - margin - 5, margin + 5, 5);
        
        // Crosshair icon in center (proportional size) - use thicker pen
        var crossSize = width / 10;
        
        // Set pen width for thicker crosshair (API 3.2.0+)
        if (dc has :setPenWidth) {
            dc.setPenWidth(2);
        }
        
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(centerX - crossSize, centerY, centerX + crossSize, centerY);
        dc.drawLine(centerX, centerY - crossSize, centerX, centerY + crossSize);
        dc.drawCircle(centerX, centerY, crossSize * 0.6);
        dc.drawCircle(centerX, centerY, crossSize * 0.3);
        
        // Reset pen width
        if (dc has :setPenWidth) {
            dc.setPenWidth(1);
        }
        
        // Wind info (left of center, proportional)
        var infoY = centerY - height * 0.15;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX - colOffset, infoY, Graphics.FONT_XTINY, "WIND", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_windSpeed > 0) {
            dc.drawText(centerX - colOffset, infoY + 15, Graphics.FONT_TINY, _windSpeed.toString() + " m/s", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(centerX - colOffset, infoY + 30, Graphics.FONT_XTINY, _windDirection, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX - colOffset, infoY + 15, Graphics.FONT_TINY, "--", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Temp (right of center, proportional) - fixed 0°C bug
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX + colOffset, infoY, Graphics.FONT_XTINY, "TEMP", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_hasTemperature) {
            dc.drawText(centerX + colOffset, infoY + 15, Graphics.FONT_TINY, _temperature.toString() + "°", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX + colOffset, infoY + 15, Graphics.FONT_TINY, "--", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Status at bottom (proportional)
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height - margin - 5, Graphics.FONT_XTINY, "Waiting for session...", Graphics.TEXT_JUSTIFY_CENTER);
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
    // PRIMARY MODE - Clean 4-element layout
    // TOP: distance | CENTER: shot count | LEFT: timer | RIGHT: max/par
    // =========================================================================
    private function drawPrimarySession(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number, margin as Number, safeWidth as Number, safeTop as Number, safeBottom as Number) as Void {
        var fontHotH = dc.getFontHeight(Graphics.FONT_NUMBER_HOT);
        
        // =====================================================================
        // 1. TOP - Distance or drill name
        // =====================================================================
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var topText = _distance > 0 ? _distance.toString() + "m" : _drillName;
        if (topText.length() > 10) { topText = topText.substring(0, 8) + ".."; }
        dc.drawText(centerX, safeTop, Graphics.FONT_SMALL, topText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // 2. CENTER - Big shot count (main focus)
        // =====================================================================
        var shotColor = _shotFlashActive ? Graphics.COLOR_YELLOW : Graphics.COLOR_WHITE;
        dc.setColor(shotColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, centerY - (fontHotH / 2), Graphics.FONT_NUMBER_HOT, _shotsFired.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // 3. LEFT - Timer
        // =====================================================================
        var leftX = margin + 10;
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        var timeRemaining = getTimeRemaining();
        var timeText = (_timeLimit > 0 && timeRemaining > 0) ? "-" + formatTime(timeRemaining) : formatTime(_elapsedSeconds);
        dc.drawText(leftX, centerY - 8, Graphics.FONT_TINY, timeText, Graphics.TEXT_JUSTIFY_LEFT);
        
        // =====================================================================
        // 4. RIGHT - Max bullets or Par time
        // =====================================================================
        var rightX = width - margin - 10;
        if (_maxBullets > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rightX, centerY - 8, Graphics.FONT_TINY, "/" + _maxBullets.toString(), Graphics.TEXT_JUSTIFY_RIGHT);
        } else if (_parTime > 0) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(rightX, centerY - 8, Graphics.FONT_TINY, _parTime.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_RIGHT);
        }
        
        // =====================================================================
        // 5. BOTTOM - Status (only if complete)
        // =====================================================================
        if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, safeBottom - 20, Graphics.FONT_XTINY, "COMPLETE!", Graphics.TEXT_JUSTIFY_CENTER);
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
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
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
                    var arcColor = Graphics.COLOR_BLUE;
                    if (progress > 0.75) { arcColor = Graphics.COLOR_ORANGE; }
                    if (progress > 0.9) { arcColor = Graphics.COLOR_RED; }
                    if (_shotFlashActive) { arcColor = Graphics.COLOR_YELLOW; }
                    dc.setColor(arcColor, Graphics.COLOR_TRANSPARENT);
                    dc.drawArc(centerX, middleCenterY, arcRadius, Graphics.ARC_COUNTER_CLOCKWISE, 225, endAngle);
                }
            } else {
                var accentColor = _shotFlashActive ? Graphics.COLOR_YELLOW : Graphics.COLOR_BLUE;
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
        var timerColor = _shotFlashActive ? Graphics.COLOR_YELLOW : Graphics.COLOR_WHITE;
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
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
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
        dc.setColor(Graphics.COLOR_PURPLE, Graphics.COLOR_TRANSPARENT);
        if (!_shooterName.equals("")) {
            dc.drawText(centerX, safeTop, Graphics.FONT_SMALL, _shooterName, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, safeTop, Graphics.FONT_SMALL, "SESSION", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        var y = safeTop + lineHeight;
        
        // Drill name (truncate if too long)
        if (!_drillName.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "DRILL", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var displayName = _drillName.length() > 16 ? _drillName.substring(0, 14) + ".." : _drillName;
            dc.drawText(centerX, y + 12, Graphics.FONT_TINY, displayName, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
        
        // Goal (truncate if too long)
        if (!_drillGoal.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "GOAL", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            var displayGoal = _drillGoal.length() > 16 ? _drillGoal.substring(0, 14) + ".." : _drillGoal;
            dc.drawText(centerX, y + 12, Graphics.FONT_TINY, displayGoal, Graphics.TEXT_JUSTIFY_CENTER);
            y += lineHeight;
        }
        
        // Distance and time limit in a row
        var colOffset = width / 4;
        if (_distance > 0 || _timeLimit > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_distance > 0) {
                dc.drawText(centerX - colOffset, y, Graphics.FONT_XTINY, "DIST", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX - colOffset, y + 12, Graphics.FONT_TINY, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
            }
            if (_timeLimit > 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y, Graphics.FONT_XTINY, "LIMIT", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y + 12, Graphics.FONT_TINY, formatTime(_timeLimit), Graphics.TEXT_JUSTIFY_CENTER);
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
                dc.drawText(centerX - colOffset, y + 10, Graphics.FONT_XTINY, _totalSessions.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            }
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_totalShots > 0) {
                dc.drawText(centerX, y, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX, y + 10, Graphics.FONT_XTINY, _totalShots.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            }
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (_bestAccuracy > 0) {
                dc.drawText(centerX + colOffset, y, Graphics.FONT_XTINY, "BEST", Graphics.TEXT_JUSTIFY_CENTER);
                dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
                dc.drawText(centerX + colOffset, y + 10, Graphics.FONT_XTINY, _bestAccuracy.toString() + "%", Graphics.TEXT_JUSTIFY_CENTER);
            }
        }
        
        // Recording indicator
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(margin + 10, margin + 10, 5);
        
        // Timer in corner
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
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
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width - margin - 5, margin, Graphics.FONT_XTINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_RIGHT);
        
        // Recording indicator top left (proportional)
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(margin + 10, margin + 10, 5);
        
        // Header
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, margin, Graphics.FONT_SMALL, "ENVIRON", Graphics.TEXT_JUSTIFY_CENTER);
        
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
            dc.drawText(centerX, y + 15, Graphics.FONT_SMALL, windText, Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, y + 15, Graphics.FONT_SMALL, "-- m/s", Graphics.TEXT_JUSTIFY_CENTER);
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
            else if (_lightLevel < 70) { lightText = "MED"; lightColor = Graphics.COLOR_YELLOW; }
            else { lightText = "HIGH"; lightColor = Graphics.COLOR_GREEN; }  // Fixed: use green for good light
        }
        dc.setColor(lightColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y + 12, Graphics.FONT_TINY, lightText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // Temp - fixed 0°C bug using _hasTemperature flag
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y, Graphics.FONT_XTINY, "TEMP", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y + 12, Graphics.FONT_TINY, _hasTemperature ? _temperature.toString() + "°C" : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Bottom row: HUM and PRESS/ALT
        y += rowHeight;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y, Graphics.FONT_XTINY, "HUM", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(leftCol, y + 12, Graphics.FONT_TINY, _humidity > 0 ? _humidity.toString() + "%" : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y, Graphics.FONT_XTINY, "PRESS", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(rightCol, y + 12, Graphics.FONT_TINY, _pressure > 0 ? _pressure.toString() : "--", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Altitude row (if available)
        if (_altitude > 0) {
            y += rowHeight - 10;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y, Graphics.FONT_XTINY, "ALT", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, y + 12, Graphics.FONT_TINY, _altitude.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
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
        dc.setColor(currentPage == PAGE_PERSONAL ? Graphics.COLOR_PURPLE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(startX, dotY, currentPage == PAGE_PERSONAL ? dotRadius + 1 : dotRadius);
        
        // Center dot (Main)
        dc.setColor(currentPage == PAGE_MAIN ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(startX + dotSpacing, dotY, currentPage == PAGE_MAIN ? dotRadius + 1 : dotRadius);
        
        // Right dot (Environment)
        dc.setColor(currentPage == PAGE_ENVIRONMENT ? Graphics.COLOR_BLUE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
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
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, margin, Graphics.FONT_SMALL, "COMPLETE", Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // 2. MIDDLE ROW - Spread TIME, SHOTS, SPLIT horizontally
        // =====================================================================
        var hasAvgSplit = _splitTimes.size() > 0;
        
        if (hasAvgSplit) {
            // 3 items: TIME | SHOTS | SPLIT - spread across width
            var col1 = margin + (width - 2 * margin) / 6;
            var col2 = centerX;
            var col3 = width - margin - (width - 2 * margin) / 6;
            
            // TIME (left)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col1, centerY - 20, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col1, centerY, Graphics.FONT_TINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
            
            // SHOTS (center)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col2, centerY - 20, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            var shotsText = _maxBullets > 0 ? _shotsFired.toString() + "/" + _maxBullets.toString() : _shotsFired.toString();
            dc.drawText(col2, centerY, Graphics.FONT_TINY, shotsText, Graphics.TEXT_JUSTIFY_CENTER);
            
            // AVG SPLIT (right)
            var avgSplit = calculateAvgSplit();
            var avgSplitSecs = avgSplit.toFloat() / 1000.0;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col3, centerY - 20, Graphics.FONT_XTINY, "SPLIT", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(col3, centerY, Graphics.FONT_TINY, avgSplitSecs.format("%.1f") + "s", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            // 2 items: TIME | SHOTS - spread left and right
            var colLeft = centerX - width / 5;
            var colRight = centerX + width / 5;
            
            // TIME (left)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colLeft, centerY - 20, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colLeft, centerY, Graphics.FONT_MEDIUM, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
            
            // SHOTS (right)
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(colRight, centerY - 20, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            var shotsText = _maxBullets > 0 ? _shotsFired.toString() + "/" + _maxBullets.toString() : _shotsFired.toString();
            dc.drawText(colRight, centerY, Graphics.FONT_MEDIUM, shotsText, Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // =====================================================================
        // 3. BOTTOM - Tap to reset
        // =====================================================================
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height - margin - 10, Graphics.FONT_XTINY, "TAP to reset", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
