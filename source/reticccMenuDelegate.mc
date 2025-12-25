import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Application;

class reticccMenuDelegate extends WatchUi.MenuInputDelegate {

    function initialize() {
        MenuInputDelegate.initialize();
    }

    function onMenuItem(item as Symbol) as Void {
        var app = Application.getApp() as reticccApp;
        
        if (item == :mock_session) {
            // Start PRIMARY mode session (shot counter)
            app.startMockSession();
            System.println("[MENU] Primary mode session started");
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            
        } else if (item == :mock_timer) {
            // Start SUPPLEMENTARY mode session (timer only)
            app.startMockSupplementarySession();
            System.println("[MENU] Supplementary mode session started");
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            
        } else if (item == :mock_env) {
            // Load mock environment data
            app.setMockEnvironment();
            System.println("[MENU] Mock environment loaded");
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            
        } else if (item == :mock_personal) {
            // Load mock personal data
            app.setMockPersonal();
            System.println("[MENU] Mock personal loaded");
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            
        } else if (item == :mock_all) {
            // Load everything and start session
            app.loadAllMockData();
            System.println("[MENU] All mock data loaded");
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        }
        
        WatchUi.requestUpdate();
    }
}