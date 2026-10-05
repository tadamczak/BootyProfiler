-- Build only for a completed scan. This reads bounded recorded data, never the
-- client, and keeps no references to session buffers, callbacks or frames.
local P = BootyProfiler
local Report = {}
P.HealthReport = Report
local FINDING_LIMIT, SAMPLE_LIMIT, DROP_LIMIT, CALLBACK_LIMIT, MOS_LIMIT = 8, 600, 64, 4096, 128
Report.limits = { findings = FINDING_LIMIT, samples = SAMPLE_LIMIT, drops = DROP_LIMIT,
    callbacks = CALLBACK_LIMIT, operations = MOS_LIMIT }
local rules = P.Health and P.Health.thresholds

local function Valid(value)
    return type(value) == "number" and value == value and value >= 0 and value < 1e300
end
local function Number(value) return Valid(value) and value or nil end
local function Text(value, limit)
    if type(value) ~= "string" then return nil end
    value = string.gsub(string.sub(value, 1, limit or 120), "[%c]", " ")
    return value ~= "" and value or nil
end
local function Format(value, unit)
    if not Valid(value) then return "unavailable" end
    return string.format(value < 10000000 and "%.1f%s" or "%.3g%s", value, unit or "")
end
local function Count(value)
    return Valid(value) and math.floor(value) or 0
end
local function Retained(buffer, limit)
    if type(buffer) ~= "table" then return 0 end
    if Valid(buffer.count) and Valid(buffer.total) then return math.min(Count(buffer.count), limit) end
    return math.min(table.getn(buffer), limit)
end
local function Entry(buffer, index)
    if Valid(buffer.count) and Valid(buffer.total) and buffer.count > 0 then
        local count, total = Count(buffer.count), Count(buffer.total)
        local oldest = total > count and total - math.floor(total / count) * count + 1 or 1
        index = oldest + index - 2
        index = index - math.floor(index / count) * count + 1
    end
    local entry = buffer[index]
    return type(entry) == "table" and entry or nil
end
local function Add(report, code, title, evidence, reason, action, severity)
    local findings = report.findings
    local nextFinding = { code = code, title = title, evidence = evidence, reason = reason, action = action, severity = severity }
    local index = 1
    while index <= table.getn(findings) and findings[index].severity >= severity do index = index + 1 end
    if index > FINDING_LIMIT then return end
    table.insert(findings, index, nextFinding)
    if table.getn(findings) > FINDING_LIMIT then table.remove(findings) end
end
local function Outcome(report, code, status, summary, severity)
    if severity > report.severity or severity == report.severity and (report.code == "limited" or report.code == "insufficient" or report.code == "stable") then
        report.code, report.status, report.summary, report.severity = code, status, summary, severity
    end
end

local function Samples(session)
    local result = { count = Retained(session.samples, SAMPLE_LIMIT), validHeap = 0, validThreshold = 0,
        lowFPSRun = 0, lowFPS = false, highLatencyRun = 0, highLatency = false,
        memoryPressure = false, retainedGrowth = false }
    local health = P.Health and P.Health.New()
    local previousAt
    for index = 1, result.count do
        local entry = Entry(session.samples, index)
        if entry then
            local at = Number(entry.at)
            local contiguous = at and (not previousAt or at > previousAt and at - previousAt <= rules.maximumSampleGap)
            if not contiguous then result.lowFPSRun, result.highLatencyRun = 0, 0 end
            local fps, latency = Number(entry.fps), Number(entry.latency)
            result.lowFPSRun = contiguous and fps and fps > 0 and fps < rules.lowFPS and result.lowFPSRun + 1 or 0
            result.highLatencyRun = contiguous and latency and latency >= rules.latencyMS and result.highLatencyRun + 1 or 0
            if result.lowFPSRun >= rules.lowFPSSamples then result.lowFPS = true end
            if result.highLatencyRun >= rules.latencySamples then result.highLatency = true end
            if Valid(entry.heap) then result.validHeap = result.validHeap + 1 end
            if Valid(entry.gcThreshold) and entry.gcThreshold > 0 then result.validThreshold = result.validThreshold + 1 end
            if health then
                if Valid(entry.windowMaxFrameGap) then P.Health.ObserveFrame(health, entry.windowMaxFrameGap) end
                local cleanups = health.cleanupCount
                P.Health.Sample(health, at, fps, latency, Number(entry.heap), Number(entry.gcThreshold))
                if health.highMemory then result.memoryPressure = true end
                if health.memoryGrowing and health.cleanupCount > cleanups then
                    result.retainedGrowth = true
                    result.growthKB = math.max(result.growthKB or 0, entry.heap - health.cleanupFloor)
                end
            end
            previousAt = at
        else
            previousAt, result.lowFPSRun, result.highLatencyRun = nil, 0, 0
            if health then P.Health.Sample(health, nil, nil, nil, nil, nil) end
        end
    end
    result.partial = type(session.samples) == "table" and Valid(session.samples.total) and session.samples.total > result.count
    return result
