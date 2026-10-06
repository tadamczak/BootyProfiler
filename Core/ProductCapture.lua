-- Explicit product targets only; no frame discovery, polling or shared-heap reads.
local P = BootyProfiler
local Capture = {}
P.Core.ProductCapture = Capture
local active, restorationBlocked
local TARGET_LIMIT, MODEL_LIMIT, SLOW_THRESHOLD, STACK_LIMIT = 73, 72, 0.005, 64
local StockAssert = assert
local COVERAGE = "Explicit BootyActionBars event entry and existing main/custom cooldown OnUpdateModel scripts (up to 73 targets); pet and stance bars are excluded. Self time excludes nested scoped targets, inclusive time retained separately. Not total addon CPU or owned memory; targets fixed at Start."

local function Finite(value)
    return type(value) == "number" and value == value and value > -1e300 and value < 1e300
end
local function Integer(value, limit)
    return Finite(value) and value >= 0 and value <= limit and value == math.floor(value)
end
local function OptionalInteger(value, limit)
    return value == nil or Integer(value, limit)
end
local function Resolve()
    if type(BootyLib) ~= "table" or type(BootyLib.GetProduct) ~= "function" then
        return nil, "BootyLib product registry is unavailable."
    end
    local product = BootyLib.GetProduct("actionbars")
    if type(product) ~= "table" or type(product.GetProfilingTargets) ~= "function" then
        return nil, "BootyActionBars profiling targets are unavailable."
    end
    local descriptor = product.GetProfilingTargets()
    if type(descriptor) ~= "table" or descriptor.contractVersion ~= 1 or
        type(descriptor.productVersion) ~= "string" or descriptor.productVersion == "" or type(descriptor.targets) ~= "table" then
        return nil, "Unsupported BootyActionBars profiling contract."
    end
    for _, key in ipairs({"active", "requested", "subscribed", "framesInitialized"}) do
        if type(descriptor[key]) ~= "boolean" then return nil, "Invalid BootyActionBars profiling state." end
    end
    if not OptionalInteger(descriptor.customRevision, 9007199254740991) or
        not OptionalInteger(descriptor.customConfiguredCount, 5) or not OptionalInteger(descriptor.customActiveCount, 5) or
        (descriptor.customActiveCount or 0) > (descriptor.customConfiguredCount or 0) then
        return nil, "Invalid BootyActionBars custom profiling state."
    end
    if not OptionalInteger(descriptor.specialConfiguredCount, 2) then
        return nil, "Invalid BootyActionBars special profiling state."
    end
    return descriptor
end
local function Snapshot(descriptor)
    local result = {contractVersion = descriptor.contractVersion, productVersion = descriptor.productVersion,
        active = descriptor.active, requested = descriptor.requested, subscribed = descriptor.subscribed,
        framesInitialized = descriptor.framesInitialized, targetCount = table.getn(descriptor.targets),
        customRevision = descriptor.customRevision or 0,
        customConfiguredCount = descriptor.customConfiguredCount or 0,
        customActiveCount = descriptor.customActiveCount or 0,
        specialConfiguredCount = descriptor.specialConfiguredCount or 0}
    if type(descriptor.runtimeStopped) == "boolean" then result.runtimeStopped = descriptor.runtimeStopped end
    if type(descriptor.settingsEnabled) == "boolean" then result.settingsEnabled = descriptor.settingsEnabled end
    return result
end
local function ReadFunction(owner, key) return owner[key] end
local function WriteFunction(owner, key, value) owner[key] = value end
local function ReadScript(frame, script) return frame:GetScript(script) end
local function WriteScript(frame, script, value) frame:SetScript(script, value) end
local function ReadTarget(record)
    if record.kind == "function" then return ReadFunction(record.owner, record.key) end
    return ReadScript(record.frame, record.script)
end
local function WriteTarget(record, value)
    if record.kind == "function" then return WriteFunction(record.owner, record.key, value) end
    return WriteScript(record.frame, record.script, value)
end
local function ReadClock(run)
    if not run.active then return nil end
    local ok, value = pcall(run.clock)
    if ok and Finite(value) then return value * run.scale end
    run.metadata.clockReadFailures = run.metadata.clockReadFailures + 1
    return nil
end
local function Begin(run)
    run.depth = run.depth + 1
    local slot = run.stack[run.depth]
    slot.children, slot.childrenInvalid = 0, false
    slot.started = ReadClock(run)
    return slot
