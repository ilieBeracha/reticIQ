import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Communications;
import Toybox.Time;
import Toybox.System;

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
    const SESSION_RESULT = "SESSION_RESULT";
    const WEATHER = "WEATHER";
}

class reticccApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        System.println("[RETIC] Registered for phone messages");
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
            
        } else if (typeStr.equals(MessageTypes.SESSION_START)) {
            if (mainView != null && payload != null && payload instanceof Dictionary) {
                mainView.startSession(payload as Dictionary);
                sendMessage(MessageTypes.ACK, {"status" => "session_started"});
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
        System.println("[RETIC] Message sent OK");
    }

    function onError() as Void {
        System.println("[RETIC] Message send FAILED");
    }
}
