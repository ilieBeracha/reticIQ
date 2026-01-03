// TimelineChunker.mc - Splits timeline data into small chunks for reliable sync
// Each chunk is ~800 bytes max (20 points + 8 shots), well under Garmin's ~1KB BLE limit
// Both points AND shots are spread across chunks to handle high shot counts
// Chunks are sent sequentially with ACK-per-chunk for guaranteed delivery

import Toybox.Lang;
import Toybox.System;

// Configuration
module ChunkConfig {
    // Garmin BLE message limit is ~1KB.
    // Each point: ~20 bytes as JSON [8,72,14,35,0]
    // Each shot: ~50 bytes as JSON {n:1,t:5,hr:72,br:14,bp:2,st:35,sd:80,fl:0}
    // Wrapper: ~100 bytes (sid, chunk, total)
    //
    // Strategy: Split both points AND shots to stay under 800 bytes per chunk.
    const POINTS_PER_CHUNK = 20;      // 20 points = ~400 bytes
    const SHOTS_PER_CHUNK = 8;        // 8 shots = ~400 bytes
    const TIMELINE_SAMPLE_INTERVAL = 3000;  // Sample every 3 seconds
    const MAX_TIMELINE_DURATION = 600000;   // 10 min max = 200 points max
}

// Represents a single timeline point (ultra-compact)
// Format: [timestamp_sec, hr, breath_rate, stress, event_type]
// event_type: 0=regular, 1=shot, 2=hit
class TimelinePoint {
    var t as Number;      // Timestamp in SECONDS since session start (not ms)
    var hr as Number;     // Heart rate BPM
    var br as Number;     // Breath rate (breaths/min, integer)
    var st as Number;     // Stress score 0-100
    var ev as Number;     // Event: 0=sample, 1=shot, 2=hit

    function initialize(timestamp as Number, heartRate as Number, breathRate as Number, stress as Number, event as Number) {
        t = timestamp;
        hr = heartRate;
        br = breathRate;
        st = stress;
        ev = event;
    }

    // Ultra-compact array format: [t, hr, br, st, ev]
    function toArray() as Array<Number> {
        return [t, hr, br, st, ev];
    }
}

// Manages timeline data collection and chunking
class TimelineChunker {

    private var _points as Array<TimelinePoint>;
    private var _shotEvents as Array<Dictionary>;  // Shot-specific details
    private var _sessionId as String = "";
    private var _totalChunks as Number = 0;

    function initialize() {
        _points = [];
        _shotEvents = [];
    }

    // Reset for new session
    function reset(sessionId as String) as Void {
        _sessionId = sessionId;
        _points = [];
        _shotEvents = [];
        _totalChunks = 0;
    }

    // Add a regular timeline sample (called every 3 seconds)
    function addSample(timestampMs as Number, hr as Number, breathRate as Float, stress as Number) as Void {
        var timestampSec = timestampMs / 1000;  // Convert to seconds
        var point = new TimelinePoint(timestampSec, hr, breathRate.toNumber(), stress, 0);
        _points.add(point);

        // Trim if too long (10 min max)
        var maxPoints = ChunkConfig.MAX_TIMELINE_DURATION / ChunkConfig.TIMELINE_SAMPLE_INTERVAL;
        if (_points.size() > maxPoints) {
            _points = _points.slice(-maxPoints.toNumber(), null) as Array<TimelinePoint>;
        }
    }

    // Add a shot event (called on each shot)
    function addShotEvent(
        shotNumber as Number,
        timestampMs as Number,
        hr as Number,
        breathRate as Float,
        breathPhase as String,
        stress as Number,
        steadiness as Number,
        flinch as Boolean,
        isHit as Boolean
    ) as Void {
        var timestampSec = timestampMs / 1000;

        // Add to timeline with event marker
        var eventType = isHit ? 2 : 1;
        var point = new TimelinePoint(timestampSec, hr, breathRate.toNumber(), stress, eventType);
        _points.add(point);

        // Store shot-specific details
        var shotDetail = {
            "n" => shotNumber,
            "t" => timestampSec,
            "hr" => hr,
            "br" => breathRate.toNumber(),
            "bp" => encodeBreathPhase(breathPhase),  // 0=inhale, 1=exhale, 2=pause
            "st" => stress,
            "sd" => steadiness,
            "fl" => flinch ? 1 : 0
        };
        _shotEvents.add(shotDetail);
    }

    // Encode breath phase to single digit
    private function encodeBreathPhase(phase as String) as Number {
        if (phase.equals("inhale")) { return 0; }
        if (phase.equals("exhale")) { return 1; }
        if (phase.equals("pause")) { return 2; }
        return 3;  // unknown
    }

