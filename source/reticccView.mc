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

class reticccView extends WatchUi.View {

    // Session state
    private var _state as SessionState = STATE_IDLE;
    
    // Session data from phone
    private var _sessionId as String = "";
    private var _drillName as String = "";
    private var _drillGoal as String = "";
    private var _distance as Number = 0;
    private var _maxBullets as Number = 0;  // Max shots allowed (from phone)
    private var _timeLimit as Number = 0;
    
    // Shot counter (user controlled)
    private var _shotsFired as Number = 0;
    
    // Timer for elapsed time
    private var _startTime as Number = 0;
    private var _timer as Timer.Timer?;
    private var _elapsedSeconds as Number = 0;
    
    // Connection status
    private var _connected as Boolean = false;
    
    // Weather/wind data (for idle screen)
    private var _windSpeed as Number = 0;      // m/s or mph
    private var _windDirection as String = ""; // N, NE, E, etc.
    private var _temperature as Number = 0;    // Celsius
    
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
    
    // Timer callback - update elapsed time
    function onTimerTick() as Void {
        if (_state == STATE_SESSION_ACTIVE && _startTime > 0) {
            _elapsedSeconds = (System.getTimer() - _startTime) / 1000;
            WatchUi.requestUpdate();
        }
    }

    // Called when session starts from phone
    function startSession(data as Dictionary) as Void {
        _state = STATE_SESSION_ACTIVE;
        _startTime = System.getTimer();
        _elapsedSeconds = 0;
        _shotsFired = 0;  // Reset shot counter
        
        // Extract session data
        _sessionId = data.get("sessionId") != null ? data.get("sessionId").toString() : "";
        _drillName = data.get("drillName") != null ? data.get("drillName").toString() : "Session";
        _drillGoal = data.get("drillGoal") != null ? data.get("drillGoal").toString() : "";
        _distance = data.get("distance") != null ? (data.get("distance") as Number) : 0;
        _maxBullets = data.get("rounds") != null ? (data.get("rounds") as Number) : 0;  // Using rounds as max bullets
        _timeLimit = data.get("timeLimit") != null ? (data.get("timeLimit") as Number) : 0;
        
        // Also check for explicit maxBullets/bullets field
        if (data.get("maxBullets") != null) {
            _maxBullets = data.get("maxBullets") as Number;
        } else if (data.get("bullets") != null) {
            _maxBullets = data.get("bullets") as Number;
        }
        
        _lastMsg = "Session started";
        WatchUi.requestUpdate();
    }
    
    // Called when session ends from phone
    function endSession(data as Dictionary) as Void {
        _state = STATE_SESSION_ENDED;
        _lastMsg = "Session ended";
        WatchUi.requestUpdate();
    }
    
    // Add a shot (called from delegate on tap)
    // Returns true if shot was added, false if at max
    function addShot() as Boolean {
        if (_state != STATE_SESSION_ACTIVE) {
            return false;
        }
        
        // Check if we've hit the max
        if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            return false;  // Can't add more
        }
        
        _shotsFired++;
        WatchUi.requestUpdate();
        
