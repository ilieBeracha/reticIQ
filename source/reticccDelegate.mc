import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Attention;

class reticccDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onMenu() as Boolean {
        WatchUi.pushView(new Rez.Menus.MainMenu(), new reticccMenuDelegate(), WatchUi.SLIDE_UP);
        return true;
    }

    // Handle tap/select - add shot during session, reset when ended
    function onSelect() as Boolean {
        if (mainView != null) {
            var state = mainView.getState();
            
            if (state == STATE_SESSION_ACTIVE) {
                // During session - count shot
                var added = mainView.addShot();
                if (added) {
                    // Vibrate to confirm shot counted
                    if (Attention has :vibrate) {
                        var vibeData = [new Attention.VibeProfile(50, 100)];
                        Attention.vibrate(vibeData);
                    }
                }
            } else if (state == STATE_SESSION_ENDED) {
                // Session ended - reset to idle
                mainView.resetToIdle();
            }
        }
        return true;
    }

    // Handle back button - finish session early (send results)
    function onBack() as Boolean {
        if (mainView != null) {
            var state = mainView.getState();
            
            if (state == STATE_SESSION_ACTIVE) {
                // During session - finish early and send results
                mainView.finishSession();
                return true;  // Don't exit app
            } else if (state == STATE_SESSION_ENDED) {
                // Already ended - reset
                mainView.resetToIdle();
                return true;
            }
        }
        // In idle state - let back exit the app (return false)
        return false;
    }

    // Handle screen tap (for touch devices)
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return onSelect();  // Same as button press
    }
}
