local P = BootyProfiler
local sources, listener = {}, nil
local state = { enabled = false, recording = false, session = nil }
local HISTORY_LIMIT, SAMPLE_LIMIT, OPERATION_LIMIT, FRAME_GAP_THRESHOLD = 64, 600, 128, 0.050
P.limits = { history = HISTORY_LIMIT, samples = SAMPLE_LIMIT, operations = OPERATION_LIMIT,
    heapDrops = HISTORY_LIMIT, frameGaps = HISTORY_LIMIT, frameGapThreshold = FRAME_GAP_THRESHOLD }

local function FiniteNonnegative(value)
    return type(value) == "number" and value == value and value >= 0 and value <= 1e300
end

local function Notify()
    if listener then
        local ok, failure = pcall(listener)
        if not ok then state.listenerError = tostring(failure); listener = nil end
    end
end

local function Now()
    if type(GetTime) ~= "function" then return nil end
    local ok, value = pcall(GetTime)
    if not ok or type(value) ~= "number" or value ~= value or value > 1e300 or value < -1e300 then return nil end
    return value
end

-- Wall-clock metadata is captured once per explicit recording. GetTime is a
-- client uptime clock and must never be presented as a calendar date.
function P.CaptureDate()
    local timestamp, formatted
    if type(time) == "function" then
        local ok, value = pcall(time)
        if ok and FiniteNonnegative(value) and value == math.floor(value) then timestamp = value end
    end
    if type(date) == "function" then
        local ok, value
        if timestamp then ok, value = pcall(date, "%Y-%m-%d %H:%M:%S", timestamp)
        else ok, value = pcall(date, "%Y-%m-%d %H:%M:%S") end
        if ok and type(value) == "string" and string.len(value) == 19
            and string.find(value, "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$") then formatted = value end
    end
    return timestamp, formatted
end

local function Push(buffer, limit)
    local index = math.mod(buffer.total, limit) + 1
    local entry = buffer[index]
    if not entry then entry = {}; table.insert(buffer, entry) end
    buffer.total = buffer.total + 1
    buffer.count = math.min(buffer.total, limit)
    return entry
end

local function Record(name, elapsed, heapChange)
    local session = state.recording and state.session
    if not session or elapsed < session.slowThreshold then return end
    local entry = Push(session.history, HISTORY_LIMIT)
    entry.name, entry.elapsed, entry.heapChange = name, elapsed, heapChange
    entry.at = math.max(0, (Now() or session.startedAt) - session.startedAt)
    entry.event = type(event) == "string" and event or nil
end

function P.GetState() return state end
function P.SetListener(callback) listener = callback end
function P.RegisterSource(name, source)
    if state.recording then return false, "Stop recording before changing the source." end
    if type(source) ~= "table" or type(source.start) ~= "function" or type(source.stop) ~= "function" then return false, "Invalid profiling source." end
    sources[name] = source
    return true
end

-- The existing recording driver supplies frame elapsed time. No API reads,
-- function wrapping, or strings are needed on the usual subthreshold frame.
function P.ObserveFrame(elapsed)
    local session = state.recording and state.session
    if not session then return 0 end
    local gaps = session.frameGaps
    if not FiniteNonnegative(elapsed) or gaps.elapsed + elapsed > 1e300 then
        gaps.invalidCount = gaps.invalidCount + 1
        gaps.windowInvalidFrames = gaps.windowInvalidFrames + 1
        session.gcWindowInvalidFrames = session.gcWindowInvalidFrames + 1
        return 0
    end
    if session.health and P.Health then P.Health.ObserveFrame(session.health, elapsed) end
    gaps.count, gaps.elapsed, gaps.latest = gaps.count + 1, gaps.elapsed + elapsed, elapsed
    if elapsed > gaps.maximum then gaps.maximum = elapsed end
    if elapsed > gaps.windowMax then gaps.windowMax = elapsed end
    if elapsed > session.gcWindowMaxFrameGap then session.gcWindowMaxFrameGap = elapsed end
    if elapsed >= FRAME_GAP_THRESHOLD then
        gaps.slowCount, gaps.windowSlowFrames = gaps.slowCount + 1, gaps.windowSlowFrames + 1
        session.gcWindowSlowFrames = session.gcWindowSlowFrames + 1
        local entry = Push(gaps.history, HISTORY_LIMIT)
        entry.at, entry.elapsed = gaps.elapsed, elapsed
        -- Only retained slow gaps need the same wall-clock axis as heap
        -- samples. Keep the original accumulated-elapsed timestamp too.
        entry.sampleAt = nil
        local now = Now()
        local sampleAt = now and now - session.startedAt
        if state.recording and state.session == session and FiniteNonnegative(sampleAt) then entry.sampleAt = sampleAt end
    end
    return elapsed
