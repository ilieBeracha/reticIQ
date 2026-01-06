import Toybox.Lang;
import Toybox.System;
import Toybox.Weather;
import Toybox.Time;
import Toybox.Application;

// Weather data structure for shooting conditions
class ShootingWeather {
    var temperature as Number = 0;         // Celsius
    var humidity as Number = 0;            // Percentage (0-100)
    var windSpeed as Number = 0;           // m/s
    var windDirection as String = "";      // Cardinal direction (N, NE, E, etc.)
    var windBearing as Number = 0;         // Degrees (0-360)
    var pressure as Number = 0;            // hPa (millibars)
    var condition as Number = 0;           // Weather.CONDITION_*
    var conditionStr as String = "Unknown";
    var observationTime as Number = 0;     // Unix timestamp
    var isAvailable as Boolean = false;    // True if data was fetched successfully
    
    // Flags to distinguish 0 from "no data"
    var hasTemperature as Boolean = false;
    var hasHumidity as Boolean = false;
    var hasPressure as Boolean = false;
    var hasWind as Boolean = false;
    
    function initialize() {}
    
    // Convert to dictionary for sending to phone
    function toDict() as Dictionary {
        var dict = {} as Dictionary<String, Object>;
        
        if (hasTemperature) {
            dict.put("temperature", temperature);
        }
        if (hasHumidity) {
            dict.put("humidity", humidity);
        }
        if (hasWind) {
            dict.put("windSpeed", windSpeed);
            dict.put("windDirection", windDirection);
            dict.put("windBearing", windBearing);
        }
        if (hasPressure) {
            dict.put("pressure", pressure);
        }
        if (!conditionStr.equals("Unknown")) {
            dict.put("condition", conditionStr);
        }
        if (observationTime > 0) {
            dict.put("observationTime", observationTime);
        }
        
        dict.put("isAvailable", isAvailable);
        
        return dict;
    }
    
    // Compact dict for inclusion in session payloads (smaller)
    function toCompactDict() as Dictionary? {
        if (!isAvailable) {
            return null;
        }
        
        var dict = {} as Dictionary<String, Object>;
        
        if (hasTemperature) { dict.put("temp", temperature); }
        if (hasHumidity) { dict.put("hum", humidity); }
        if (hasWind) { 
            dict.put("wind", windSpeed); 
            dict.put("windDir", windDirection);
        }
        if (hasPressure) { dict.put("press", pressure); }
        
        return dict;
    }
    
    function toString() as String {
        if (!isAvailable) {
            return "Weather: N/A";
        }
        var parts = [] as Array<String>;
        if (hasTemperature) { parts.add(temperature.toString() + "C"); }
        if (hasWind) { parts.add(windSpeed.toString() + "m/s " + windDirection); }
        if (hasHumidity) { parts.add(humidity.toString() + "% RH"); }
        
        var result = "";
        for (var i = 0; i < parts.size(); i++) {
            if (i > 0) { result = result + ", "; }
            result = result + parts[i];
        }
        return result;
    }
}

class WeatherService {
    private var _lastWeather as ShootingWeather;
    private var _lastFetchTime as Number = 0;
    private const CACHE_DURATION_MS = 300000;  // 5 minutes cache
    
    function initialize() {
        _lastWeather = new ShootingWeather();
    }
    
    // Get current weather conditions
    // Returns cached data if less than 5 minutes old
    function getCurrentWeather() as ShootingWeather {
        var now = System.getTimer();
        
        // Return cached if fresh enough
        if (_lastWeather.isAvailable && (now - _lastFetchTime) < CACHE_DURATION_MS) {
            return _lastWeather;
        }
        
        // Fetch fresh data
        _lastWeather = fetchWeather();
        _lastFetchTime = now;
        
        return _lastWeather;
    }
    
    // Force refresh weather data
    function refreshWeather() as ShootingWeather {
        _lastWeather = fetchWeather();
        _lastFetchTime = System.getTimer();
        return _lastWeather;
    }
    