    // Get total number of chunks needed (accounts for both points AND shots)
    function getChunkCount() as Number {
        if (_points.size() == 0 && _shotEvents.size() == 0) {
            return 0;
        }

        // Calculate chunks needed for points
        var pointChunks = 0;
        if (_points.size() > 0) {
            pointChunks = ((_points.size() - 1) / ChunkConfig.POINTS_PER_CHUNK) + 1;
        }

        // Calculate chunks needed for shots (spread across point chunks, overflow to extra)
        var shotChunks = 0;
        if (_shotEvents.size() > 0) {
            shotChunks = ((_shotEvents.size() - 1) / ChunkConfig.SHOTS_PER_CHUNK) + 1;
        }

        // Use the larger of the two (shots are spread across point chunks)
        _totalChunks = pointChunks > shotChunks ? pointChunks : shotChunks;
        if (_totalChunks == 0) {
            _totalChunks = 1;
        }

        return _totalChunks;
    }

    // Get a specific chunk (0-indexed)
    // Points and shots are distributed across chunks to stay under size limit
    function getChunk(chunkIndex as Number) as Dictionary? {
        var totalChunks = getChunkCount();
        if (chunkIndex < 0 || chunkIndex >= totalChunks) {
            return null;
        }

        // === POINTS for this chunk ===
        var pointsData = [] as Array<Array<Number>>;
        var pointStartIdx = chunkIndex * ChunkConfig.POINTS_PER_CHUNK;
        var pointEndIdx = pointStartIdx + ChunkConfig.POINTS_PER_CHUNK;
        if (pointEndIdx > _points.size()) {
            pointEndIdx = _points.size();
        }

        for (var i = pointStartIdx; i < pointEndIdx; i++) {
            pointsData.add(_points[i].toArray());
        }

        // === SHOTS for this chunk (spread across chunks) ===
        var shotsData = [] as Array<Dictionary>;
        var shotStartIdx = chunkIndex * ChunkConfig.SHOTS_PER_CHUNK;
        var shotEndIdx = shotStartIdx + ChunkConfig.SHOTS_PER_CHUNK;
        if (shotEndIdx > _shotEvents.size()) {
            shotEndIdx = _shotEvents.size();
        }

        for (var i = shotStartIdx; i < shotEndIdx; i++) {
            shotsData.add(_shotEvents[i]);
        }

        return {
            "sid" => _sessionId,
            "chunk" => chunkIndex,
            "total" => totalChunks,
            "pts" => pointsData,           // [[t,hr,br,st,ev], ...]
            "shots" => shotsData.size() > 0 ? shotsData : null  // Shots for this chunk
        };
    }

    // Get all chunks as array (for storage/retry)
    function getAllChunks() as Array<Dictionary> {
        var chunks = [] as Array<Dictionary>;
        var total = getChunkCount();

        for (var i = 0; i < total; i++) {
            var chunk = getChunk(i);
            if (chunk != null) {
                chunks.add(chunk);
            }
        }

        return chunks;
    }

    // Get session ID
    function getSessionId() as String {
        return _sessionId;
    }

    // Check if there's any timeline data
    function hasData() as Boolean {
        return _points.size() > 0;
    }

    // Get point count
    function getPointCount() as Number {
        return _points.size();
    }

    // Get shot count
    function getShotCount() as Number {
        return _shotEvents.size();
    }

    // Estimate total payload size in bytes (rough)
    function estimatePayloadBytes() as Number {
        // Each point: ~20 bytes as JSON array [8,72,14,35,0]
        // Each shot: ~50 bytes as JSON object
        // Wrapper overhead: ~100 bytes (sid, chunk, total)
        return (_points.size() * 20) + (_shotEvents.size() * 50) + 100;
    }

    // Estimate single chunk size in bytes
    function estimateChunkBytes(chunkIndex as Number) as Number {
        var total = getChunkCount();
        if (chunkIndex < 0 || chunkIndex >= total) {
            return 0;
        }

        // Points in this chunk
        var pointStart = chunkIndex * ChunkConfig.POINTS_PER_CHUNK;
        var pointEnd = pointStart + ChunkConfig.POINTS_PER_CHUNK;
        if (pointEnd > _points.size()) {
            pointEnd = _points.size();
        }
        var pointCount = pointEnd > pointStart ? pointEnd - pointStart : 0;

        // Shots in this chunk
        var shotStart = chunkIndex * ChunkConfig.SHOTS_PER_CHUNK;
        var shotEnd = shotStart + ChunkConfig.SHOTS_PER_CHUNK;
        if (shotEnd > _shotEvents.size()) {
            shotEnd = _shotEvents.size();
        }
        var shotCount = shotEnd > shotStart ? shotEnd - shotStart : 0;

        // Wrapper (~100) + points (~20 each) + shots (~50 each)
        return 100 + (pointCount * 20) + (shotCount * 50);
    }

    // Get FULL timeline as single payload (for web request - no chunking needed)
    // Web requests support ~100KB so we can send everything at once
    function getFullPayload() as Dictionary {
        var pointsData = [] as Array<Array<Number>>;
        for (var i = 0; i < _points.size(); i++) {
            pointsData.add(_points[i].toArray());
        }

        return {
            "sid" => _sessionId,
            "pts" => pointsData,      // All timeline points
            "shots" => _shotEvents    // All shot details
        };
    }
}