end
local function Finish(run, record, slot, ended, success)
    if not run.active then return end
    local operation, metadata = record.operation, run.metadata
    operation.count = operation.count + 1
    if not success then operation.failures = operation.failures + 1 end
    local started, elapsed = slot.started, nil
    if started ~= nil and ended ~= nil and ended >= started and Finite(ended - started) then elapsed = ended - started end
    run.depth = run.depth - 1
    local parent = run.stack[run.depth]
    if parent then
        if elapsed then parent.children = parent.children + elapsed
        else parent.childrenInvalid = true end
    end
    local children, childrenInvalid = slot.children, slot.childrenInvalid
    slot.started, slot.children, slot.childrenInvalid = nil, 0, false
    if elapsed == nil or not Finite(operation.inclusiveTime + elapsed) then
        metadata.timingFailures, metadata.partial = metadata.timingFailures + 1, true
        return
    end
    operation.inclusiveTime = operation.inclusiveTime + elapsed
    operation.inclusiveTimedCalls = operation.inclusiveTimedCalls + 1
    if elapsed > operation.maxInclusiveTime then operation.maxInclusiveTime = elapsed end
    if childrenInvalid or children > elapsed or not Finite(children) or not Finite(operation.time + elapsed - children) then
        metadata.timingFailures, metadata.partial = metadata.timingFailures + 1, true
        return
    end
    local own = elapsed - children
    operation.timedCalls = operation.timedCalls + 1
    operation.time = operation.time + own
    if own > operation.maxTime then operation.maxTime = own end
    if run.observer and elapsed >= SLOW_THRESHOLD then
        local ok = pcall(run.observer, record.name, elapsed, nil)
        if not ok then metadata.observerFailures = metadata.observerFailures + 1 end
    end
end
local function Overflow(run, record, success)
    if not run.active then return end
    record.operation.count = record.operation.count + 1
    if not success then record.operation.failures = record.operation.failures + 1 end
    run.metadata.depthSkipped, run.metadata.partial = run.metadata.depthSkipped + 1, true
    run.stack[run.depth].childrenInvalid = true
end
local function Rethrow(failure)
    error(failure, 0)
    -- Modified clients may print error() without throwing, including nil errors.
    StockAssert(false, failure)
end
local function Wrapper0(record)
    return function()
        local run = record.run
        if not run or not run.active then record.original(); return end
        if run.depth >= STACK_LIMIT then
            local ok, failure = pcall(record.original)
            Overflow(run, record, ok)
            if not ok then Rethrow(failure) end
            return
        end
        local oldThis, oldEvent, oldArg = this, event, arg1
        local slot = Begin(run)
        this, event, arg1 = oldThis, oldEvent, oldArg
        local ok, failure = pcall(record.original)
        local outThis, outEvent, outArg = this, event, arg1
        local ended = ReadClock(run)
        this, event, arg1 = outThis, outEvent, outArg
        Finish(run, record, slot, ended, ok)
        this, event, arg1 = outThis, outEvent, outArg
        if not ok then Rethrow(failure) end
    end
end
local function Wrapper2(record)
    return function(first, second)
        local run = record.run
        if not run or not run.active then record.original(first, second); return end
        if run.depth >= STACK_LIMIT then
            local ok, failure = pcall(record.original, first, second)
            Overflow(run, record, ok)
            if not ok then Rethrow(failure) end
            return
        end
        local oldThis, oldEvent, oldArg = this, event, arg1
        local slot = Begin(run)
        this, event, arg1 = oldThis, oldEvent, oldArg
        local ok, failure = pcall(record.original, first, second)
        local outThis, outEvent, outArg = this, event, arg1
        local ended = ReadClock(run)
        this, event, arg1 = outThis, outEvent, outArg
        Finish(run, record, slot, ended, ok)
        this, event, arg1 = outThis, outEvent, outArg
        if not ok then Rethrow(failure) end
    end
