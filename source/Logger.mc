import Toybox.Communications;
import Toybox.System;
import Toybox.Time;
import Toybox.Lang;

// PostHog Analytics - Events only
class Logger {
    private const API_KEY = "phc_Kv1gWbvZFOJuT3OvUOmylqWIcQQBuqS5bCNuCNl06WN";
    private const CAPTURE_URL = "https://us.i.posthog.com/capture/";
    
    function initialize() {
    }
    
    // Track analytics event
    function track(eventName as String, props as Dictionary?, createPersonProfile as Boolean) as Void {
        var properties = {} as Dictionary<String, Object>;
        properties.put("distinct_id", getDeviceId());
        properties.put("app_version", "1.0.3");
        properties.put("platform", "garmin_connectiq");
        properties.put("$process_person_profile", createPersonProfile);
        
        if (props != null) {
            var keys = props.keys();
            for (var i = 0; i < keys.size(); i++) {
                var key = keys[i] as String;
                properties.put(key, props.get(keys[i]));
            }
        }
        
        var event = {} as Dictionary<String, Object>;
        event.put("api_key", API_KEY);
        event.put("event", eventName);
        event.put("properties", properties);
        event.put("timestamp", getISOTimestamp());
        
        System.println("[LOG] Event: " + eventName);
        
        Communications.makeWebRequest(CAPTURE_URL, event as Dictionary, {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {"Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON},
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        }, method(:onResponse));
    }
    
    function onResponse(responseCode as Number, data as Null or Dictionary or String) as Void {
        if (responseCode == 200 || responseCode == 1) {
            System.println("[LOG] ✓ Sent");
        } else {
            System.println("[LOG] ✗ " + getErrorDescription(responseCode));
        }
    }
    
    private function getErrorDescription(code as Number) as String {
        if (code == -2) { return "Phone not responding"; }
        if (code == -104) { return "No phone connection"; }
        if (code == -300) { return "Timeout"; }
        if (code == 401) { return "Bad API key"; }
        if (code == 429) { return "Rate limited"; }
        return "Error " + code;
    }
    
    // Convenience methods
    function logEvent(eventName as String, properties as Dictionary?) as Void {
        track(eventName, properties, true);
    }
    
    function logError(errorCode as String, message as String) as Void {
        track("app_error", {
            "error_code" => errorCode,
            "error_message" => message
        }, true);
    }
    
    function logWarning(warningCode as String, message as String) as Void {
        track("app_warning", {
            "warning_code" => warningCode,
            "warning_message" => message
        }, true);
    }
    
    function logSessionMetrics(sessionId as String, shots as Number, accuracy as Number, avgHR as Number) as Void {
        track("session_completed", {
            "session_id" => sessionId,
            "shots" => shots,
            "accuracy_pct" => accuracy,
            "avg_hr" => avgHR
        }, true);
    }
    
    function logSyncEvent(status as String, phaseType as String, details as Dictionary?) as Void {
        var props = {
            "sync_status" => status,
            "sync_phase" => phaseType
        } as Dictionary<String, Object>;
        
        if (details != null) {
            var keys = details.keys();
            for (var i = 0; i < keys.size(); i++) {
                var key = keys[i] as String;
                props.put(key, details.get(key));
            }
        }
        
        track("sync_" + status, props, true);
    }
    
    function flush() as Void {}
    
    private function getDeviceId() as String {
        return System.getDeviceSettings().uniqueIdentifier;
    }
    
    private function getISOTimestamp() as String {
        var now = Time.now();
        var info = Time.Gregorian.info(now, Time.FORMAT_SHORT);
        return info.year + "-" + pad(info.month as Number) + "-" + pad(info.day as Number) + "T" + 
               pad(info.hour as Number) + ":" + pad(info.min as Number) + ":" + pad(info.sec as Number) + "Z";
    }
    
    private function pad(num as Number) as String {
        return num < 10 ? "0" + num : num.toString();
    }
}

// Get global logger instance
function getLogger() as Logger {
    if (logger == null) {
        logger = new Logger();
    }
    return logger as Logger;
}
