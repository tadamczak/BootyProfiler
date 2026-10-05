-- One-shot shared-heap windows after this addon's SavedVariables are loaded.
-- These deltas do not establish memory owned by an individual addon.
local P = BootyProfiler
local L = {}
P.LoginMemory = L
local RECORD_LIMIT, SETTLE_SECONDS, SAMPLE_SECONDS, INVENTORY_LIMIT = 256, 10, 1, 256
L.limits = { records = RECORD_LIMIT, settleSeconds = SETTLE_SECONDS, sampleSeconds = SAMPLE_SECONDS, inventory = INVENTORY_LIMIT }
local driver, loaded, active, status = nil, false, nil, "waiting"
local clock, heapReader, previousAt, previousHeap, deadline, sampleWait
local listener

local function Finite(value)
    return type(value) == "number" and value == value and value >= 0 and value < 1e300
end
local function Text(value, limit)
    return type(value) == "string" and value ~= "" and string.sub(value, 1, limit or 128) or nil
end
local function Database()
    if type(BootyProfilerDB) ~= "table" then BootyProfilerDB = { schema = 1 } end
    if BootyProfilerDB.schema == nil then BootyProfilerDB.schema = 1 end
    return BootyProfilerDB
end
local function Notify()
    if listener then
        local ok = pcall(listener)
        if not ok then listener = nil end
    end
end
local function StopHandlers()
    if driver then
        driver:SetScript("OnUpdate", nil); driver:SetScript("OnEvent", nil); driver:SetScript("OnHide", nil)
        driver:UnregisterAllEvents(); driver:Hide()
    end
    clock, heapReader, previousAt, previousHeap, deadline, sampleWait = nil, nil, nil, nil, nil, nil
end
local function CopyFields(source)
    local copy = {}
    for key, value in pairs(source) do
        local kind = type(value)
        if type(key) == "string" and (kind == "string" or kind == "boolean" or kind == "number" and value == value and math.abs(value) < 1e300) then copy[key] = value end
    end
    return copy
end
local function Finish(kind, reason)
    local report = active
    active = nil; StopHandlers(); status = kind
    if not report then return end
    report.kind, report.reason = kind, reason
    local copy = CopyFields(report)
    copy.events = {}
    for index = 1, math.min(RECORD_LIMIT, table.getn(report.events)) do table.insert(copy.events, CopyFields(report.events[index])) end
    Database().lastLoginMemory = copy
    Notify()
end
local function Read(report)
    if active ~= report then return nil end
    local ok, at = pcall(clock)
    -- Client extensions may call addon code while supplying a reading.
    if active ~= report then return nil end
    if not ok or not Finite(at) or previousAt and at < previousAt then
        report.clockFailures = report.clockFailures + 1
        Finish("failed", "clock-unavailable-or-invalid"); return nil
    end
    local read, heap, threshold = pcall(heapReader)
    if active ~= report then return nil end
    if not read or not Finite(heap) then
        report.heapFailures = report.heapFailures + 1
        Finish("failed", "heap-unavailable-or-invalid"); return nil
    end
    return at, heap, Finite(threshold) and threshold or nil
end
local function Sample(eventName, addon)
    local report = active
    if not report then return nil end
    local at, heap, threshold = Read(report)
    if not at or active ~= report then return nil end
    local delta = previousHeap and heap - previousHeap or 0
    local window = previousAt and at - previousAt or 0
    if not report.startHeap then report.startHeap, report.startedAt = heap, at end
    report.heap, report.heapDelta, report.gcThreshold = heap, heap - report.startHeap, threshold
    report.elapsed = at - report.startedAt
    if report.firstWorldAt~=nil then report.settleRemaining=math.max(0,SETTLE_SECONDS-(report.elapsed-report.firstWorldAt)) end
    report.lastEvent, report.lastAddon = eventName, addon
    if delta < 0 then
        report.heapDropCount = report.heapDropCount + 1
        report.observedHeapDrop = report.observedHeapDrop - delta
    end
    if table.getn(report.events) < RECORD_LIMIT then
        table.insert(report.events, { event = eventName, addon = addon, at = report.elapsed,
            heap = heap, delta = delta, windowElapsed = window, gcThreshold = threshold })
    else report.truncated = true; report.omittedRecords = report.omittedRecords + 1 end
    previousAt, previousHeap = at, heap
    return at