end

local function ReadHeap()
    if type(gcinfo) ~= "function" then return nil, nil, false end
    local ok, heap, threshold = pcall(gcinfo)
    if not ok or not FiniteNonnegative(heap) then return nil, nil, false end
    if not FiniteNonnegative(threshold) then threshold = nil end
    return heap, threshold, true
end

local function SampleHeap(session, entry)
    local heap, threshold, valid = ReadHeap()
    local gc = session.gc
    if not valid then gc.readFailures = gc.readFailures + 1; return end
    entry.heap, entry.gcThreshold, session.heap, session.gcThreshold = heap, threshold, heap, threshold
    if not session.startHeap then session.startHeap = heap end
    local previousHeap, previousAt = session.gcPreviousHeap, session.gcPreviousAt
    if previousHeap then
        entry.heapDelta = heap - previousHeap
        if heap < previousHeap then
            local amount = previousHeap - heap
            gc.heapDropCount, gc.heapDropTotal = gc.heapDropCount + 1, gc.heapDropTotal + amount
            gc.lastHeapDrop, gc.lastHeapDropAt = amount, entry.at
            gc.lastHeapDropWindowStart, gc.lastHeapDropWindowEnd = previousAt, entry.at
            gc.lastHeapDropWindowDuration = math.max(0, entry.at - previousAt)
            gc.lastHeapDropMaxFrameGap, gc.lastHeapDropSlowFrames = session.gcWindowMaxFrameGap, session.gcWindowSlowFrames
            gc.lastHeapDropInvalidFrames = session.gcWindowInvalidFrames
            local drop = Push(gc.history, HISTORY_LIMIT)
            drop.at, drop.heapDrop, drop.beforeHeap, drop.afterHeap = entry.at, amount, previousHeap, heap
            drop.windowStart, drop.windowEnd, drop.windowDuration = previousAt, entry.at, gc.lastHeapDropWindowDuration
            drop.maxFrameGap, drop.slowFrames, drop.invalidFrames = session.gcWindowMaxFrameGap, session.gcWindowSlowFrames, session.gcWindowInvalidFrames
        end
    end
    session.gcPreviousHeap, session.gcPreviousAt = heap, entry.at
    session.gcWindowMaxFrameGap, session.gcWindowSlowFrames, session.gcWindowInvalidFrames = 0, 0, 0
end

