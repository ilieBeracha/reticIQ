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
module MessageTypes {
    const PING = "PING";
    const PONG = "PONG";
    const DATA = "DATA";
    const ACK = "ACK";
    const ERROR = "ERROR";
    const SESSION_START = "SESSION_START";
    const SESSION_END = "SESSION_END";
    const SESSION_RESULT = "SESSION_RESULT";      // Legacy - keep for compatibility
    const SESSION_SUMMARY = "SESSION_SUMMARY";    // Phase 1: Quick summary (~300 bytes)
    const SESSION_DETAILS = "SESSION_DETAILS";    // Phase 2: Full data (background)
    const WEATHER = "WEATHER";
}

// Sync phase enum
enum SyncPhase {
    SYNC_IDLE,           // No sync in progress
    SYNC_SUMMARY,        // Waiting for summary ACK
    SYNC_DETAILS         // Waiting for details ACK
}

// Storage keys for persistent data
module StorageKeys {
    const PENDING_SESSIONS = "pending_sessions";
    const PENDING_DETAILS = "pending_details";    // Full details awaiting send
    const LAST_SEND_ATTEMPT = "last_send_attempt";
}

class reticccApp extends Application.AppBase {
    
    // Two-phase sync state
    private var _syncPhase as SyncPhase = SYNC_IDLE;
    private var _pendingAckSessionId as String? = null;
    private var _ackTimer as Timer.Timer? = null;
    private var _ackTimeoutMs as Number = 5000;  // 5 second timeout for ACK
    private var _pendingSessionData as Dictionary? = null;
    private var _pendingDetailsData as Dictionary? = null;  // Full details for phase 2
    private var _retryCount as Number = 0;
    private var _maxRetries as Number = 3;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        System.println("[RETIC] Registered for phone messages");
        
        // Check for pending sessions on app start
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
    // TWO-PHASE SESSION SYNC - Reliable Delivery
    // Phase 1: SESSION_SUMMARY (instant, ~300 bytes)
    // Phase 2: SESSION_DETAILS (background, full data)
    // =========================================================================
    
    // Start two-phase sync: send summary first, then details after ACK
    function sendSessionWithTwoPhase(sessionId as String, summary as Dictionary, details as Dictionary) as Void {
        System.println("[SYNC] Starting two-phase sync for: " + sessionId);
        
        // Store pending data
        _pendingAckSessionId = sessionId;
        _pendingSessionData = summary;
        _pendingDetailsData = details;
        _syncPhase = SYNC_SUMMARY;
        _retryCount = 0;
        
        // Save details to storage (in case app crashes before phase 2)
        saveDetailsToStorage(sessionId, details);
        
        // Phase 1: Send summary immediately
        System.println("[SYNC] Phase 1: Sending SESSION_SUMMARY");
        sendMessage(MessageTypes.SESSION_SUMMARY, summary);
        
        // Start ACK timeout timer
        startAckTimer();
        
        if (mainView != null) {
            mainView.setLastMsg("Syncing...");
        }
    }
    