        // Auto-complete when reaching max bullets
        if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            // Send results to phone automatically
            sendResultsToPhone();
        }
        
        return true;
    }
    
    // Send results back to phone and end session
    function sendResultsToPhone() as Void {
        var app = Application.getApp() as reticccApp;
        
        var results = {
            "sessionId" => _sessionId,
            "shotsFired" => _shotsFired,
            "elapsedTime" => _elapsedSeconds,
            "distance" => _distance,
            "completed" => (_maxBullets > 0 && _shotsFired >= _maxBullets)
        };
        
        app.sendMessage("SESSION_RESULT", results);
        
        // Move to ended state
        _state = STATE_SESSION_ENDED;
        _lastMsg = "Results sent!";
        WatchUi.requestUpdate();
    }
    
    // Manually finish session (before hitting max bullets)
    function finishSession() as Void {
        if (_state == STATE_SESSION_ACTIVE) {
            sendResultsToPhone();
        }
    }
    
    // Reset to idle state
    function resetToIdle() as Void {
        _state = STATE_IDLE;
        _elapsedSeconds = 0;
        _startTime = 0;
        _shotsFired = 0;
        _lastMsg = "";
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
        WatchUi.requestUpdate();
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

        var width = dc.getWidth();
        var height = dc.getHeight();
        var centerX = width / 2;
        var centerY = height / 2;

        if (_state == STATE_SESSION_ACTIVE) {
            drawActiveSession(dc, width, height, centerX, centerY);
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
        // App name at top
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, 8, Graphics.FONT_TINY, "RETIC", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Connection indicator
        dc.setColor(_connected ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(width - 12, 12, 5);
        
        // Crosshair icon in center
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        var crossSize = 25;
        dc.drawLine(centerX - crossSize, centerY, centerX + crossSize, centerY);
        dc.drawLine(centerX, centerY - crossSize, centerX, centerY + crossSize);
        dc.drawCircle(centerX, centerY, 15);
        dc.drawCircle(centerX, centerY, 8);
        
        // Wind info (left side)
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(15, centerY - 35, Graphics.FONT_XTINY, "WIND", Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_windSpeed > 0) {
            dc.drawText(15, centerY - 20, Graphics.FONT_TINY, _windSpeed.toString() + " m/s", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(15, centerY - 5, Graphics.FONT_XTINY, _windDirection, Graphics.TEXT_JUSTIFY_LEFT);
        } else {
            dc.drawText(15, centerY - 20, Graphics.FONT_TINY, "--", Graphics.TEXT_JUSTIFY_LEFT);
        }
        
        // Temp (right side)
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width - 15, centerY - 35, Graphics.FONT_XTINY, "TEMP", Graphics.TEXT_JUSTIFY_RIGHT);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_temperature != 0) {
            dc.drawText(width - 15, centerY - 20, Graphics.FONT_TINY, _temperature.toString() + "°", Graphics.TEXT_JUSTIFY_RIGHT);
        } else {
            dc.drawText(width - 15, centerY - 20, Graphics.FONT_TINY, "--", Graphics.TEXT_JUSTIFY_RIGHT);
        }
        
        // Status at bottom
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height - 25, Graphics.FONT_XTINY, "Waiting for session...", Graphics.TEXT_JUSTIFY_CENTER);
    }
    
    // =========================================================================
    // ACTIVE SESSION - Shot counter, distance, timer
    // =========================================================================
    private function drawActiveSession(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Header bar with distance
        dc.setColor(Graphics.COLOR_DK_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, width, 26);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_distance > 0) {
            dc.drawText(centerX, 5, Graphics.FONT_SMALL, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(centerX, 5, Graphics.FONT_SMALL, "ACTIVE", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Timer at top-right area
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, 32, Graphics.FONT_TINY, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
        
        // =====================================================================
        // BIG SHOT COUNTER - Main focus
        // =====================================================================
        var shotY = centerY - 5;
        
        // Shot count (BIG)
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, shotY - 25, Graphics.FONT_NUMBER_HOT, _shotsFired.toString(), Graphics.TEXT_JUSTIFY_CENTER);
        
        // Max bullets indicator
        if (_maxBullets > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, shotY + 30, Graphics.FONT_SMALL, "/ " + _maxBullets.toString(), Graphics.TEXT_JUSTIFY_CENTER);
            
            // Progress bar
            var barWidth = width - 40;
            var barHeight = 6;
            var barY = shotY + 55;
            var barX = 20;
            
            // Background
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(barX, barY, barWidth, barHeight);
            
            // Fill
            var fillWidth = (barWidth * _shotsFired) / _maxBullets;
            if (fillWidth > barWidth) { fillWidth = barWidth; }
            var fillColor = (_shotsFired >= _maxBullets) ? Graphics.COLOR_RED : Graphics.COLOR_GREEN;
            dc.setColor(fillColor, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(barX, barY, fillWidth, barHeight);
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, shotY + 30, Graphics.FONT_XTINY, "SHOTS", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Hint at bottom
        if (_maxBullets > 0 && _shotsFired >= _maxBullets) {
            // Max reached - show complete message
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - 20, Graphics.FONT_XTINY, "MAX REACHED - Results sent!", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - 20, Graphics.FONT_XTINY, "TAP to count shot", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Recording indicator (pulsing)
        var pulse = (_elapsedSeconds % 2 == 0);
        dc.setColor(pulse ? Graphics.COLOR_RED : Graphics.COLOR_DK_RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(12, 12, 5);
    }
    
    // =========================================================================
    // SESSION ENDED - Show results summary
    // =========================================================================
    private function drawSessionEnded(dc as Dc, width as Number, height as Number, centerX as Number, centerY as Number) as Void {
        // Header
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, width, 26);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, 5, Graphics.FONT_SMALL, "COMPLETE", Graphics.TEXT_JUSTIFY_CENTER);
        
        // Stats
        var statsY = 40;
        var lineHeight = 32;
        
        // Time
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, statsY, Graphics.FONT_XTINY, "TIME", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, statsY + 12, Graphics.FONT_MEDIUM, formatTime(_elapsedSeconds), Graphics.TEXT_JUSTIFY_CENTER);
        
        // Shots
        statsY += lineHeight + 10;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, statsY, Graphics.FONT_XTINY, "SHOTS FIRED", Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        var shotsText = _shotsFired.toString();
        if (_maxBullets > 0) {
            shotsText = _shotsFired.toString() + " / " + _maxBullets.toString();
        }
        dc.drawText(centerX, statsY + 12, Graphics.FONT_MEDIUM, shotsText, Graphics.TEXT_JUSTIFY_CENTER);
        
        // Distance (if set)
        if (_distance > 0) {
            statsY += lineHeight;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, statsY, Graphics.FONT_XTINY, "DISTANCE", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, statsY + 12, Graphics.FONT_SMALL, _distance.toString() + "m", Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Result sent confirmation
        if (!_lastMsg.equals("")) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(centerX, height - 35, Graphics.FONT_XTINY, _lastMsg, Graphics.TEXT_JUSTIFY_CENTER);
        }
        
        // Tap to continue
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(centerX, height - 18, Graphics.FONT_XTINY, "TAP to reset", Graphics.TEXT_JUSTIFY_CENTER);
    }
}