end
local function Targets(descriptor, run)
    local count, functions, models = table.getn(descriptor.targets), 0, 0
    if count < 1 or count > TARGET_LIMIT then return false, "Invalid action bar profiling target count." end
    for key in pairs(descriptor.targets) do
        if type(key) ~= "number" or key < 1 or key > count or key ~= math.floor(key) then
            return false, "Profiling targets must be a contiguous list."
        end
    end
    for index = 1, count do
        local target = descriptor.targets[index]
        if type(target) ~= "table" or type(target.name) ~= "string" or target.name == "" or target.results ~= 0 then
            return false, "Invalid action bar profiling target descriptor."
        end
        if run.handle.operations[target.name] then return false, "Duplicate action bar profiling target name." end
        local record = {kind = target.kind, name = target.name, run = run}
        if target.kind == "function" and target.parameters == 2 and type(target.owner) == "table" and target.key == "HandleEvent" then
            functions = functions + 1
            record.owner, record.key = target.owner, target.key
        elseif target.kind == "script" and target.parameters == 0 and target.script == "OnUpdateModel" and
            (type(target.frame) == "table" or type(target.frame) == "userdata") then
            models = models + 1
            record.frame, record.script = target.frame, target.script
        else return false, "Unsupported action bar profiling target kind or signature." end
        if functions > 1 or models > MODEL_LIMIT then return false, "Action bar profiling target limit exceeded." end
        for _, previous in ipairs(run.records) do
            if record.kind == previous.kind and (record.owner and record.owner == previous.owner and record.key == previous.key or
                record.frame and record.frame == previous.frame and record.script == previous.script) then
                return false, "Duplicate action bar profiling target reference."
            end
        end
        local read, original = pcall(ReadTarget, record)
        if not read or type(original) ~= "function" then return false, "Action bar profiling target callback is unavailable: " .. target.name end
        record.original = original
        record.operation = {count = 0, time = 0, maxTime = 0, failures = 0, timedCalls = 0,
            inclusiveTime = 0, inclusiveTimedCalls = 0, maxInclusiveTime = 0}
        record.wrapper = record.kind == "function" and Wrapper2(record) or Wrapper0(record)
        run.handle.operations[target.name] = record.operation
        run.records[index] = record
    end
    if functions ~= 1 then return false, "Action bar profiling requires its explicit event entry." end
    return true
end
local function Cleanup(run)
    run.active, run.clock, run.observer = false, nil, nil
    local metadata = run.metadata
    for _, record in ipairs(run.records) do
        if record.attempted then
            local read, current = pcall(ReadTarget, record)
            if not read then metadata.restoreFailures = metadata.restoreFailures + 1
            elseif current == record.wrapper then
                local written = pcall(WriteTarget, record, record.original)
                local checked, restored = pcall(ReadTarget, record)
                if not written or not checked or restored ~= record.original then
                    metadata.restoreFailures = metadata.restoreFailures + 1
                else metadata.restoredTargets = metadata.restoredTargets + 1 end
            else metadata.replacedTargets = metadata.replacedTargets + 1 end
        end
        -- Inert delegates retain only their original callback, never frames,
        -- target owners, a recording, an observer or measurement clocks.
        record.run, record.owner, record.frame, record.key, record.script = nil, nil, nil, nil, nil
        record.wrapper, record.operation, record.name = nil, nil, nil
    end
    run.records, run.stack = nil, nil
    if metadata.restoreFailures > 0 then restorationBlocked = true end
    metadata.restorationBlocked = restorationBlocked == true
    metadata.restored = metadata.restoreFailures == 0 and metadata.replacedTargets == 0
    metadata.partial = metadata.partial or metadata.restoreFailures > 0 or metadata.replacedTargets > 0
end
local function SelectClock(metadata)
    if type(debugprofilestop) == "function" then
        local ok, value = pcall(debugprofilestop)
        if ok and Finite(value) then metadata.clock = "debugprofilestop (differences; milliseconds)"; return debugprofilestop, 0.001 end
        metadata.clockProbeFailures = metadata.clockProbeFailures + 1
    end
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if ok and Finite(value) then metadata.clock = "GetTime"; return GetTime, 1 end
        metadata.clockProbeFailures = metadata.clockProbeFailures + 1
    end
    return nil