function P.Sample()
    local session = state.recording and state.session
    if not session then return end
    local now = Now()
    if not now then
        if session.health and P.Health then P.Health.Sample(session.health, nil, nil, nil, nil, nil) end
        state.error = "Client clock is unavailable."; P.Stop(); return
    end
    session.elapsed = math.max(0, now - session.startedAt)
    local entry = Push(session.samples, SAMPLE_LIMIT)
    -- A reused slot must never retain an old API reading or a previous drop.
    entry.heap, entry.gcThreshold, entry.heapDelta, entry.fps, entry.latency = nil, nil, nil, nil, nil
    entry.at = session.elapsed
    local gaps = session.frameGaps
    entry.windowStart, entry.windowMaxFrameGap = gaps.windowStart, gaps.windowMax
    entry.windowSlowFrames, entry.windowInvalidFrames = gaps.windowSlowFrames, gaps.windowInvalidFrames
    gaps.lastWindowMax, gaps.lastWindowSlowFrames, gaps.lastWindowInvalidFrames = gaps.windowMax, gaps.windowSlowFrames, gaps.windowInvalidFrames
    gaps.windowStart, gaps.windowMax, gaps.windowSlowFrames, gaps.windowInvalidFrames = entry.at, 0, 0, 0
    SampleHeap(session, entry)
    if type(GetFramerate) == "function" then
        local fps = tonumber(GetFramerate())
        if FiniteNonnegative(fps) and fps > 0 then
            entry.fps = fps; session.fps = fps
            if not session.minFps or fps < session.minFps then session.minFps = fps end
            if not session.maxFps or fps > session.maxFps then session.maxFps = fps end
            session.fpsSamples = session.fpsSamples + 1
            session.averageFps = session.averageFps and session.averageFps + (fps - session.averageFps) / session.fpsSamples or fps
        else entry.fps = nil end
    end
    if type(GetNetStats) == "function" then
        local _, _, latency = GetNetStats()
        latency = tonumber(latency)
        if FiniteNonnegative(latency) then
            entry.latency, session.latency = latency, latency
            if not session.minLatency or latency < session.minLatency then session.minLatency = latency end
            if not session.maxLatency or latency > session.maxLatency then session.maxLatency = latency end
            session.latencySamples = session.latencySamples + 1
            session.averageLatency = session.averageLatency and session.averageLatency + (latency - session.averageLatency) / session.latencySamples or latency
        end
    end
    if session.health and P.Health then
        P.Health.Sample(session.health, entry.at, entry.fps, entry.latency, entry.heap, entry.gcThreshold)
    end
    Notify()
end

function P.Start(options)
    if not state.enabled then return false, "Enable BootyProfiler first." end
    if state.recording then return false, "A recording is already running." end
    local callbacksRequested = type(options) == "table" and options.callbacks and true or false
    local sourceName
    if type(options) == "table" then sourceName = options.source end
    if sourceName == nil then sourceName = sources.Booty and "Booty" or "MOS" end
    local source, now = sourceName and sources[sourceName] or nil, Now()
    if not source and (sourceName ~= false or not callbacksRequested) then return false, tostring(sourceName or "Selected") .. " profiling source is unavailable." end
    if not now then return false, "Client clock is unavailable." end
    local handle
    if source then
        local ok, value, failure = pcall(source.start, Record)
        if not ok or not value then state.error = tostring(ok and failure or value); Notify(); return false, state.error end
        handle = value
        if type(handle) ~= "table" or type(handle.operations) ~= "table" then
            pcall(source.stop, handle)
            state.error = "Profiling source returned an invalid handle."; Notify(); return false, state.error
        end
    end
    local callbackMemoryRequested = callbacksRequested and options.memory and true or false
    local capturedAt, capturedDate = P.CaptureDate()
    -- Session summaries retain only running means/counts and extrema. The
    -- bounded sample ring may wrap without changing the summary's time span.
    local session = { startedAt = now, capturedAt = capturedAt, capturedDate = capturedDate,
        elapsed = 0, fpsSamples = 0, latencySamples = 0,
        history = { count = 0, total = 0 }, samples = { count = 0, total = 0 },
        gc = { heapDropCount = 0, heapDropTotal = 0, readFailures = 0, history = { count = 0, total = 0 } },
        frameGaps = { count = 0, slowCount = 0, invalidCount = 0, maximum = 0, elapsed = 0, threshold = FRAME_GAP_THRESHOLD,
            windowStart = 0, windowMax = 0, windowSlowFrames = 0, windowInvalidFrames = 0, history = { count = 0, total = 0 } },
        gcWindowMaxFrameGap = 0, gcWindowSlowFrames = 0, gcWindowInvalidFrames = 0,
        slowThreshold = 0.005, source = source, sourceName = sourceName, handle = handle, operations = handle and handle.operations or {},
        clock = "GetTime", clockResolution = "not verified in this client", coverage = source and "Selected " .. tostring(sourceName) .. " entry points; nested calls counted once." or "No selected-operation source; intercepted frame callbacks only.",
        callbacksRequested = callbacksRequested,
        callbackMemoryRequested = callbackMemoryRequested,
        allAddonsCoverage = callbacksRequested and "Intercepted frame OnEvent/OnUpdate callbacks, global Lua heap and sampled FPS/latency. This is not total addon CPU or causal FPS attribution."
            or "Global Lua heap and sampled FPS/latency. Start from All Addons to also intercept frame callbacks." }
    state.session, state.recording, state.error, state.listenerError = session, true, nil, nil
    if P.Health then session.health = P.Health.New() end
    if source and source.capabilities then
        local captured, capabilities = pcall(source.capabilities)
        if not captured then P.Fail(capabilities); return false, state.error end
        session.capabilities = capabilities
    end
    local sampled, sampleError = pcall(P.Sample)
    if not sampled then P.Fail(sampleError); return false, state.error end
    if not state.recording then return false, state.error end
    if callbacksRequested and P.Callbacks then
        local activated, callbackError = pcall(P.Callbacks.Start, session)
        if not activated then P.Fail(callbackError); return false, state.error end
    elseif callbacksRequested then
        session.allAddonsCoverage = "Frame callback profiling is unavailable in this BootyProfiler version. Global Lua heap and sampled FPS/latency only."
    end
    local running, runtimeError = pcall(P.Runtime.SetRunning, true)
    if not running then P.Fail(runtimeError); return false, state.error end
    Notify()
    return true