end
local function Tick()
    if not active then StopHandlers(); return end
    local report = active
    local elapsed = arg1
    if not Finite(elapsed) then Finish("failed", "invalid-frame-elapsed"); return end
    sampleWait = sampleWait + elapsed
    if sampleWait < SAMPLE_SECONDS then return end
    -- At most one sample per rendered frame; stalled frames never cause catch-up.
    sampleWait = 0
    local at = Sample("SETTLE_SAMPLE")
    if at and active == report and at >= deadline then Finish("completed", "first-world-settled") end
end
local function Hidden()
    if active then Finish("partial", "capture-driver-hidden") end
end
local function BaselineCoverage(report)
    local countReader = type(GetNumAddOns) == "function" and GetNumAddOns or nil
    local infoReader = type(GetAddOnInfo) == "function" and GetAddOnInfo or nil
    local loadedReader = type(IsAddOnLoaded) == "function" and IsAddOnLoaded or nil
    if not loadedReader and type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function" then loadedReader = C_AddOns.IsAddOnLoaded end
    report.baselineInventoryAvailable, report.baselineInventoryComplete = false, false
    report.baselineInventoryInspected, report.baselineInventoryFailures, report.baselineInventoryTruncated = 0, 0, false
    if not countReader or not infoReader or not loadedReader then
        report.baselineInventoryReason = not loadedReader and "loaded-state-api-unavailable" or "addon-inventory-api-unavailable"
        return active == report
    end
    local ok, count = pcall(countReader)
    if active ~= report then return false end
    if not ok or not Finite(count) or count ~= math.floor(count) then
        report.baselineInventoryFailures = 1; report.baselineInventoryReason = "addon-count-unavailable-or-invalid"
        return true
    end
    report.baselineInventoryAvailable, report.baselineInventoryCount, report.baselineLoadedAddonCount = true, count, 0
    report.baselineInventoryTruncated = count > INVENTORY_LIMIT
    -- One bounded query at the armed startup event; no names or API readers retained.
    for index = 1, math.min(INVENTORY_LIMIT, count) do
        local read, name = pcall(infoReader, index)
        if active ~= report then return false end
        if not read or type(name) ~= "string" or name == "" then report.baselineInventoryFailures = report.baselineInventoryFailures + 1
        elseif name ~= "BootyProfiler" then
            local checked, isLoaded = pcall(loadedReader, name)
            if active ~= report then return false end
            if not checked or isLoaded ~= nil and isLoaded ~= true and isLoaded ~= false and isLoaded ~= 0 and isLoaded ~= 1 then
                report.baselineInventoryFailures = report.baselineInventoryFailures + 1
            else
                report.baselineInventoryInspected = report.baselineInventoryInspected + 1
                if isLoaded == true or isLoaded == 1 then report.baselineLoadedAddonCount = report.baselineLoadedAddonCount + 1 end
            end
        end
    end
    report.baselineInventoryComplete = not report.baselineInventoryTruncated and report.baselineInventoryFailures == 0
    return true
