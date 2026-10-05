-- A visible-only snapshot, independent of advanced recordings and saved reports.
local P = BootyProfiler
local Monitor = {}
P.LiveMonitor = Monitor
local state = { visible = false, samples = 0 }
local health = P.Health and P.Health.New() or nil
state.health = health
local driver, listener, previousHeap, previousAt = nil, nil, nil, nil
local elapsed, generation = 0, 0

local function Finite(value)
    return type(value) == "number" and value == value and value >= -1e300 and value <= 1e300
end

local function Nonnegative(value)
    return Finite(value) and value >= 0
end

local function Current(token)
    return state.visible and generation == token
end

local function Notify(token)
    if not Current(token) or not listener then return end
    local callback = listener
    local ok = pcall(callback)
    -- A listener may close/reopen the monitor or replace itself while running.
    if not ok and Current(token) and listener == callback then
        state.listenerFailures = state.listenerFailures + 1
        listener = nil
    end
end

local function Sample(token)
    if not Current(token) then return end
    local now, heap, threshold, fps, latency = nil, nil, nil, nil, nil
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if not Current(token) then return end
        if ok and Nonnegative(value) then now = value end
    end
    if type(gcinfo) == "function" then
        local ok, value, limit = pcall(gcinfo)
        if not Current(token) then return end
        if ok and Nonnegative(value) then heap = value end
        if ok and Nonnegative(limit) then threshold = limit end
    end
    if type(GetFramerate) == "function" then
        local ok, value = pcall(GetFramerate)
        if not Current(token) then return end
        if ok and Nonnegative(value) and value > 0 then fps = value end
    end
    if type(GetNetStats) == "function" then
        local ok, incoming, outgoing, value = pcall(GetNetStats)
        if not Current(token) then return end
        if ok and Nonnegative(value) then latency = value end
    end
    if not Current(token) then return end
    state.samples = state.samples + 1
    state.at, state.fps, state.heap, state.gcThreshold, state.latency = now, fps, heap, threshold, latency
    state.clockAvailable, state.heapAvailable, state.fpsAvailable = now ~= nil, heap ~= nil, fps ~= nil
    state.thresholdAvailable = threshold ~= nil
    state.latencyAvailable = latency ~= nil
    if not now then state.clockFailures = state.clockFailures + 1 end
    if not heap then state.heapFailures = state.heapFailures + 1 end
    if not fps then state.fpsFailures = state.fpsFailures + 1 end
    if not latency then state.latencyFailures = state.latencyFailures + 1 end
    if heap and (not state.maxHeap or heap > state.maxHeap) then state.maxHeap = heap end
    if threshold and (not state.maxGcThreshold or threshold > state.maxGcThreshold) then state.maxGcThreshold = threshold end

    -- Invalid/unchanged/backwards clocks break the pair. A later good reading
    -- must establish a fresh baseline instead of attributing an unobserved gap.
    state.rate, state.lastCleanupAge = nil, nil
    if now and state.lastCleanupAt and now >= state.lastCleanupAt then
        state.lastCleanupAge = now - state.lastCleanupAt
    end
    if now and heap then
        if previousAt and previousHeap and now > previousAt then
            local difference, interval = heap - previousHeap, now - previousAt
            local rate = difference / interval
            if Finite(rate) then state.rate = rate end
            if difference < 0 then
                state.lastCleanup, state.lastCleanupAt, state.lastCleanupAge = -difference, now, 0
            end
        end
        previousHeap, previousAt = heap, now
    else
        previousHeap, previousAt = nil, nil
    end
    if health then P.Health.Sample(health, now, fps, latency, heap, threshold) end
    Notify(token)
end

local function Tick()
    if not state.visible then return end
    local delta = tonumber(arg1)
    if not Nonnegative(delta) or elapsed + delta > 1e300 then return end
    if health then P.Health.ObserveFrame(health, delta) end
    elapsed = elapsed + delta
    if elapsed >= 1 then
        elapsed = 0
        -- One snapshot after a delayed frame; there is no catch-up batch.
        Sample(generation)
    end
end

local function Hidden()
    Monitor.SetVisible(false)
end

function Monitor.GetState() return state end
function Monitor.IsOwnFrame(frame) return driver ~= nil and frame == driver end
function Monitor.SetListener(callback)
    if callback ~= nil and type(callback) ~= "function" then return false end
    listener = callback
    return true
end

function Monitor.SetVisible(visible)
    if type(visible) ~= "boolean" then return false, "Invalid monitor visibility." end
    if not visible then
        generation = generation + 1
        state.visible, listener, elapsed = false, nil, 0
        previousHeap, previousAt = nil, nil
        if driver then
            driver:SetScript("OnUpdate", nil)
            driver:SetScript("OnHide", nil)
            driver:Hide()
        end
        return true
    end
    if state.visible then return true end
    generation = generation + 1
    local token = generation
    state.visible, state.samples, elapsed = true, 0, 0
    state.at, state.fps, state.heap, state.gcThreshold, state.latency = nil, nil, nil, nil, nil
    state.maxHeap, state.maxGcThreshold, state.rate = nil, nil, nil
    state.lastCleanup, state.lastCleanupAt, state.lastCleanupAge = nil, nil, nil
    state.clockAvailable, state.heapAvailable, state.fpsAvailable, state.thresholdAvailable = false, false, false, false
    state.clockFailures, state.heapFailures, state.fpsFailures, state.listenerFailures = 0, 0, 0, 0
    state.latencyAvailable, state.latencyFailures = false, 0
    if health then P.Health.Reset(health) end
    previousHeap, previousAt = nil, nil
    if not driver then
        if type(CreateFrame) ~= "function" then
            Monitor.SetVisible(false)
            return false, "Client frames are unavailable."
        end
        local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
        if not ok or not frame then
            Monitor.SetVisible(false)
            return false, "Live monitor frame could not be created."
        end
        driver = frame
        if not Current(token) then driver:Hide(); return false end
    end
    -- Attach only after API reads/listener dispatch: closing from either must
    -- never be followed by a stale SetScript that turns the sampler back on.
    Sample(token)
    if not Current(token) then return false end
    driver:SetScript("OnHide", Hidden)
    driver:SetScript("OnUpdate", Tick)
    driver:Show()
    return Current(token)
end