end

function P.Stop()
    if not state.recording then return false end
    local session = state.session
    -- One cleanup failure must not prevent the other measurement sources from
    -- releasing their wrappers/scopes. Freeze the capture before teardown.
    state.recording = false
    local runtimeStopped, runtimeError = pcall(P.Runtime.SetRunning, false)
    local callbacksStopped, callbackError = true, nil
    if session.callbacksRequested and P.Callbacks then
        callbacksStopped, callbackError = pcall(P.Callbacks.Stop, session)
        if callbacksStopped and callbackError == false then
            callbacksStopped, callbackError = false, "Some callback wrappers could not be restored; retained wrappers are disabled."
        end
    end
    local ok, failure = true, nil
    if session.source then ok, failure = pcall(session.source.stop, session.handle) end
    session.elapsed = math.max(session.elapsed, (Now() or session.startedAt) - session.startedAt)
    local heap, threshold, valid = ReadHeap()
    if valid then session.heap, session.gcThreshold = heap, threshold end
    session.gcPreviousHeap, session.gcPreviousAt = nil, nil
    session.gcWindowMaxFrameGap, session.gcWindowSlowFrames, session.gcWindowInvalidFrames = nil, nil, nil
    session.stopped = true
    if session.health then session.health.stopped = true end
    if not ok then state.error = tostring(failure) end
    if not callbacksStopped then state.error = tostring(callbackError) end
    if not runtimeStopped then state.error = tostring(runtimeError) end
    session.captureError = session.captureError or state.error
    if P.HealthReport then
        local built, report = pcall(P.HealthReport.Build, session)
        if built and type(report)=="table" then
            state.lastHealthReport, state.healthReportChecked, state.healthReportError = report, true, nil
        elseif not built then state.healthReportError=tostring(report) end
    end
    Notify()
    return ok and callbacksStopped and runtimeStopped
end

function P.Fail(message)
    if state.session then state.session.captureError=tostring(message) end
    P.Stop(); state.error = tostring(message); Notify()
end

function P.GetLastHealthReport()
    if state.lastHealthReport or state.healthReportChecked then return state.lastHealthReport end
    if not P.HealthReport then return nil end
    state.healthReportChecked=true
    local saved=type(BootyProfilerDB)=="table" and BootyProfilerDB.schema==1 and BootyProfilerDB.lastSession
    if type(saved)=="table" and saved.schema==1 then
        -- lastSession is written only by explicit stopped Export. Accept old
        -- exports without a stopped marker; never retain their frame metrics.
        local built, report=pcall(P.HealthReport.Build,saved,true)
        if built and type(report)=="table" then state.lastHealthReport=report
        elseif not built then state.healthReportError=tostring(report) end
    end
    return state.lastHealthReport