    // Fetch weather from Garmin Weather API
    private function fetchWeather() as ShootingWeather {
        var weather = new ShootingWeather();
        
        // Check if Weather API is available on this device
        if (!(Weather has :getCurrentConditions)) {
            System.println("[WEATHER] Weather API not available on this device");
            return weather;
        }
        
        try {
            var conditions = Weather.getCurrentConditions();
            
            if (conditions == null) {
                System.println("[WEATHER] No weather data available (Garmin Connect not synced?)");
                return weather;
            }
            
            // Temperature
            if (conditions.temperature != null) {
                weather.temperature = conditions.temperature.toNumber();
                weather.hasTemperature = true;
            }
            
            // Humidity
            if (conditions has :relativeHumidity && conditions.relativeHumidity != null) {
                weather.humidity = conditions.relativeHumidity;
                weather.hasHumidity = true;
            }
            
            // Wind speed
            if (conditions.windSpeed != null) {
                weather.windSpeed = conditions.windSpeed.toNumber();
                weather.hasWind = true;
            }
            
            // Wind direction
            if (conditions.windBearing != null) {
                weather.windBearing = conditions.windBearing;
                weather.windDirection = bearingToCardinal(conditions.windBearing);
                weather.hasWind = true;
            }
            
            // Pressure (some devices provide this)
            if (conditions has :pressure && conditions.pressure != null) {
                // Convert from Pascals to hPa (millibars)
                weather.pressure = (conditions.pressure / 100).toNumber();
                weather.hasPressure = true;
            }
            
            // Condition
            if (conditions.condition != null) {
                weather.condition = conditions.condition;
                weather.conditionStr = conditionToString(conditions.condition);
            }
            
            // Observation time
            if (conditions.observationTime != null) {
                weather.observationTime = conditions.observationTime.value();
            }
            
            weather.isAvailable = true;
            
            System.println("[WEATHER] Fetched: " + weather.toString());
            
        } catch (ex) {
            System.println("[WEATHER] Error fetching weather: " + ex.getErrorMessage());
        }
        
        return weather;
    }
    
    // Convert degrees to cardinal direction
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
    
    // Convert condition code to readable string
    private function conditionToString(condition as Number) as String {
        // Check if Weather module has the condition constants
        if (!(Weather has :CONDITION_CLEAR)) {
            return "Unknown";
        }
        
        switch (condition) {
            case Weather.CONDITION_CLEAR:
                return "Clear";
            case Weather.CONDITION_PARTLY_CLOUDY:
                return "Partly Cloudy";
            case Weather.CONDITION_MOSTLY_CLOUDY:
                return "Mostly Cloudy";
            case Weather.CONDITION_RAIN:
                return "Rain";
            case Weather.CONDITION_SNOW:
                return "Snow";
            case Weather.CONDITION_WINDY:
                return "Windy";
            case Weather.CONDITION_THUNDERSTORMS:
                return "Thunderstorms";
            case Weather.CONDITION_FOG:
                return "Fog";
            case Weather.CONDITION_HAZY:
                return "Hazy";
            case Weather.CONDITION_HAIL:
                return "Hail";
            case Weather.CONDITION_SCATTERED_SHOWERS:
                return "Scattered Showers";
            default:
                return "Unknown";
        }
    }
    
    // Get wind description for shooting (helpful for long range)
    function getWindDescription() as String {
        var weather = getCurrentWeather();
        
        if (!weather.isAvailable || !weather.hasWind) {
            return "Wind: Unknown";
        }
        
        var speedMph = weather.windSpeed * 2.237;  // m/s to mph
        var description;
        
        if (speedMph < 3) {
            description = "Calm";
        } else if (speedMph < 8) {
            description = "Light";
        } else if (speedMph < 13) {
            description = "Moderate";
        } else if (speedMph < 19) {
            description = "Fresh";
        } else if (speedMph < 25) {
            description = "Strong";
        } else {
            description = "Very Strong";
        }
        
        return description + " " + weather.windDirection + " (" + 
               speedMph.format("%.0f") + " mph)";
    }
    
    // Check if conditions are good for shooting
    function isGoodShootingWeather() as Boolean {
        var weather = getCurrentWeather();
        
        if (!weather.isAvailable) {
            return true;  // Unknown = assume OK
        }
        
        // Bad conditions - check if constants exist first
        if (Weather has :CONDITION_RAIN) {
            if (weather.condition == Weather.CONDITION_RAIN ||
                weather.condition == Weather.CONDITION_THUNDERSTORMS ||
                weather.condition == Weather.CONDITION_SNOW ||
                weather.condition == Weather.CONDITION_HAIL) {
                return false;
            }
        }
        
        // High wind (>15 mph = 6.7 m/s)
        if (weather.hasWind && weather.windSpeed > 6.7) {
            return false;
        }
        
        return true;
    }
    
    // Send current weather to phone
    function sendWeatherToPhone() as Void {
        var weather = getCurrentWeather();
        
        if (!weather.isAvailable) {
            System.println("[WEATHER] No weather data to send");
            return;
        }
        
        var app = Application.getApp() as reticccApp;
        var payload = {
            "weather" => weather.toDict(),
            "timestamp" => Time.now().value()
        };
        
        app.sendMessage("WEATHER_UPDATE", payload);
        System.println("[WEATHER] Sent weather update to phone");
    }
}
