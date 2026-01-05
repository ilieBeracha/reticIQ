import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Communications;
import Toybox.Time;
import Toybox.System;
import Toybox.Timer;
import Toybox.Application.Storage;

// Global variable to store the view reference for UI updates
var mainView as reticccView?;

// Message type constants - MUST match your React Native AppConstants
// Protocol v2: 2-phase sync (SESSION_SUMMARY -> TIMELINE_CHUNK)
module MessageTypes {
    const PING = "PING";
    const PONG = "PONG";
    const DATA = "DATA";
    const ACK = "ACK";
    const ERROR = "ERROR";
    const SESSION_START = "SESSION_START";
    const SESSION_END = "SESSION_END";
    const SESSION_RESULT = "SESSION_RESULT";      // Legacy - keep for compatibility
    const SESSION_SUMMARY = "SESSION_SUMMARY";    // Phase 1: Summary + all metadata (~1KB)
    const TIMELINE_CHUNK = "TIMELINE_CHUNK";      // Phase 2: Biometric time-series chunks
    const WEATHER = "WEATHER";
}

// Sync phase enum (Protocol v2: 2-phase sync)
enum SyncPhase {
    SYNC_IDLE,           // No sync in progress
    SYNC_SUMMARY,        // Waiting for summary ACK
    SYNC_TIMELINE        // Waiting for timeline chunk ACK
}

// Storage keys for persistent data
module StorageKeys {
    const PENDING_SESSIONS = "pending_sessions";
    const PENDING_TIMELINE = "pending_timeline";  // Timeline chunks awaiting send
    const LAST_SEND_ATTEMPT = "last_send_attempt";
}

class reticccApp extends Application.AppBase {

    // Multi-phase sync state (Protocol v2: summary -> timeline)
    private var _syncPhase as SyncPhase = SYNC_IDLE;
    private var _pendingAckSessionId as String? = null;
    private var _ackTimer as Timer.Timer? = null;
    private var _ackTimeoutMs as Number = 5000;  // 5 second timeout for ACK
    private var _pendingSessionData as Dictionary? = null;
    private var _retryCount as Number = 0;
    private var _maxRetries as Number = 3;

    // Timeline chunk sync state (phase 3)
    private var _timelineChunks as Array<Dictionary>?;
    private var _currentChunkIndex as Number = 0;
    private var _totalChunks as Number = 0;

    // Session management modules (two-phase sync architecture)
    private var _sessionManager as SessionManager?;
    private var _payloadBuilder as PayloadBuilder?;

    function initialize() {
        AppBase.initialize();
        _sessionManager = new SessionManager();
        _payloadBuilder = new PayloadBuilder();
    }

    // Get session manager for View integration
    function getSessionManager() as SessionManager {
        if (_sessionManager == null) {
            _sessionManager = new SessionManager();
        }
        return _sessionManager as SessionManager;
    }

    // Get payload builder
    function getPayloadBuilder() as PayloadBuilder {
        if (_payloadBuilder == null) {
            _payloadBuilder = new PayloadBuilder();
        }
        return _payloadBuilder as PayloadBuilder;
    }

    // Called by View when session completes (Protocol v2: 2-phase sync)
    function onSessionComplete(
        completed as Boolean,
        shotDetector as ShotDetector?
    ) as Void {
        var sessionMgr = getSessionManager();
        var payloadBldr = getPayloadBuilder();

        // End the session in SessionManager
        sessionMgr.endSession(completed);

        // Get biometrics and steadiness trackers from ShotDetector
        var bioTracker = null as BiometricsTracker?;
        var steadyAnalyzer = null as SteadinessAnalyzer?;
        if (shotDetector != null) {
            bioTracker = shotDetector.getBiometricsTracker();
            steadyAnalyzer = shotDetector.getSteadinessAnalyzer();
            shotDetector.stopMonitoring();
        }

        // Build summary payload (Protocol v2: no separate details phase)
        var payloads = payloadBldr.build(sessionMgr, bioTracker, steadyAnalyzer);
        var summary = payloads.get("summary") as Dictionary;

        // Collect timeline chunks from biometrics tracker
        _timelineChunks = null;
        _currentChunkIndex = 0;
        _totalChunks = 0;

        if (bioTracker != null) {
            var chunker = bioTracker.getTimelineChunker();
            if (chunker != null && chunker.hasData()) {
                _timelineChunks = chunker.getAllChunks();
                _totalChunks = _timelineChunks.size();
                System.println("[APP] Timeline: " + chunker.getPointCount() + " points, " + _totalChunks + " chunks");
            }
        }

        var sessionId = sessionMgr.getSessionId();
        System.println("[APP] onSessionComplete - sessionId: " + sessionId + ", completed: " + completed);
        System.println("[APP] Summary keys: sid=" + summary.get("sid") + ", shots=" + summary.get("shots"));

        // Initiate Protocol v2 sync (summary -> timeline chunks)
        sendSessionSummary(sessionId, summary);

        if (mainView != null) {
            mainView.setLastMsg("Syncing...");
        }
    }