end

function P.Enable(enabled)
    if not enabled then P.Stop() end
    state.enabled = enabled and true or false
    Notify()
end

function P.Reset()
    local restart = state.recording
    local callbacks = state.session and state.session.callbacksRequested
    local memory = state.session and state.session.callbackMemoryRequested
    local source = state.session and state.session.sourceName
    P.Stop(); state.session, state.error = nil, nil
    state.lastHealthReport, state.healthReportError, state.healthReportChecked=nil,nil,true
    if restart then return P.Start({ callbacks = callbacks, memory = memory, source = source }) end
    Notify(); return true
end

function P.HistoryEntry(buffer, index)
    if not buffer or index < 1 or index > buffer.count then return nil end
    local oldest = buffer.total > buffer.count and math.mod(buffer.total, buffer.count) + 1 or 1
    return buffer[math.mod(oldest + index - 2, buffer.count) + 1]
end

local function CopyFields(value)
    local result, key, field = {}, nil, nil
    for key, field in pairs(value) do if type(field) ~= "table" and type(field) ~= "function" and type(field) ~= "userdata" then result[key] = field end end
    return result
end
local function CompareTime(left, right) return left.time > right.time end
local function CompareMemory(left,right) return left.memory > right.memory end
local function CompareSelfTime(left,right) return left.selfTime > right.selfTime end
local function CompareHeapRise(left,right)
    if (left.heapRise or 0)==(right.heapRise or 0) then return left.name<right.name end
    return (left.heapRise or 0)>(right.heapRise or 0)
end

function P.HasNativeAddonMemory()
    return type(UpdateAddOnMemoryUsage)=="function" and type(GetAddOnMemoryUsage)=="function"
        and type(GetNumAddOns)=="function" and type(GetAddOnInfo)=="function"
end
function P.ReadAddonMemory()
    if not state.enabled then return false,"Enable BootyProfiler first." end
    if not P.HasNativeAddonMemory() then return false,"Native addon memory statistics are unavailable in this client." end
    local ok,failure=pcall(UpdateAddOnMemoryUsage)
    if not ok then return false,tostring(failure) end
    local counted,number=pcall(GetNumAddOns)
    if not counted or not FiniteNonnegative(number) then return false,"Addon inventory is unavailable." end
    local entries=state.addonEntries
    if not entries then entries={};state.addonEntries=entries end
    local count=0
    for index=1,math.min(256,math.max(0,math.floor(number))) do
        local measured,amount=pcall(GetAddOnMemoryUsage,index)
        local named,name,title=pcall(GetAddOnInfo,index)
        if measured and named and FiniteNonnegative(amount) then
            count=count+1
            local entry=entries[count]
            if not entry then entry={};table.insert(entries,entry) end
            entry.name,entry.owner,entry.memory=title or name or ("Addon "..index),name,amount
        end
    end
    for index=table.getn(entries),count+1,-1 do table.remove(entries,index) end
    table.sort(entries,CompareMemory);state.addonMemoryTruncated=number>256
    return true
end