end

local function TopCallback(callbacks)
    local best, bestTime, longest, longestPeak = nil, -1, nil, 0
    local operations = type(callbacks.operations) == "table" and callbacks.operations or {}
    for index = 1, math.min(table.getn(operations), CALLBACK_LIMIT) do
        local item = operations[index]
        if type(item) == "table" then
            local time, peak = Number(item.selfTime), Number(item.peak)
            if time and time > bestTime and Count(item.calls) > 0 then best, bestTime = item, time end
            if peak and peak > longestPeak and Count(item.calls) > 0 then longest, longestPeak = item, peak end
        end
    end
    return best, math.max(0, bestTime), longest, longestPeak
end
local function TopMOS(session)
    if type(session.operations) ~= "table" then return nil, 0, 0 end
    local count, best, bestTime, bestName, reads = 0, nil, 0, nil, 0
    local key, item = next(session.operations)
    while key ~= nil and reads < MOS_LIMIT do
        if type(item) == "table" then
            count = count + Count(item.count)
            local time = Number(item.time)
            if time and time > bestTime then best, bestTime, bestName = item, time, Text(item.name or key, 96) end
        end
        reads = reads + 1; key, item = next(session.operations, key)
    end
    return best, bestTime, count, bestName
end

-- A saved row's frame name is never ownership evidence. Only offer a targeted
-- isolation step when its recorded file folder agrees with the recorded owner.
local function CallbackOwner(item)
    local owner, source = Text(item.owner, 96), Text(item.source, 1024)
    if not owner or owner ~= item.owner or not source or source ~= item.source or string.sub(source, 1, 1) ~= "@" then return nil end
    source = string.gsub(source, "\\", "/")
    local first, last = string.find(string.lower(source), "interface/addons/", 1, true)
    if not first or first ~= 2 and string.sub(source, first - 1, first - 1) ~= "/" then return nil end
    local slash = string.find(source, "/", last + 1, true)
    if not slash or string.lower(string.sub(source, last + 1, slash - 1)) ~= string.lower(owner) then return nil end
    return owner
end