    function onStart(state as Dictionary?) as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        System.println("[RETIC] Registered for phone messages");
        
        // Check for pending sessions on app start (retries failed syncs)
        checkPendingSessions();
    }

    // Callback when a phone message is received
    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        System.println("[RETIC] === MESSAGE RECEIVED ===");
        
        var data = msg.data;
        if (data == null) {
            System.println("[RETIC] ERROR: null data");
            return;
        }
        
        if (data instanceof Dictionary) {
            var dict = data as Dictionary;
            var msgType = dict.get("type");
            var payload = dict.get("payload");
            
            System.println("[RETIC] Type: " + (msgType != null ? msgType.toString() : "null"));
            handleMessage(msgType, payload);
        } else {
            System.println("[RETIC] Non-dict message: " + data.toString());
            sendMessage(MessageTypes.ACK, {"received" => "ok"});
        }
        
        WatchUi.requestUpdate();
    }

    // Handle different message types from the phone
    function handleMessage(msgType as Object?, payload as Object?) as Void {
        if (msgType == null) {
            return;
        }
        
        var typeStr = msgType.toString();
        System.println("[RETIC] Handling: " + typeStr);
        
        if (typeStr.equals(MessageTypes.PING)) {
            sendMessage(MessageTypes.PONG, {"timestamp" => Time.now().value()});
            
        } else if (typeStr.equals(MessageTypes.ACK)) {
            // Handle ACK from phone for SESSION_RESULT
            handleAck(payload);
            
        } else if (typeStr.equals(MessageTypes.SESSION_START)) {
            if (mainView != null && payload != null && payload instanceof Dictionary) {
                mainView.prepareSession(payload as Dictionary);
                sendMessage(MessageTypes.ACK, {"status" => "session_ready"});
            }
            
        } else if (typeStr.equals(MessageTypes.SESSION_END)) {
            if (mainView != null && payload != null && payload instanceof Dictionary) {
                mainView.endSession(payload as Dictionary);
                sendMessage(MessageTypes.ACK, {"status" => "session_ended"});
            }
            
        } else if (typeStr.equals(MessageTypes.WEATHER)) {
            // Update weather data on idle screen
            if (mainView != null && payload != null && payload instanceof Dictionary) {
                var p = payload as Dictionary;
                var wind = p.get("windSpeed") != null ? (p.get("windSpeed") as Number) : 0;
                var windDir = p.get("windDirection") != null ? p.get("windDirection").toString() : "";
                var temp = p.get("temperature") != null ? (p.get("temperature") as Number) : 0;
                mainView.setWeather(wind, windDir, temp);
                sendMessage(MessageTypes.ACK, {"status" => "weather_updated"});
            }
            
        } else if (typeStr.equals(MessageTypes.DATA)) {
            sendMessage(MessageTypes.ACK, {"status" => "received"});
        }
    }

    // Send a structured message back to the phone
    function sendMessage(msgType as String, payload as Dictionary) as Void {
        var message = {
            "type" => msgType,
            "payload" => payload
        };
        
        System.println("[RETIC] Sending: " + msgType);
        var listener = new CommListener();
        Communications.transmit(message, null, listener);
    }
    
    // =========================================================================
    // PROTOCOL V2: TWO-PHASE SESSION SYNC - Reliable Delivery
    // Phase 1: SESSION_SUMMARY (instant, ~1KB)
    // Phase 2: TIMELINE_CHUNK (biometric time-series, after summary ACK)
    // =========================================================================
    
    // Start Protocol v2 sync: send summary first, then timeline after ACK
    function sendSessionSummary(sessionId as String, summary as Dictionary) as Void {
        System.println("[SYNC] Starting Protocol v2 sync for: " + sessionId);
        
        // Store pending data
        _pendingAckSessionId = sessionId;
        _pendingSessionData = summary;
        _syncPhase = SYNC_SUMMARY;
        _retryCount = 0;
        
        // Save summary to storage (in case app crashes before ACK)
        saveSessionToStorage(sessionId, summary);
        
        // Phase 1: Send summary immediately
        System.println("[SYNC] Phase 1: Sending SESSION_SUMMARY");
        sendMessage(MessageTypes.SESSION_SUMMARY, summary);
        
        // Start ACK timeout timer
        startAckTimer();
        
        if (mainView != null) {
            mainView.setLastMsg("Syncing...");
        }
    }
    
    // Legacy wrapper for backward compatibility
    function sendSessionWithTwoPhase(sessionId as String, summary as Dictionary, details as Dictionary) as Void {
        // Protocol v2: details are ignored, go straight to timeline after summary
        sendSessionSummary(sessionId, summary);
    }
    
    // Handle ACK received from phone (Protocol v2: summary -> timeline chunks)
    private function handleAck(payload as Object?) as Void {
        if (payload == null || !(payload instanceof Dictionary)) {
            System.println("[ACK] Invalid ACK payload");
            return;
        }

        var ackPayload = payload as Dictionary;
        var ackSessionId = ackPayload.get("sessionId");
        var ackType = ackPayload.get("type");  // "summary" or "timeline"
        var ackStatus = ackPayload.get("status");

        var typeStr = (ackType != null) ? ackType.toString() : "unknown";
        System.println("[ACK] Received ACK type=" + typeStr + " for session: " + (ackSessionId != null ? ackSessionId.toString() : "null"));

        // Check for error status
        if (ackStatus != null && ackStatus.toString().equals("error")) {
            var errorMsg = ackPayload.get("error");
            System.println("[ACK] Error from phone: " + (errorMsg != null ? errorMsg.toString() : "unknown"));
            // Keep data for retry, show error
            if (mainView != null) {
                mainView.setLastMsg("Sync error");
            }
            return;
        }

        // Check if this ACK matches our pending session
        if (ackSessionId == null || _pendingAckSessionId == null) {
            System.println("[ACK] No pending session or missing sessionId");
            return;
        }

        if (!ackSessionId.toString().equals(_pendingAckSessionId)) {
            System.println("[ACK] sessionId mismatch. Expected: " + _pendingAckSessionId + ", Got: " + ackSessionId.toString());
            return;
        }

        // Cancel timeout timer
        stopAckTimer();

        if (_syncPhase == SYNC_SUMMARY) {
            // Summary ACK received - show success, then start timeline
            System.println("[SYNC] ✓ Summary ACK received! Phone shows 'Session Recorded'");

            if (mainView != null) {
                mainView.setLastMsg("Synced ✓");
            }

            // Remove summary from storage (successful delivery)
            removeSessionFromStorage(_pendingAckSessionId);

            // Phase 2: Start timeline chunk sync if there's data
            startTimelineSync();

        } else if (_syncPhase == SYNC_TIMELINE) {
            // Timeline chunk ACK received - send next chunk or complete
            var ackChunk = ackPayload.get("chunk");
            System.println("[SYNC] Timeline chunk " + (_currentChunkIndex + 1) + "/" + _totalChunks + " ACK received");

            _currentChunkIndex++;

            if (_currentChunkIndex < _totalChunks) {
                // Send next chunk
                sendNextTimelineChunk();
            } else {
                // All chunks sent successfully!
                System.println("[SYNC] ✓✓ All " + _totalChunks + " timeline chunks sent! Sync complete!");

                // Remove timeline from storage
                removeTimelineFromStorage(_pendingAckSessionId);

                // Clear state
                clearSyncState();

                if (mainView != null) {
                    mainView.setLastMsg("Synced ✓");
                }
            }
        }
    }

    // Start timeline chunk sync (Phase 2 of Protocol v2)
    private function startTimelineSync() as Void {
        if (_timelineChunks == null || _totalChunks == 0) {
            // No timeline data, sync complete
            System.println("[SYNC] No timeline data, sync complete");
            clearSyncState();
            return;
        }

        System.println("[SYNC] Phase 2: Starting timeline sync (" + _totalChunks + " chunks)");
        _syncPhase = SYNC_TIMELINE;
        _currentChunkIndex = 0;
        _retryCount = 0;

        // Save timeline chunks to storage for recovery
        if (_pendingAckSessionId != null) {
            saveTimelineToStorage(_pendingAckSessionId, _timelineChunks);
        }

        // Send first chunk
        sendNextTimelineChunk();
    }

    // Send the next timeline chunk
    private function sendNextTimelineChunk() as Void {
        if (_timelineChunks == null || _currentChunkIndex >= _totalChunks) {
            return;
        }

        var chunk = _timelineChunks[_currentChunkIndex];
        System.println("[SYNC] Sending timeline chunk " + (_currentChunkIndex + 1) + "/" + _totalChunks);

        _retryCount = 0;
        sendMessage(MessageTypes.TIMELINE_CHUNK, chunk);
        startAckTimer();
    }
    
    // Clear all sync state
    private function clearSyncState() as Void {
        _pendingAckSessionId = null;
        _pendingSessionData = null;
        _timelineChunks = null;
        _currentChunkIndex = 0;
        _totalChunks = 0;
        _syncPhase = SYNC_IDLE;
        _retryCount = 0;
    }

    // Start ACK timeout timer
    private function startAckTimer() as Void {
        stopAckTimer();  // Cancel any existing timer
        
        _ackTimer = new Timer.Timer();
        _ackTimer.start(method(:onAckTimeout), _ackTimeoutMs, false);
        System.println("[ACK] Started " + (_ackTimeoutMs / 1000) + "s timeout timer");
    }
    
    // Stop ACK timeout timer
    private function stopAckTimer() as Void {
        if (_ackTimer != null) {
            _ackTimer.stop();
            _ackTimer = null;
        }
    }
    
    // ACK timeout callback - no ACK received in time (Protocol v2)
    function onAckTimeout() as Void {
        System.println("[ACK] ⚠ Timeout! No ACK received (phase=" + _syncPhase + ")");

        _retryCount++;

        if (_retryCount < _maxRetries) {
            // Retry sending current phase
            System.println("[ACK] Retry attempt " + _retryCount + "/" + _maxRetries);

            if (_syncPhase == SYNC_SUMMARY && _pendingSessionData != null) {
                sendMessage(MessageTypes.SESSION_SUMMARY, _pendingSessionData);
                if (mainView != null) {
                    mainView.setLastMsg("Retry " + _retryCount + "...");
                }
            } else if (_syncPhase == SYNC_TIMELINE && _timelineChunks != null) {
                // Retry current timeline chunk
                if (_currentChunkIndex < _totalChunks) {
                    var chunk = _timelineChunks[_currentChunkIndex];
                    sendMessage(MessageTypes.TIMELINE_CHUNK, chunk);
                }
                // Don't update UI for timeline retry
            }

            startAckTimer();
        } else {
            // Max retries reached
            System.println("[ACK] Max retries reached for phase " + _syncPhase);

            if (_syncPhase == SYNC_SUMMARY) {
                // Summary failed - keep in storage for later
                System.println("[ACK] Summary sync failed. Saved for later.");
                if (mainView != null) {
                    mainView.setLastMsg("Saved offline");
                }
            } else if (_syncPhase == SYNC_TIMELINE) {
                // Timeline failed but summary succeeded - OK for now
                System.println("[ACK] Timeline sync failed at chunk " + (_currentChunkIndex + 1) + "/" + _totalChunks + ". Will retry later.");
                // Timeline already in storage
            }

            clearSyncState();
        }
    }
    
    // =========================================================================
    // LEGACY: Send SESSION_RESULT (single message - for backwards compatibility)
    // =========================================================================
    
    // Send SESSION_RESULT with ACK waiting and retry logic (legacy)
    function sendSessionResultWithAck(sessionId as String, payload as Dictionary) as Void {
        System.println("[ACK] Sending SESSION_RESULT for: " + sessionId);
        
        // Store pending data for potential retry
        _pendingAckSessionId = sessionId;
        _pendingSessionData = payload;
        _syncPhase = SYNC_SUMMARY;  // Reuse for legacy
        _retryCount = 0;
        
        // Save to storage immediately (in case app crashes/closes)
        saveSessionToStorage(sessionId, payload);
        
        // Send the message
        sendMessage(MessageTypes.SESSION_RESULT, payload);
        
        // Start ACK timeout timer
        startAckTimer();
    }
    
    // =========================================================================
    // LOCAL STORAGE - Pending Sessions Queue
    // =========================================================================
    // LOCAL STORAGE - Pending Sessions & Details
    // =========================================================================
    
    // Save session summary to local storage
    private function saveSessionToStorage(sessionId as String, payload as Dictionary) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_SESSIONS);
            var pendingDict = {} as Dictionary<String, Dictionary>;
            
            if (pending != null && pending instanceof Dictionary) {
                pendingDict = pending as Dictionary<String, Dictionary>;
            }
            
            pendingDict.put(sessionId, payload);
            Storage.setValue(StorageKeys.PENDING_SESSIONS, pendingDict);
            System.println("[STORAGE] Saved session summary: " + sessionId);
        } catch (ex) {
            System.println("[STORAGE] Error saving session: " + ex.getErrorMessage());
        }
    }
    
    // Remove session from storage (after successful ACK)
    private function removeSessionFromStorage(sessionId as String) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_SESSIONS);
            
            if (pending != null && pending instanceof Dictionary) {
                var pendingDict = pending as Dictionary<String, Dictionary>;
                pendingDict.remove(sessionId);
                Storage.setValue(StorageKeys.PENDING_SESSIONS, pendingDict);
                System.println("[STORAGE] Removed session: " + sessionId);
            }
        } catch (ex) {
            System.println("[STORAGE] Error removing session: " + ex.getErrorMessage());
        }
    }

    // Save timeline chunks to local storage (for phase 2 recovery)
    private function saveTimelineToStorage(sessionId as String, chunks as Array<Dictionary>) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_TIMELINE);
            var pendingDict = {} as Dictionary<String, Object>;

            if (pending != null && pending instanceof Dictionary) {
                pendingDict = pending as Dictionary<String, Object>;
            }

            // Store chunks array and current index for resume
            pendingDict.put(sessionId, {
                "chunks" => chunks,
                "index" => 0
            });
            Storage.setValue(StorageKeys.PENDING_TIMELINE, pendingDict);
            System.println("[STORAGE] Saved " + chunks.size() + " timeline chunks: " + sessionId);
        } catch (ex) {
            System.println("[STORAGE] Error saving timeline: " + ex.getErrorMessage());
        }
    }

    // Remove timeline from storage (after all chunks sent)
    private function removeTimelineFromStorage(sessionId as String) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_TIMELINE);

            if (pending != null && pending instanceof Dictionary) {
                var pendingDict = pending as Dictionary<String, Object>;
                pendingDict.remove(sessionId);
                Storage.setValue(StorageKeys.PENDING_TIMELINE, pendingDict);
                System.println("[STORAGE] Removed timeline: " + sessionId);
            }
        } catch (ex) {
            System.println("[STORAGE] Error removing timeline: " + ex.getErrorMessage());
        }
    }


    // Check and retry pending sessions on app start/connection (Protocol v2)
    function checkPendingSessions() as Void {
        try {
            // Check for pending timeline chunks first (phase 2 retries)
            var pendingTimeline = Storage.getValue(StorageKeys.PENDING_TIMELINE);
            if (pendingTimeline != null && pendingTimeline instanceof Dictionary) {
                var timelineDict = pendingTimeline as Dictionary<String, Object>;
                var timelineKeys = timelineDict.keys();
                
                if (timelineKeys.size() > 0) {
                    System.println("[STORAGE] Found " + timelineKeys.size() + " pending timeline sync(s)");
                    var firstKey = timelineKeys[0] as String;
                    var timelineData = timelineDict.get(firstKey);
                    
                    if (timelineData != null && timelineData instanceof Dictionary) {
                        var data = timelineData as Dictionary;
                        var chunks = data.get("chunks");
                        var idx = data.get("index");
                        
                        if (chunks != null && chunks instanceof Array) {
                            System.println("[STORAGE] Retrying timeline: " + firstKey);
                            _pendingAckSessionId = firstKey;
                            _timelineChunks = chunks as Array<Dictionary>;
                            _totalChunks = _timelineChunks.size();
                            _currentChunkIndex = (idx != null) ? (idx as Number) : 0;
                            _syncPhase = SYNC_TIMELINE;
                            _retryCount = 0;
                            
                            sendNextTimelineChunk();
                            return;  // Handle one at a time
                        }
                    }
                }
            }
            
            // Then check for pending summaries (phase 1 retries)
            var pending = Storage.getValue(StorageKeys.PENDING_SESSIONS);
            if (pending == null || !(pending instanceof Dictionary)) {
                System.println("[STORAGE] No pending sessions");
                return;
            }
            
            var pendingDict = pending as Dictionary<String, Dictionary>;
            var keys = pendingDict.keys();
            
            System.println("[STORAGE] Found " + keys.size() + " pending session(s)");
            
            if (keys.size() > 0) {
                var firstKey = keys[0] as String;
                var sessionData = pendingDict.get(firstKey);
                
                if (sessionData != null && sessionData instanceof Dictionary) {
                    System.println("[STORAGE] Retrying session: " + firstKey);
                    
                    _pendingAckSessionId = firstKey;
                    _pendingSessionData = sessionData as Dictionary;
                    _syncPhase = SYNC_SUMMARY;
                    _retryCount = 0;
                    
                    sendMessage(MessageTypes.SESSION_SUMMARY, _pendingSessionData);
                    startAckTimer();
                    
                    if (mainView != null) {
                        mainView.setLastMsg("Syncing...");
                    }
                }
            }
        } catch (ex) {
            System.println("[STORAGE] Error checking pending: " + ex.getErrorMessage());
        }
    }
    
    // Get count of pending sessions (for UI display)
    function getPendingSessionCount() as Number {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_SESSIONS);
            if (pending != null && pending instanceof Dictionary) {
                return (pending as Dictionary).size();
            }
        } catch (ex) {
            // Ignore
        }
        return 0;
    }
    
    // Clear all pending sessions (manual reset)
    function clearPendingSessions() as Void {
        Storage.deleteValue(StorageKeys.PENDING_SESSIONS);
        System.println("[STORAGE] Cleared all pending sessions");
    }
    
    // =========================================================================
    // MOCK DATA FOR SIMULATOR TESTING
    // =========================================================================
    
    // Start a mock PRIMARY mode session (timed drill - shot counter)
    function startMockSession() as Void {
        if (mainView != null) {
            var mockData = {
                "sessionId" => "MOCK-001",
                "drillName" => "Bill Drill",
                "drillGoal" => "6 shots under par",
                "drillType" => "timed",
                "inputMethod" => "manual",
                "watchMode" => "primary",        // Shot counter mode
                "distance" => 7,
                "rounds" => 6,
                "timeLimit" => 0,
                "parTime" => 2.0,
                "strings" => 1
            };
            mainView.startSession(mockData);
            System.println("[MOCK] PRIMARY mode session started");
        }
    }
    
    // Start a mock SUPPLEMENTARY mode session (zeroing drill - timer only)
    function startMockSupplementarySession() as Void {
        if (mainView != null) {
            var mockData = {
                "sessionId" => "MOCK-002",
                "drillName" => "5-Shot Group",
                "drillGoal" => "Tight grouping",
                "drillType" => "grouping",
                "inputMethod" => "scan",
                "watchMode" => "supplementary",  // Timer only mode
                "distance" => 100,
                "rounds" => 0,                    // No limit
                "timeLimit" => 0,
                "parTime" => 0,
                "strings" => 1
            };
            mainView.startSession(mockData);
            System.println("[MOCK] SUPPLEMENTARY mode session started");
        }
    }
    
    // Set mock environment data
    function setMockEnvironment() as Void {
        if (mainView != null) {
            var mockEnv = {
                "windSpeed" => 5,
                "windDirection" => "NW",
                "windAngle" => 315,
                "temperature" => 22,
                "humidity" => 65,
                "pressure" => 1013,
                "lightLevel" => 75,
                "altitude" => 450
            };
            mainView.setEnvironment(mockEnv);
            System.println("[MOCK] Environment data set");
        }
    }
    
    // Set mock personal data
    function setMockPersonal() as Void {
        if (mainView != null) {
            var mockPersonal = {
                "name" => "Shooter",
                "totalSessions" => 42,
                "totalShots" => 1250,
                "bestAccuracy" => 94
            };
            mainView.setPersonalData(mockPersonal);
            System.println("[MOCK] Personal data set");
        }
    }
    
    // Load all mock data at once
    function loadAllMockData() as Void {
        setMockEnvironment();
        setMockPersonal();
        startMockSession();
    }
    
    // Start a mock session with auto-detection enabled
    function startMockAutoDetectSession() as Void {
        if (mainView != null) {
            var mockData = {
                "sessionId" => "MOCK-AUTO-001",
                "drillName" => "Auto Detect",
                "drillGoal" => "Test shot detection",
                "drillType" => "timed",
                "inputMethod" => "auto",
                "watchMode" => "primary",
                "distance" => 25,
                "rounds" => 10,
                "timeLimit" => 0,
                "parTime" => 0,
                "strings" => 1,
                "autoDetect" => true,           // Enable auto-detection
                "sensitivity" => 3.5            // Medium sensitivity (3.5G)
            };
            mainView.startSession(mockData);
            System.println("[MOCK] Auto-detect session started");
        }
    }

    // =========================================================================
    // DEMO MODE - Fully automated session for testing without a gun
    // Auto-fires simulated shots with realistic timing
    // =========================================================================

    // Start a fully automated demo session
    // Fires 6 simulated shots with realistic split times (0.3-0.8s)
    function startDemoSession() as Void {
        System.println("[DEMO] startDemoSession called");

        if (mainView == null) {
            System.println("[DEMO] ERROR: mainView is null!");
            return;
        }

        // Load environment and personal data first
        setMockEnvironment();
        setMockPersonal();

        // Use manual input mode to avoid needing real sensor data
        var mockData = {
            "sessionId" => "DEMO-" + Time.now().value().toString(),
            "drillName" => "Demo Drill",
            "drillGoal" => "6 shots auto-fire",
            "drillType" => "timed",
            "inputMethod" => "manual",
            "watchMode" => "primary",
            "distance" => 7,
            "rounds" => 6,
            "timeLimit" => 0,
            "parTime" => 2,
            "strings" => 1,
            "autoDetect" => false,
            "sensitivity" => 3.5
        };

        System.println("[DEMO] Starting session...");
        mainView.startSession(mockData);
        System.println("[DEMO] Session started, state: " + mainView.getState());

        // Enable demo mode in the view - uses existing timer tick (more reliable)
        mainView.startDemoMode(6, 1500);  // 6 shots, first after 1.5s
        System.println("[DEMO] Demo mode activated");
    }

    function onStop(state as Dictionary?) as Void {
        // Clean up demo mode on app stop
        if (mainView != null) {
            mainView.stopDemoMode();
        }
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        mainView = new reticccView();
        return [mainView, new reticccDelegate()];
    }
}

// Communication listener for transmit callbacks
class CommListener extends Communications.ConnectionListener {
    private var _msgType as String = "";

    function initialize() {
        ConnectionListener.initialize();
    }

    function initWithType(msgType as String) {
        ConnectionListener.initialize();
        _msgType = msgType;
    }

    function onComplete() as Void {
        System.println("[COMM] ✓ " + _msgType + " sent successfully");
    }

    function onError() as Void {
        System.println("[COMM] ✗ " + _msgType + " send FAILED - check phone connection");
        // Notify view of send failure
        if (mainView != null) {
            mainView.setLastMsg("Send failed!");
        }
    }
}
