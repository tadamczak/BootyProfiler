-- Heuristic warnings from observed readings, not causal diagnoses or client limits.
-- One reusable scalar state; no API reads, frame creation, histories or per-frame allocations.
local P = BootyProfiler
local Health = {}
P.Health = Health
local rules = {
    stableSamples = 5, lowFPS = 30, lowFPSSamples = 3,
    latencyMS = 250, latencySamples = 3, nearThreshold = 0.95,
    memorySamples = 3, pauseSeconds = 0.1, severePauseSeconds = 0.25,
    holdSeconds = 5, cleanupKB = 1024, cleanupSeconds = 10, cleanupSamples = 3,
    growthKB = 8192, growthFraction = 0.10, growthSeconds = 120, growthCleanups = 4,
    maximumSampleGap = 5,
}
Health.thresholds = rules

local function Valid(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1e300
end

local function Result(state, code, status, severity, reason)
    state.code, state.status, state.severity, state.reason = code, status, severity, reason
    return state
end

function Health.Reset(state)
    for key in pairs(state) do state[key] = nil end
    state.samples, state.goodSamples = 0, 0
    state.lowFPSRun, state.latencyRun, state.memoryRun = 0, 0, 0
    state.cleanupCount, state.cleanupRun, state.elevatedCleanups = 0, 0, 0
    state.windowFrameCount, state.windowMaxFrameGap, state.maxFrameGap = 0, 0, 0
    state.ready, state.memoryGrowing = false, false
    return Result(state, "checking", "Checking", 0, "Waiting for five valid samples.")
end

function Health.New()
    return Health.Reset({})
end

function Health.ObserveFrame(state, elapsed)
    if not Valid(elapsed) then return false end
    state.windowFrameCount = state.windowFrameCount + 1
    if elapsed > state.windowMaxFrameGap then state.windowMaxFrameGap = elapsed end
    if elapsed > state.maxFrameGap then state.maxFrameGap = elapsed end
    return true
end

local function Drop(state, now, heap, pause)
    state.cleanupCount = state.cleanupCount + 1
    local adjacent = state.lastCleanupAt and now > state.lastCleanupAt and now - state.lastCleanupAt <= rules.cleanupSeconds
    if pause >= rules.pauseSeconds then
        if adjacent then state.cleanupRun = state.cleanupRun + 1 else state.cleanupRun = 1 end
        if state.cleanupRun >= rules.cleanupSamples then state.cleanupIssueUntil = now + rules.holdSeconds end
    else
        state.cleanupRun = 0
    end
    state.lastCleanupAt = now
    if not state.cleanupFloor or heap < state.cleanupFloor then
        state.cleanupFloor = heap
        state.elevatedSince, state.elevatedCleanups, state.memoryGrowing = nil, 0, false
    elseif heap - state.cleanupFloor >= rules.growthKB and heap >= state.cleanupFloor * (1 + rules.growthFraction) then
        if not state.elevatedSince then state.elevatedSince = now end
        state.elevatedCleanups = state.elevatedCleanups + 1
        state.memoryGrowing = state.elevatedCleanups >= rules.growthCleanups and now - state.elevatedSince >= rules.growthSeconds
    else
        state.elevatedSince, state.elevatedCleanups, state.memoryGrowing = nil, 0, false
    end
end

function Health.Sample(state, now, fps, latency, heap, threshold)
    local pause = state.windowMaxFrameGap
    state.lastFrameGap = pause
    state.windowFrameCount, state.windowMaxFrameGap = 0, 0
    state.samples = state.samples + 1
    local clockOK = Valid(now)
    local fpsOK, latencyOK, heapOK = Valid(fps) and fps > 0, Valid(latency), Valid(heap)
    local thresholdOK = Valid(threshold) and threshold > 0
    state.limitedData = not (clockOK and fpsOK and latencyOK and heapOK and thresholdOK)
    if not clockOK or state.previousAt and now <= state.previousAt then
        state.previousAt, state.previousHeap = nil, nil
        state.lowFPSRun, state.latencyRun, state.memoryRun, state.goodSamples = 0, 0, 0, 0
        state.ready, state.limitedData = false, true
        -- A missing/backwards clock cannot establish observation windows or retain timed warnings.
        state.fpsIssueUntil, state.severePauseUntil, state.latencyIssueUntil = nil, nil, nil
        state.memoryIssueUntil, state.cleanupIssueUntil = nil, nil
        state.unstableFPS, state.latencyIssue, state.highMemory, state.cleanupStalls = false, false, false, false
        state.cleanupRun, state.lastCleanupAt = 0, nil
        state.cleanupFloor, state.elevatedSince, state.elevatedCleanups, state.memoryGrowing = nil, nil, 0, false
        return Result(state, "limited", "Limited data", 2, "The clock is unavailable or did not advance; trends cannot be checked.")
    end
    if state.previousAt and now - state.previousAt > rules.maximumSampleGap then
        state.previousHeap, state.cleanupFloor = nil, nil
        state.goodSamples, state.ready = 0, false
        state.fpsIssueUntil, state.severePauseUntil, state.latencyIssueUntil = nil, nil, nil
        state.memoryIssueUntil, state.cleanupIssueUntil = nil, nil
        state.lowFPSRun, state.latencyRun, state.memoryRun = 0, 0, 0
        state.elevatedSince, state.elevatedCleanups, state.memoryGrowing = nil, 0, false
        state.cleanupRun, state.lastCleanupAt = 0, nil
    end
    if not state.limitedData then state.goodSamples = state.goodSamples + 1 else state.goodSamples = 0 end
    state.ready = state.goodSamples >= rules.stableSamples

    if fpsOK and fps < rules.lowFPS then state.lowFPSRun = state.lowFPSRun + 1 else state.lowFPSRun = 0 end
    if latencyOK and latency >= rules.latencyMS then state.latencyRun = state.latencyRun + 1 else state.latencyRun = 0 end
    if heapOK and thresholdOK and heap / threshold >= rules.nearThreshold then state.memoryRun = state.memoryRun + 1 else state.memoryRun = 0 end
    if pause >= rules.pauseSeconds or state.lowFPSRun >= rules.lowFPSSamples then state.fpsIssueUntil = now + rules.holdSeconds end
    if pause >= rules.severePauseSeconds then state.severePauseUntil = now + rules.holdSeconds end
    if state.latencyRun >= rules.latencySamples then state.latencyIssueUntil = now + rules.holdSeconds end
    if state.memoryRun >= rules.memorySamples then state.memoryIssueUntil = now + rules.holdSeconds end

    if heapOK and state.previousHeap and state.previousHeap - heap >= rules.cleanupKB then
        Drop(state, now, heap, pause)
    elseif not heapOK then
        state.cleanupFloor, state.elevatedSince, state.elevatedCleanups, state.memoryGrowing = nil, nil, 0, false
        state.cleanupRun, state.lastCleanupAt = 0, nil
    end
    state.previousAt, state.previousHeap = now, heapOK and heap or nil
    state.unstableFPS = state.fpsIssueUntil ~= nil and now < state.fpsIssueUntil
    state.latencyIssue = state.latencyIssueUntil ~= nil and now < state.latencyIssueUntil
    state.highMemory = state.memoryIssueUntil ~= nil and now < state.memoryIssueUntil
    state.cleanupStalls = state.cleanupIssueUntil ~= nil and now < state.cleanupIssueUntil
    if state.latencyIssue then
        return Result(state, "latency", "Latency issue", 3, "Latency reached 250 ms for three samples; network response is delayed.")
    elseif state.cleanupStalls then
        return Result(state, "cleanup", "Cleanup + stalls", 3, "Repeated memory drops coincide with pauses of at least 100 ms; GC time is not measured.")
    elseif state.unstableFPS then
        local severe = state.severePauseUntil ~= nil and now < state.severePauseUntil
        return Result(state, "fps", "Unstable FPS", severe and 3 or 2, "A frame paused for 100 ms, or FPS stayed below 30 for three samples.")
    elseif state.memoryGrowing then
        return Result(state, "growth", "Memory growing", 2, "Post-cleanup memory stayed 8 MB / 10% higher for two minutes; a leak is unconfirmed.")
    elseif state.highMemory then
        return Result(state, "memory", "High memory", 2, "Lua memory reached 95% of its GC threshold for three samples; cleanup may be near.")
    elseif state.limitedData then
        return Result(state, "limited", "Limited data", 2, "Some readings are unavailable; memory, FPS or latency cannot all be checked.")
    elseif not state.ready then
        return Result(state, "checking", "Checking", 0, "Waiting for five valid samples.")
    end
    return Result(state, "stable", "Stable", 1, "Recent readings show no warning; low FPS, pauses, latency and memory pressure are checked.")
end