function Report.Build(session, completed)
    local report = { available = false, code = "empty", status = "No completed scan", title = "Last completed scan",
        summary = "Start Profile All, then Stop to create a health report.", severity = 0,
        findings = {}, partial = false }
    if type(session) ~= "table" or not (session.stopped == true or session.stopped == nil and completed == true) then return report end
    local elapsed = Number(session.elapsed)
    if not elapsed then
        report.code, report.status, report.summary = "invalid", "Invalid scan", "This scan has no valid duration. Capture a new scan."
        return report
    end
    report.available, report.elapsed = true, elapsed
    report.date, report.scope = Text(session.capturedDate, 32), session.callbacksRequested == true and "All Addons" or Text(session.sourceName, 32) or "MOS"
    report.code, report.status, report.summary = "insufficient", "Not enough data", "Record at least five seconds of gameplay, then Stop."
    report.coverage = report.scope == "All Addons" and "Recorded frame callbacks; sampled FPS, latency and shared Lua memory."
        or "Selected Booty operations; sampled FPS, latency and shared Lua memory."
    if not rules then
        report.code, report.status, report.summary = "limited", "Limited data", "The health policy is unavailable in this profiler build."
        return report
    end
    local samples = Samples(session)
    report.partial = samples.partial
    local fpsCount, latencyCount = Count(session.fpsSamples), Count(session.latencySamples)
    local averageFPS, minimumFPS = Number(session.averageFps), Number(session.minFps)
    local averageLatency, maximumLatency = Number(session.averageLatency), Number(session.maxLatency)
    local gaps = type(session.frameGaps) == "table" and session.frameGaps or {}
    local maximumGap, frameCount = Number(gaps.maximum), Count(gaps.count)
    local sufficient = elapsed >= rules.stableSamples - 1 and fpsCount >= rules.stableSamples
        and latencyCount >= rules.stableSamples and averageFPS and averageLatency
        and samples.validHeap >= rules.stableSamples and samples.validThreshold >= rules.stableSamples
        and frameCount > 0 and maximumGap ~= nil
    if sufficient then
        report.code, report.status, report.summary, report.severity = "stable", "Stable", "FPS, latency and memory readings stayed within the health warning thresholds.", 1
    elseif elapsed >= rules.stableSamples - 1 then
        report.code, report.status, report.summary, report.severity = "limited", "Limited data", "Some required readings are missing; this scan cannot establish stable health.", 2
        report.partial = true
        Add(report, "missing", "Incomplete readings", "FPS, latency, frame intervals or Lua memory lack enough valid samples.",
            "The client did not provide enough readings to check every warning. Missing values do not mean zero cost.",
            "Open Technical details to identify the unavailable reading. Use the supported Live Monitor readings until capture support is fixed.", 2)
    end
    local captureError = Text(session.captureError, 140)
    if captureError then
        Add(report, "capture", "Capture ended with an error", captureError,
            "The profiler could not complete part of its work. This error concerns capture; it does not identify a gameplay fault.",
            "Copy the error above for the BootyProfiler maintainer. Keep Advanced Profiler stopped and use supported Live Monitor readings meanwhile.", 3)
        Outcome(report, "capture", "Capture error", "The scan ended with a recorded capture error; some results are incomplete.", 3)
        report.partial = true
    end
    if maximumGap and maximumGap >= rules.pauseSeconds then
        local slow, threshold = Count(gaps.slowCount), Number(gaps.threshold) or 0.050
        local severity = maximumGap >= rules.severePauseSeconds and 3 or 2
        Add(report, "pauses", "Frame pauses", Format(maximumGap * 1000, " ms") .. " longest pause; " .. slow .. " frames reached " .. Format(threshold * 1000, " ms") .. ".",
            "A long interval between game updates can appear as a freeze even with high average FPS. The interval alone does not identify its cause.",
            session.callbacksRequested == true and "Keep Advanced Profiler stopped during normal play; use Live Monitor instead. Inspect the callback finding, if present, to narrow down recorded addon work."
                or "Open Task Manager (Ctrl+Shift+Esc) and close unneeded apps with high CPU/GPU use. Inspect the Booty operation finding if one is listed.", severity)
        Outcome(report, "fps", "Unstable FPS", "The scan recorded frame pauses; average FPS alone does not describe its smoothness.", severity)
    end
    if samples.lowFPS or averageFPS and averageFPS < rules.lowFPS or minimumFPS and minimumFPS > 0 and minimumFPS < rules.lowFPS then
        Add(report, "low-fps", "Low sampled FPS", "Average " .. Format(averageFPS) .. " FPS; lowest recorded sample " .. Format(minimumFPS) .. " FPS.",
            "The game displayed fewer frames at these sampled moments. These readings cannot tell whether addons, rendering or other programs were responsible.",
            "Stop Advanced Profiler during gameplay. In Task Manager, check CPU/GPU use and close unnecessary heavy apps before changing game or addon settings.", 2)
        Outcome(report, "fps", "Unstable FPS", "The scan recorded low FPS; the responsible component has not been identified.", 2)
    end
    if samples.highLatency or averageLatency and averageLatency >= rules.latencyMS then
        Add(report, "latency", "Latency issue", "Average " .. Format(averageLatency, " ms") .. "; highest recorded " .. Format(maximumLatency, " ms") .. ".",
            "The recorded delay can affect how quickly server-confirmed actions respond. It is separate from FPS and does not locate the source of the delay.",
            "Pause unneeded downloads or streams. If using Wi-Fi, try Ethernet; run the Windows Network troubleshooter if connection problems continue.", 3)
        Outcome(report, "latency", "Latency issue", "The scan recorded high latency; network response and visual smoothness are separate readings.", 3)
    elseif maximumLatency and maximumLatency >= rules.latencyMS then
        Add(report, "latency-peak", "Latency spike", "The highest recorded latency was " .. Format(maximumLatency, " ms") .. ".",
            "One high reading does not prove a sustained issue. A brief delay can slow server-confirmed actions without lowering FPS.",
            "Check Task Manager's Network column and pause unneeded transfers while playing. Watch Latency in Live Monitor if delayed actions return.", 2)
        Outcome(report, "latency", "Latency spike", "The scan recorded a latency spike without enough evidence of a sustained episode.", 2)
    end

    local gc = type(session.gc) == "table" and session.gc or {}
    local retained, coincident, worst = Retained(gc.history, DROP_LIMIT), 0, 0
    for index = 1, retained do
        local drop = Entry(gc.history, index)
        if drop and Valid(drop.heapDrop) and drop.heapDrop >= rules.cleanupKB and Valid(drop.maxFrameGap) and drop.maxFrameGap >= rules.pauseSeconds then
            coincident = coincident + 1; worst = math.max(worst, drop.maxFrameGap)
        end
    end
    if Count(gc.heapDropCount) > retained then report.partial = true end
    if coincident >= rules.cleanupSamples then
        Add(report, "cleanup", "Memory drops + pauses", coincident .. " of " .. retained .. " recorded memory drops had a game-update pause of at least 100 ms between readings; longest " .. Format(worst * 1000, " ms") .. ".",
            "Lua automatically removes unused objects. Memory fell around these pauses, but the readings do not measure GC time or prove GC caused the pauses.",
            session.callbacksRequested == true and "Stop Advanced Profiler and use Live Monitor during gameplay. For a timing-only scan, set Memory: OFF to remove per-call memory checks."
                or "Keep only Live Monitor open during gameplay and close unused addon windows. Save this scan for inspection if pauses continue.", 3)
        Outcome(report, "cleanup", "Cleanup + stalls", "Memory decreases repeatedly coincided with long frames; the cause of those pauses remains unproven.", 3)
    end
    if samples.retainedGrowth then
        Add(report, "growth", "Memory stayed higher after drops", "Observed post-drop memory rose by up to " .. Format(samples.growthKB / 1024, " MB") .. "; higher post-drop levels were recorded over two minutes and four drops.",
            "Lua keeps objects that addons still reference. A rising post-drop level can also be intentional stored data; this does not confirm a memory leak.",
            "Stop Advanced Profiler and close unused addon windows. Watch memory after several drops in Live Monitor; if it keeps rising, save a longer scan for code inspection.", 2)
        Outcome(report, "growth", "Memory growing", "The scan contains sustained growth after memory drops; a leak is not confirmed.", 2)
    end
    if samples.memoryPressure then
        Add(report, "pressure", "Near the GC threshold", "Shared Lua memory reached at least 95% of its current GC threshold for three recorded samples.",
            "Lua memory stayed close to the level that triggers automatic cleanup. This is a collection trigger, not your PC's RAM limit.",
            "Use Live Monitor while raiding and keep Advanced Profiler stopped. Leave Memory: OFF for timing scans unless memory measurements are needed.", 2)
        Outcome(report, "memory", "High memory", "The scan recorded memory near its GC threshold; absolute MB alone does not establish a problem.", 2)
    end

    local callbacks = type(session.callbacks) == "table" and session.callbacks or nil
    if session.callbacksRequested and (not callbacks or callbacks.available == false) then
        report.partial = true
        Add(report, "unavailable-callbacks", "Frame callbacks were not captured", "This scan contains global readings, but no usable frame-callback capture.",
            "No event or frame-update work was captured. Required client support or a capture failure may prevent these measurements.",
            "Check callback support in Technical details. Use Live Monitor if this client cannot capture callbacks.", 1)
    end
    if callbacks then
        local failures, restores = Count(callbacks.failures), Count(callbacks.restoreFailures)
        if restores > 0 then
            Add(report, "restoration", "Callback cleanup failed", restores .. " callback restoration attempts failed.",
                "The profiler could not restore some frame scripts. Another callback scan would start from an uncertain state.",
                "Reload the UI before recording frame callbacks again.", 3)
            Outcome(report, "restoration", "Reload required", "Some profiler callbacks could not be restored; reload the UI before another callback scan.", 3)
        elseif failures > 0 then
            Add(report, "errors", "Callback errors", failures .. " intercepted callback calls threw an error.",
                "A recorded addon script failed while running. This can interrupt its work; the count alone does not say why it failed.",
                "Read the first Lua error in your error viewer. Update or temporarily disable only the addon named by that error outside combat; keep its saved settings.", 3)
            Outcome(report, "errors", "Callback errors", "Recorded scripts threw errors; the first Lua error message is needed to identify the fault.", 3)
        end
        local top, time, longest, peak = TopCallback(callbacks)
        if longest and peak >= rules.pauseSeconds or top and elapsed > 0 and time / elapsed >= 0.02 then
            local item = peak >= rules.pauseSeconds and longest or top
            local name = Text(item.name, 96) or "Recorded callback"
            local owner = CallbackOwner(item)
            Add(report, "callback", "Inspect a recorded callback", name .. ": " .. Format(Number(item.selfTime), " s own time") .. ", " .. Format(Number(item.peak) and item.peak * 1000, " ms longest call") .. ".",
                "This script accumulated noticeable recorded time or a long call. Timing includes interruptions and profiler work; its frame name does not prove its addon owner.",
                owner and "Save this report. Outside the raid, temporarily uncheck '" .. owner .. "' in the character-select AddOns list for a targeted test; keep its saved settings."
                    or "Open Frame callbacks, expand this row's family and inspect its scripts. Use the Source addon ranking for identified owners; do not disable an addon from a frame name.", 2)
        end
        local total, unknown = Number(callbacks.totalSelfTime), 0
        local addons = type(callbacks.addons) == "table" and callbacks.addons or {}
        for index = 1, math.min(table.getn(addons), 256) do
            local addon = addons[index]
            if type(addon) == "table" and addon.name == "Unknown owner" then unknown = Number(addon.selfTime) or 0 end
        end
        local unknownText = total and total > 0 and unknown > 0 and Format(math.min(100, unknown / total * 100), "% of measured script time has no identified addon.") or nil
        local unsupported, calls = Count(callbacks.heapUnsupportedCalls), Count(callbacks.totalCalls)
        if unknownText or unsupported > 0 or callbacks.truncated or callbacks.operationsTruncated or callbacks.exportOperationsTruncated or callbacks.captureOperationsTruncated then
            report.partial = true
            local evidence = unknownText or "The callback ranking has incomplete coverage."
            if session.callbackMemoryRequested and unsupported > 0 then evidence = evidence .. " " .. unsupported .. " of " .. calls .. " calls have no valid callback heap measurement." end
            Add(report, "coverage", "Partial callback coverage", evidence,
                "Some measured work has no identified addon or memory reading. Callback memory is shared-memory change during a call, not that addon's retained RAM.",
                session.callbackMemoryRequested and unsupported > 0 and "Set Memory: OFF for timing scans. For unassigned work, open Frame callbacks and expand its family; use Source addon rankings only for identified owners."
                    or "Open Frame callbacks and expand the highest-time family to locate its scripts. Keep unassigned work separate until a file source identifies its owner.", 1)
        end
    end
    if Count(gaps.invalidCount) > 0 or Count(gc.readFailures) > 0 then
        report.partial = true
        Add(report, "invalid-readings", "Some readings were rejected", Count(gaps.invalidCount) .. " invalid frame intervals; " .. Count(gc.readFailures) .. " failed Lua-memory reads.",
            "The client returned readings that could not be used. They were skipped rather than counted as zero time or memory.",
            "Open Technical details to locate the failed readings. Stop capture if failures continue and use the remaining supported Live Monitor readings.", 1)
    end
    local topMOS, timeMOS, callsMOS, nameMOS = TopMOS(session)
    if topMOS and elapsed > 0 and timeMOS / elapsed >= 0.02 then
        Add(report, "mos", "Inspect a Booty operation", (nameMOS or "Recorded operation") .. ": " .. Format(timeMOS, " s recorded time") .. ", " .. Format(Number(topMOS.maxTime) and topMOS.maxTime * 1000, " ms longest call") .. ".",
            "This selected Booty action used noticeable recorded time. Its timer can include interruptions and does not cover the whole addon.",
            "Close unused Booty pages and avoid repeated manual refreshes. Give the operation above and this exported scan to the Booty maintainer for a focused code check.", 2)
    elseif callsMOS > 0 and not topMOS then
        Add(report, "mos-clock", "Booty time below clock precision", callsMOS .. " selected Booty calls were recorded without a positive elapsed reading.",
            "The calls were counted without a positive duration. These readings cannot distinguish tiny calls from missing timing.",
            "Check Calls for frequently repeated Booty actions. Use recorded frame pauses to investigate freezes rather than ranking these calls by zero duration.", 1)
    end
    if report.partial then report.coverage = report.coverage .. " Some detailed records or addon names are missing; overall scan counters remain usable." end
    if report.status == "Stable" and table.getn(report.findings) == 0 then
        Add(report, "stable", "Stable readings", "No 100 ms pause, persistent low FPS, high latency or memory-pressure condition was observed.",
            "The scan has enough valid readings and did not trigger these health warnings. No performance change is justified by this scan alone.",
            "Keep Advanced Profiler stopped for normal play. Open Live Monitor only when you need a quick FPS, memory or latency check.", 1)
    end
    return report
end