    // Handle ACK received from phone (supports two-phase)
    private function handleAck(payload as Object?) as Void {
        if (payload == null || !(payload instanceof Dictionary)) {
            System.println("[ACK] Invalid ACK payload");
            return;
        }
        
        var ackPayload = payload as Dictionary;
        var ackSessionId = ackPayload.get("sessionId");
        var ackType = ackPayload.get("type");  // "summary" or "details"
        
        var typeStr = (ackType != null) ? ackType.toString() : "unknown";
        System.println("[ACK] Received ACK type=" + typeStr + " for session: " + (ackSessionId != null ? ackSessionId.toString() : "null"));
        
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
            // Summary ACK received - now send details
            System.println("[SYNC] ✓ Summary ACK received! Starting Phase 2...");
            
            if (mainView != null) {
                mainView.setLastMsg("Synced ✓");
            }
            
            // Phase 2: Send details in background
            if (_pendingDetailsData != null) {
                _syncPhase = SYNC_DETAILS;
                _retryCount = 0;
                
                System.println("[SYNC] Phase 2: Sending SESSION_DETAILS");
                sendMessage(MessageTypes.SESSION_DETAILS, _pendingDetailsData);
                startAckTimer();
                
                // Don't update UI - user already sees success
            } else {
                // No details to send (shouldn't happen)
                System.println("[SYNC] No details to send, sync complete");
                clearSyncState();
            }
            
        } else if (_syncPhase == SYNC_DETAILS) {
            // Details ACK received - sync complete!
            System.println("[SYNC] ✓✓ Details ACK received! Sync complete!");
            
            // Remove from storage (successful delivery)
            removeDetailsFromStorage(_pendingAckSessionId);
            
            // Clear state
            clearSyncState();
            
            if (mainView != null) {
                mainView.setLastMsg("Synced ✓");
            }
        }
    }
    
    // Clear all sync state
    private function clearSyncState() as Void {
        _pendingAckSessionId = null;
        _pendingSessionData = null;
        _pendingDetailsData = null;
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
    
    // ACK timeout callback - no ACK received in time
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
            } else if (_syncPhase == SYNC_DETAILS && _pendingDetailsData != null) {
                sendMessage(MessageTypes.SESSION_DETAILS, _pendingDetailsData);
                // Don't update UI for details retry - user already sees success
            }
            
            startAckTimer();
        } else {
            // Max retries reached
            System.println("[ACK] Max retries reached for phase " + _syncPhase);
            
            if (_syncPhase == SYNC_SUMMARY) {
                // Summary failed - save both for later
                System.println("[ACK] Summary sync failed. Saved for later.");
                if (mainView != null) {
                    mainView.setLastMsg("Saved offline");
                }
            } else if (_syncPhase == SYNC_DETAILS) {
                // Details failed but summary succeeded - OK for now
                System.println("[ACK] Details sync failed. Will retry later.");
                // Details already in storage from earlier
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
    
    // Save session details to local storage (for phase 2)
    private function saveDetailsToStorage(sessionId as String, payload as Dictionary) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_DETAILS);
            var pendingDict = {} as Dictionary<String, Dictionary>;
            
            if (pending != null && pending instanceof Dictionary) {
                pendingDict = pending as Dictionary<String, Dictionary>;
            }
            
            pendingDict.put(sessionId, payload);
            Storage.setValue(StorageKeys.PENDING_DETAILS, pendingDict);
            System.println("[STORAGE] Saved session details: " + sessionId);
        } catch (ex) {
            System.println("[STORAGE] Error saving details: " + ex.getErrorMessage());
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
    
    // Remove details from storage (after successful details ACK)
    private function removeDetailsFromStorage(sessionId as String) as Void {
        try {
            var pending = Storage.getValue(StorageKeys.PENDING_DETAILS);
            
            if (pending != null && pending instanceof Dictionary) {
                var pendingDict = pending as Dictionary<String, Dictionary>;
                pendingDict.remove(sessionId);
                Storage.setValue(StorageKeys.PENDING_DETAILS, pendingDict);
                System.println("[STORAGE] Removed details: " + sessionId);
            }
        } catch (ex) {
            System.println("[STORAGE] Error removing details: " + ex.getErrorMessage());
        }
    }
    
    // Check and retry pending sessions on app start/connection
    function checkPendingSessions() as Void {
        try {
            // First check for pending details (phase 2 retries)
            var pendingDetails = Storage.getValue(StorageKeys.PENDING_DETAILS);
            if (pendingDetails != null && pendingDetails instanceof Dictionary) {
                var detailsDict = pendingDetails as Dictionary<String, Dictionary>;
                var detailKeys = detailsDict.keys();
                
                if (detailKeys.size() > 0) {
                    System.println("[STORAGE] Found " + detailKeys.size() + " pending details to sync");
                    var firstKey = detailKeys[0] as String;
                    var detailsData = detailsDict.get(firstKey);
                    
                    if (detailsData != null && detailsData instanceof Dictionary) {
                        System.println("[STORAGE] Retrying details: " + firstKey);
                        _pendingAckSessionId = firstKey;
                        _pendingDetailsData = detailsData as Dictionary;
                        _syncPhase = SYNC_DETAILS;
                        _retryCount = 0;
                        
                        sendMessage(MessageTypes.SESSION_DETAILS, _pendingDetailsData);
                        startAckTimer();
                        return;  // Handle one at a time
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

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        mainView = new reticccView();
        return [mainView, new reticccDelegate()];
    }
}

// Communication listener for transmit callbacks
class CommListener extends Communications.ConnectionListener {
    function initialize() {
        ConnectionListener.initialize();
    }

    function onComplete() as Void {
        System.println("[COMM] ✓ Message sent successfully");
    }

    function onError() as Void {
        System.println("[COMM] ✗ Message send FAILED - check phone connection");
        // Notify view of send failure
        if (mainView != null) {
            mainView.setLastMsg("Send failed!");
        }
    }
}