end
local function Start(observer)
    if restorationBlocked then return nil, "Action bar profiling restoration failed. Reload the UI before recording again." end
    if active then return nil, "Action bar profiling is already running." end
    if observer ~= nil and type(observer) ~= "function" then return nil, "Invalid action bar profiling observer." end
    local resolved, descriptor, failure = pcall(Resolve)
    if not resolved or not descriptor then return nil, tostring(resolved and failure or descriptor) end
    local metadata = {start = Snapshot(descriptor), coverage = COVERAGE, clockResolution = "Not verified in this client; zero and invalid durations are reported.",
        clockReadFailures = 0, clockProbeFailures = 0, timingFailures = 0, observerFailures = 0, depthSkipped = 0,
        restoreFailures = 0, restoredTargets = 0, replacedTargets = 0, hookedTargets = 0,
        partial = (descriptor.specialConfiguredCount or 0) > 0,
        excludedSpecialBars = (descriptor.specialConfiguredCount or 0) > 0,
        restored = false, restorationBlocked = false, memoryMeasured = false,
        configurationChanged = false, targetsChanged = false}
    local clock, scale = SelectClock(metadata)
    if not clock then return nil, "Action bar profiling clock is unavailable." end
    local handle = {operations = {}, metadata = metadata}
    local run = {handle = handle, metadata = metadata, records = {}, clock = clock, scale = scale, observer = observer,
        active = false, stack = {}, depth = 0}
    for index = 1, STACK_LIMIT do run.stack[index] = {children = 0, childrenInvalid = false} end
    local valid, reason = Targets(descriptor, run)
    if not valid then Cleanup(run); return nil, reason end
    active = run
    for _, record in ipairs(run.records) do
        record.attempted = true
        local written, writeError = pcall(WriteTarget, record, record.wrapper)
        local read, current = pcall(ReadTarget, record)
        if not written or not read or current ~= record.wrapper then
            metadata.partial = true
            Cleanup(run); active = nil
            return nil, tostring(not written and writeError or "Action bar profiling target installation could not be verified.")
        end
        metadata.hookedTargets = metadata.hookedTargets + 1
    end
    run.active, handle.capture = true, run
    return handle
end
local function Stop(handle)
    if type(handle) ~= "table" or type(handle.capture) ~= "table" or handle.capture ~= active then
        return false, "Invalid or stopped action bar profiling handle."
    end
    local run = handle.capture
    -- Final inspection and teardown are outside the measured gameplay scope.
    run.active = false
    local resolved, descriptor, failure = pcall(Resolve)
    if resolved and descriptor then
        handle.metadata["end"] = Snapshot(descriptor)
        local changed = table.getn(descriptor.targets) ~= table.getn(run.records)
        if not changed then
            for key in pairs(descriptor.targets) do
                if type(key) ~= "number" or key < 1 or key > table.getn(run.records) or key ~= math.floor(key) then
                    changed = true
                    break
                end
            end
        end
        if not changed then
            for index, record in ipairs(run.records) do
                local target = descriptor.targets[index]
                if type(target) ~= "table" or target.name ~= record.name or target.kind ~= record.kind or
                    target.owner ~= record.owner or target.key ~= record.key or
                    target.frame ~= record.frame or target.script ~= record.script or target.results ~= 0 or
                    target.parameters ~= (record.kind == "function" and 2 or 0) then
                    changed = true
                    break
                end
            end
        end
        if changed then
            handle.metadata.targetsChanged, handle.metadata.partial = true, true
        end
        local first, last = handle.metadata.start, handle.metadata["end"]
        if last.specialConfiguredCount > 0 then
            handle.metadata.excludedSpecialBars, handle.metadata.partial = true, true
        end
        if first.customRevision ~= last.customRevision or first.customConfiguredCount ~= last.customConfiguredCount or
            first.specialConfiguredCount ~= last.specialConfiguredCount then
            handle.metadata.configurationChanged, handle.metadata.partial = true, true
        end
    else
        handle.metadata.partial, handle.metadata.endStateUnavailable = true, true
        handle.metadata.endStateError = tostring(resolved and failure or descriptor)
    end
    -- Inspect identity before releasing the hook records; cleanup still runs
    -- when the final descriptor is unavailable or malformed.
    Cleanup(run)
    handle.capture, run.handle = nil, nil
    active = nil
    if handle.metadata.restoreFailures > 0 then return false, "Action bar profiling targets could not be restored. Reload the UI before recording again." end
    if not handle.metadata["end"] then return false, handle.metadata.endStateError end
    return true
end
local function Capabilities()
    if restorationBlocked then return {available = false, restorationBlocked = true, status = "Reload required after action bar profiling restoration failure."} end
    local ok, descriptor, failure = pcall(Resolve)
    if not ok or not descriptor then return {available = false, status = tostring(ok and failure or descriptor)} end
    local result = Snapshot(descriptor)
    result.available, result.memoryMeasured, result.coverage = true, false, COVERAGE
    return result
end
function Capture.Create()
    return {start = Start, stop = Stop, capabilities = Capabilities}
end
