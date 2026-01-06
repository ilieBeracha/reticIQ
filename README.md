# reticIQ

## Phone Integration: Weather Data

### Receiving Weather in SESSION_SUMMARY

When the watch sends a `SESSION_SUMMARY` message, it includes weather conditions captured at the shooting session location:

```typescript
// SESSION_SUMMARY payload includes:
{
  "sid": "session-123",
  "shots": 10,
  "dur": 45000,
  // ... other fields ...
  
  "weather": {
    "t": 220,      // Temperature in Celsius × 10 (22.0°C)
    "h": 65,       // Humidity percentage (0-100)
    "ws": 35,      // Wind speed in m/s × 10 (3.5 m/s)
    "wd": "NW",    // Wind direction cardinal (N, NE, E, SE, S, SW, W, NW)
    "wb": 315,     // Wind bearing in degrees (0-360)
    "p": 1013,     // Pressure in hPa (millibars)
    "c": "PartlyCloudy"  // Condition string
  }
}
```

### Decoding Weather Values

```typescript
interface SessionWeather {
  t?: number;   // Temp × 10 → divide by 10 for actual Celsius
  h?: number;   // Humidity % (direct)
  ws?: number;  // Wind m/s × 10 → divide by 10 for actual speed
  wd?: string;  // Cardinal direction (N, NE, E, SE, S, SW, W, NW)
  wb?: number;  // Bearing degrees (0-360)
  p?: number;   // Pressure hPa (direct)
  c?: string;   // Condition string
}

function decodeWeather(weather: SessionWeather | null) {
  if (!weather) return null;
  
  return {
    temperatureC: weather.t != null ? weather.t / 10 : null,
    temperatureF: weather.t != null ? (weather.t / 10) * 9/5 + 32 : null,
    humidity: weather.h ?? null,
    windSpeedMps: weather.ws != null ? weather.ws / 10 : null,
    windSpeedMph: weather.ws != null ? (weather.ws / 10) * 2.237 : null,
    windDirection: weather.wd ?? null,
    windBearing: weather.wb ?? null,
    pressureHpa: weather.p ?? null,
    condition: weather.c ?? null,
  };
}
```

### Condition Strings

The `c` field contains one of these condition strings:

| Value | Description |
|-------|-------------|
| `Clear` | Clear sky |
| `PartlyCloudy` | Partly cloudy |
| `MostlyCloudy` | Mostly cloudy |
| `Cloudy` | Overcast |
| `Rain` | Rain |
| `LightRain` | Light rain |
| `HeavyRain` | Heavy rain |
| `Snow` | Snow |
| `LightSnow` | Light snow |
| `HeavySnow` | Heavy snow |
| `Windy` | Windy conditions |
| `Thunderstorms` | Thunderstorms |
| `Fog` | Fog/mist |
| `Hazy` | Hazy |
| `Hail` | Hail |
| `ScatteredShowers` | Scattered showers |
| `ScatteredThunderstorms` | Scattered thunderstorms |
| `Dust` | Dust |
| `Drizzle` | Drizzle |
| `Tornado` | Tornado |
| `Smoke` | Smoke |
| `Ice` | Ice |
| `Sand` | Sand |
| `Squall` | Squall |
| `Sandstorm` | Sandstorm |
| `VolcanicAsh` | Volcanic ash |
| `Fair` | Fair weather |
| `Hurricane` | Hurricane |
| `TropicalStorm` | Tropical storm |
| `Unknown` | Unknown/unavailable |

### Weather Availability

- Weather data comes from the watch's Garmin Weather API
- Requires the watch to have recent weather sync (typically from phone GPS)
- `weather` field will be `null` if weather data is unavailable
- Individual fields may be missing if that specific data isn't available
- Data is cached for 5 minutes on the watch

### Example Phone Handler

```typescript
function handleSessionSummary(payload: SessionSummaryPayload) {
  const weather = decodeWeather(payload.weather);
  
  if (weather) {
    console.log(`Session weather: ${weather.temperatureF?.toFixed(1)}°F, ` +
                `Wind ${weather.windSpeedMph?.toFixed(1)} mph ${weather.windDirection}, ` +
                `${weather.condition}`);
    
    // Store with session for later analysis
    saveSessionWeather(payload.sid, weather);
  }
}
```

### Wind for Shooting Analysis

Wind is critical for shooting accuracy. Use wind data for:

- **Bullet drift calculation**: Wind speed + direction relative to firing line
- **Condition assessment**: Flag sessions with challenging conditions
- **Performance correlation**: Compare accuracy vs. wind conditions

```typescript
function getWindImpact(windSpeedMps: number): string {
  if (windSpeedMps < 2) return 'calm';      // < 2 m/s: minimal impact
  if (windSpeedMps < 5) return 'light';     // 2-5 m/s: noticeable
  if (windSpeedMps < 8) return 'moderate';  // 5-8 m/s: significant
  return 'strong';                           // 8+ m/s: challenging
}
```