end
local function Start()
    clock, heapReader = type(GetTime) == "function" and GetTime or nil, type(gcinfo) == "function" and gcinfo or nil
    active = { schema = 1, profilerVersion = Text(P.version, 64), kind = "recording",
        coveragePartial = true, coverageStartsAt = "BootyProfiler ADDON_LOADED",
        events = {}, addonEvents = 0, omittedRecords = 0, heapDropCount = 0, observedHeapDrop = 0,
        clockFailures = 0, heapFailures = 0, elapsed = 0, settleSeconds = SETTLE_SECONDS }
    status = "recording"
    local report = active
    if not clock or not heapReader then Finish("failed", "clock-or-heap-api-unavailable"); return end
    -- Capture formatting allocations belong to the startup baseline. Nothing
    -- reads the wall clock during later addon windows or the settle sampler.
    if type(P.CaptureDate) == "function" then report.capturedAt, report.capturedDate = P.CaptureDate() end
    if active ~= report then return end
    -- Include this query's own allocations in the baseline, not a later addon window.
    if not BaselineCoverage(report) or active ~= report then return end
    if not Sample("BASELINE", "BootyProfiler") or active ~= report then return end
    driver:RegisterEvent("ADDON_LOADED"); driver:RegisterEvent("VARIABLES_LOADED")
    driver:RegisterEvent("PLAYER_LOGIN"); driver:RegisterEvent("PLAYER_ENTERING_WORLD"); driver:RegisterEvent("PLAYER_LOGOUT")
end
local function OnEvent()
    if not loaded then
        if event ~= "ADDON_LOADED" or arg1 ~= "BootyProfiler" then return end
        loaded = true
        local db = Database()
        local armed = db.captureNextLogin == true
        db.captureNextLogin = false
        if armed then Start() else status = "off"; StopHandlers() end
        return
    end
    local report = active
    if not report then return end
    if event == "ADDON_LOADED" then
        local name = Text(arg1)
        if not name or name == "BootyProfiler" then return end
        report.addonEvents = report.addonEvents + 1
        Sample(event, name)
    elseif event == "VARIABLES_LOADED" then
        if report.variablesLoadedAt ~= nil then return end
        if Sample(event) and active == report then report.variablesLoadedAt = report.elapsed end
    elseif event == "PLAYER_LOGIN" then
        if report.playerLoginAt ~= nil then return end
        if Sample(event) and active == report then report.playerLoginAt = report.elapsed end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if report.firstWorldAt ~= nil then return end
        local at = Sample(event)
        if not at or active ~= report then return end
        report.firstWorldAt = report.elapsed
        report.settleRemaining = SETTLE_SECONDS
        deadline, sampleWait = at + SETTLE_SECONDS, 0
        driver:UnregisterEvent("PLAYER_ENTERING_WORLD")
        driver:SetScript("OnHide", Hidden); driver:SetScript("OnUpdate", Tick); driver:Show()
    elseif event == "PLAYER_LOGOUT" then
        if Sample(event) and active == report then Finish("partial", "logout-before-settle") end
    end
end

function L.Arm(value)
    if not loaded then return false, "BootyProfiler is still loading." end
    if type(value) ~= "boolean" then return false, "Expected true or false." end
    local changed = L.IsArmed() ~= value
    Database().captureNextLogin = value
    if not active then status = value and "armed" or "off" end
    if changed then Notify() end
    return true
end
function L.IsArmed() return type(BootyProfilerDB) == "table" and BootyProfilerDB.captureNextLogin == true or false end
function L.IsRecording() return active ~= nil end
function L.IsOwnFrame(frame) return driver ~= nil and frame == driver end
function L.GetReport()
    if active then return active end
    return type(BootyProfilerDB) == "table" and type(BootyProfilerDB.lastLoginMemory) == "table" and BootyProfilerDB.lastLoginMemory or nil
end
function L.GetStatus() return status end
function L.SetListener(callback)
    if callback ~= nil and type(callback) ~= "function" then return false, "Expected a function or nil." end
    listener = callback; return true
end
function L.Cancel()
    if not loaded then return false, "BootyProfiler is still loading." end
    local changed = L.IsArmed() or status ~= "off"
    Database().captureNextLogin = false
    if active then Finish("cancelled", "user-cancelled") else status = "off"; StopHandlers(); if changed then Notify() end end
    return true
end

if type(CreateFrame) == "function" then
    driver = CreateFrame("Frame", nil, UIParent)
    driver:Hide(); driver:RegisterEvent("ADDON_LOADED"); driver:SetScript("OnEvent", OnEvent)
else loaded = true; status = "unavailable" end