function P.Export()
    if state.recording then return nil, "Stop recording before exporting." end
    local session = state.session
    if not session then return nil, "No recording to export." end
    local result = { schema = 1, profilerVersion = P.version, elapsed = session.elapsed, clock = session.clock, stopped=true,
        sourceName = session.sourceName,
        captureError=session.captureError,
        capturedAt = session.capturedAt, capturedDate = session.capturedDate,
        clockResolution = session.clockResolution, coverage = session.coverage, allAddonsCoverage = session.allAddonsCoverage,
        callbacksRequested = session.callbacksRequested,
        callbackMemoryRequested = session.callbackMemoryRequested,
        startHeap = session.startHeap, endHeap = session.heap, minFps = session.minFps, maxFps = session.maxFps,
        fpsSamples = session.fpsSamples, averageFps = session.averageFps,
        latencySamples = session.latencySamples, minLatency = session.minLatency, maxLatency = session.maxLatency,
        averageLatency = session.averageLatency,
        gcThreshold = session.gcThreshold,
        slowThreshold = session.slowThreshold, history = {}, samples = {}, operations = {} }
    local name, operation, index
    if session.health then
        -- Persist the diagnostic result, not the policy's rolling counters.
        result.health = { code = session.health.code, status = session.health.status,
            reason = session.health.reason, severity = session.health.severity, ready = session.health.ready }
    end
    for name, operation in pairs(session.operations) do
        if table.getn(result.operations) < OPERATION_LIMIT then local copy = CopyFields(operation); copy.name = name; table.insert(result.operations, copy)
        else result.operationsTruncated = true end
    end
    table.sort(result.operations, CompareTime)
    for index = 1, session.history.count do table.insert(result.history, CopyFields(P.HistoryEntry(session.history, index))) end
    for index = 1, session.samples.count do table.insert(result.samples, CopyFields(P.HistoryEntry(session.samples, index))) end
    if session.gc then
        result.gc = CopyFields(session.gc); result.gc.history = {}
        for index = 1, session.gc.history.count do table.insert(result.gc.history, CopyFields(P.HistoryEntry(session.gc.history, index))) end
    end
    if session.frameGaps then
        result.frameGaps = CopyFields(session.frameGaps); result.frameGaps.history = {}
        for index = 1, session.frameGaps.history.count do table.insert(result.frameGaps.history, CopyFields(P.HistoryEntry(session.frameGaps.history, index))) end
    end
    if session.capabilities then result.capabilities = CopyFields(session.capabilities) end
    if session.callbacks then
        local callbacks = session.callbacks
        result.callbacks = CopyFields(callbacks)
        result.callbacks.addons, result.callbacks.operations, result.callbacks.history = {}, {}, {}
        result.callbacks.sourceExamples = {}
        for index = 1, math.min(8, table.getn(callbacks.sourceExamples or {})) do
            table.insert(result.callbacks.sourceExamples, CopyFields(callbacks.sourceExamples[index]))
        end
        for index = 1, math.min(256, table.getn(callbacks.addons or {})) do
            table.insert(result.callbacks.addons, CopyFields(callbacks.addons[index]))
        end
        local callbackOrder=session.callbackMemoryRequested and CompareHeapRise or CompareSelfTime
        table.sort(result.callbacks.addons, callbackOrder)
        -- Export is explicit and stopped. Select the actual highest-cost
        -- callbacks across the bounded capture, rather than its first entries.
        local ordered = {}
        for index = 1, table.getn(callbacks.operations or {}) do table.insert(ordered, callbacks.operations[index]) end
        table.sort(ordered, callbackOrder)
        for index = 1, math.min(OPERATION_LIMIT, table.getn(ordered)) do
            table.insert(result.callbacks.operations, CopyFields(ordered[index]))
        end
        result.callbacks.captureOperationsTruncated = callbacks.operationsTruncated == true
        result.callbacks.exportOperationsTruncated = table.getn(ordered) > OPERATION_LIMIT
        result.callbacks.operationsTruncated = result.callbacks.captureOperationsTruncated or result.callbacks.exportOperationsTruncated
        local history = callbacks.history
        if history then
            result.callbacks.slowCalls = history.total
            result.callbacks.slowCallsRetained = history.count
            for index = 1, history.count do table.insert(result.callbacks.history, CopyFields(P.HistoryEntry(history,index))) end
        end
    end
    if state.addonEntries then
        result.addonMemory={}
        for index=1,table.getn(state.addonEntries) do table.insert(result.addonMemory,CopyFields(state.addonEntries[index])) end
        result.addonMemoryTruncated=state.addonMemoryTruncated
    end
    if type(BootyProfilerDB)~="table" then BootyProfilerDB={} end
    BootyProfilerDB.schema, BootyProfilerDB.lastSession = 1, result
    return result
end
