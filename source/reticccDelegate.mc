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

    // Handle tap/select - behavior depends on watch mode
    // PRIMARY mode: Add shot, enforce limits
    // SUPPLEMENTARY mode: Record split time (optional)
    function onSelect() as Boolean {
        if (mainView != null) {
            var state = mainView.getState();
            
            if (state == STATE_SESSION_ACTIVE) {
                // Only handle on main page
                if (mainView.getCurrentPage() == PAGE_MAIN) {
                    var result = mainView.addShot();
                    
                    if (Attention has :vibrate) {
                        if (result == :completed) {
                            // Session complete! Long vibration
                            var vibeData = [
                                new Attention.VibeProfile(100, 500)  // Long strong pulse
                            ];
                            Attention.vibrate(vibeData);
                        } else if (result == :added) {
                            // Shot recorded - short double pulse
                            var vibeData = [
                                new Attention.VibeProfile(100, 50),
                                new Attention.VibeProfile(0, 30),
                                new Attention.VibeProfile(50, 30)
                            ];
                            Attention.vibrate(vibeData);
                        } else if (result == :blocked) {
                            // At max - error vibration (triple short)
                            var vibeData = [
                                new Attention.VibeProfile(50, 30),
                                new Attention.VibeProfile(0, 50),
                                new Attention.VibeProfile(50, 30),
                                new Attention.VibeProfile(0, 50),
                                new Attention.VibeProfile(50, 30)
                            ];
                            Attention.vibrate(vibeData);
                        }
                    }
                }
            } else if (state == STATE_SESSION_ENDED) {
                mainView.resetToIdle();
            }
        }
        return true;
    }

    // Handle back button - finish session early
    function onBack() as Boolean {
        if (mainView != null) {
            var state = mainView.getState();
            
            if (state == STATE_SESSION_ACTIVE) {
                // End session early (completed = false)
                if (Attention has :vibrate) {
                    // Double short pulse for early end
                    var vibeData = [
                        new Attention.VibeProfile(50, 50),
                        new Attention.VibeProfile(0, 50),
                        new Attention.VibeProfile(50, 50)
                    ];
                    Attention.vibrate(vibeData);
                }
                mainView.finishSession();
                return true;
            } else if (state == STATE_SESSION_ENDED) {
                mainView.resetToIdle();
                return true;
            }
        }
        return false;  // Let back exit app in idle
    }

    // Handle screen tap (for touch devices)
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return onSelect();
    }
    
    // Handle UP/DOWN for page navigation during session
    function onNextPage() as Boolean {
        if (mainView != null && mainView.getState() == STATE_SESSION_ACTIVE) {
            mainView.pageDown();
            return true;
        }
        return false;
    }
    
    function onPreviousPage() as Boolean {
        if (mainView != null && mainView.getState() == STATE_SESSION_ACTIVE) {
            mainView.pageUp();
            return true;
        }
        return false;
    }
}