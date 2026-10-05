-- Frame-label families are presentation groups, never callback source owners.
-- This helper reads plain retained metrics only: no frames, APIs or scheduler.
local F = {}
BootyProfiler.CallbackFamilies = F
local OPERATION_LIMIT, BUILD_BUDGET, SORT_BUDGET = 4096, 128, 1024
F.limits = { operations = OPERATION_LIMIT, perStep = BUILD_BUDGET, sortStep = SORT_BUDGET }
local anonymousTypes = { Frame = true, Button = true, CheckButton = true, EditBox = true,
    Slider = true, ScrollFrame = true, StatusBar = true, MessageFrame = true,
    ScrollingMessageFrame = true, SimpleHTML = true, Model = true, PlayerModel = true,
    DressUpModel = true, GameTooltip = true, Minimap = true, Cooldown = true }

local function Text(value)
    return type(value) == "string" and value ~= "" and string.len(value) <= 512 and value or nil
end

local function NamedFamily(label)
    local first, last = string.find(label, "^[^_]+_")
    if first then return string.sub(label, first, last) end
    local _, _, numbered = string.find(label, "^(.-)%s*#?%d+$")
    if numbered and numbered ~= "" then return numbered end
    return label
end

function F.FamilyName(operation)
    if type(operation) ~= "table" then return "Anonymous frames" end
    local context = Text(operation.frameContext)
    if context then
        local _, _, root = string.find(context, "^([^%.%[%s>]+)")
        if root then return NamedFamily(root) end
    end
    local label = Text(operation.frameLabel) or Text(operation.name)
    if not label then return "Anonymous frames" end
    local first = string.find(label, " / ", 1, true)
    if first then label = string.sub(label, 1, first - 1) end
    local _, _, anonymous = string.find(label, "^([%a]+) #%d+$")
    if anonymousTypes[anonymous] or string.find(label, "^Unnamed frame %d+$") then return "Anonymous frames" end
    return NamedFamily(label)
end

local function NewTotals() return { calls = 0, time = 0, selfTime = 0, peak = 0, failures = 0, timedCalls = 0,
    heapSamples = 0, heapDelta = 0, heapRise = 0, heapPeak = 0, heapUnsupportedCalls = 0 } end
local familyMeta = { __index = function(family, key) return family.totals[family.model.published][key] end }
local function Budget(value, maximum)
    value = tonumber(value) or BUILD_BUDGET
    if value ~= value or value < 1 then value = 1 end
    return math.min(maximum, math.floor(value))
end

function F.Create(operations, sortKey)
    operations = type(operations) == "table" and operations or {}
    local length = table.getn(operations)
    local total = math.min(OPERATION_LIMIT, length)
    return { source = operations, total = total, target = total, cursor = 0,
        pending = total > 0, truncated = length > OPERATION_LIMIT, indexed = 0,
        families = {}, familyMap = {}, members = {}, order = {}, sortTimes = {},
        published = 1, updateState = {}, sortState = {}, sortScratch = {}, sortKey = sortKey == "heapRise" and "heapRise" or "selfTime" }
end

function F.Sync(model, budget)
    if not model.pending then return true, model.cursor end
    budget = Budget(budget, BUILD_BUDGET)
    local last = math.min(model.total, model.cursor + budget)
    for index = model.cursor + 1, last do
        local operation = model.source[index]
        if type(operation) == "table" and not model.members[operation] then
            local name = F.FamilyName(operation)
            local family = model.familyMap[name]
            if not family then
                family = setmetatable({ name = name, children = {}, count = 0, model = model,
                    totals = { NewTotals(), NewTotals() } }, familyMeta)
                model.familyMap[name] = family; table.insert(model.families, family)
            end
            table.insert(family.children, operation); family.count = family.count + 1
            model.members[operation] = family; model.order[operation] = index
            model.sortTimes[operation] = 0
            model.indexed = model.indexed + 1
        end
    end
    model.cursor, model.pending = last, last < model.total
    return not model.pending, last
end

local function Number(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value >= 1e300 then return 0 end
    return value
end
local function SignedNumber(value)
    if type(value) ~= "number" or value ~= value or value <= -1e300 or value >= 1e300 then return 0 end
    return value
end

function F.BeginUpdate(model)
    if model.pending or model.updating or model.sorting then return false end
    model.updating = true
    local state = model.updateState
    state.phase, state.cursor, state.write = "clear", 0, 3 - model.published
    return true
end

function F.UpdateStep(model, budget)
    if not model.updating then return true end
    budget = Budget(budget, BUILD_BUDGET)
    local state = model.updateState
    while budget > 0 do
        if state.phase == "clear" then
            if state.cursor >= table.getn(model.families) then state.phase, state.cursor = "aggregate", 0
            else
                state.cursor = state.cursor + 1
                local totals = model.families[state.cursor].totals[state.write]
                totals.calls, totals.time, totals.selfTime, totals.peak, totals.failures, totals.timedCalls = 0, 0, 0, 0, 0, 0
                totals.heapSamples, totals.heapDelta, totals.heapRise, totals.heapPeak = 0, 0, 0, 0
                totals.heapUnsupportedCalls = 0
                budget = budget - 1
            end
        elseif state.cursor >= model.total then
            -- A single pointer publishes all families together. Accumulation
            -- spans multiple steps and is not an instantaneous capture.
            model.published, model.updating = state.write, false
            state.phase = nil; return true
        else
            state.cursor = state.cursor + 1
            local operation = model.source[state.cursor]
            local family = model.members[operation]
            if family and model.order[operation] == state.cursor then
                local totals = family.totals[state.write]
                local own = Number(operation.selfTime)
                totals.calls = totals.calls + Number(operation.calls)
                totals.time = totals.time + Number(operation.time); totals.selfTime = totals.selfTime + own
                totals.peak = math.max(totals.peak, Number(operation.peak)); totals.failures = totals.failures + Number(operation.failures)
                totals.timedCalls = totals.timedCalls + Number(operation.timedCalls == nil and operation.calls or operation.timedCalls)
                totals.heapSamples = totals.heapSamples + Number(operation.heapSamples)
                totals.heapDelta = totals.heapDelta + SignedNumber(operation.heapDelta)
                totals.heapRise = totals.heapRise + Number(operation.heapRise)
                totals.heapPeak = math.max(totals.heapPeak, Number(operation.heapPeak))
                totals.heapUnsupportedCalls = totals.heapUnsupportedCalls + Number(operation.heapUnsupportedCalls)
                model.sortTimes[operation] = Number(operation[model.sortKey])
            end
            budget = budget - 1
        end
    end
    return false
end

function F.Update(model)
    -- Convenience path for small inventories only; large reports must yield.
    if model.total > BUILD_BUDGET or not F.BeginUpdate(model) then return false end
    while not F.UpdateStep(model) do end
    return true
end

local function Compare(model, families, left, right)
    local leftTime, rightTime
    if families then
        leftTime, rightTime = left.totals[model.published][model.sortKey], right.totals[model.published][model.sortKey]
    else leftTime, rightTime = model.sortTimes[left], model.sortTimes[right] end
    if leftTime ~= rightTime then return leftTime > rightTime end
    local leftName, rightName = Text(left.name) or "", Text(right.name) or ""
    if leftName ~= rightName then return leftName < rightName end
    if families then return false end
    return model.order[left] < model.order[right]
end

local function StartList(state, list, families)
    state.list, state.length, state.families = list, table.getn(list), families
    state.width, state.cursor = 1, 1
    state.phase = state.length > 1 and "copy" or "advance"
end

local function StartMerge(state, first)
    state.first, state.left, state.write = first, first, first
    state.leftEnd = math.min(state.length, first + state.width - 1)
    state.right, state.rightEnd = state.leftEnd + 1, math.min(state.length, first + state.width * 2 - 1)
end

function F.BeginSort(model)
    if model.pending or model.updating or model.sorting then return false end
    model.sorting = true
    local state = model.sortState
    state.familyCursor = 0
    StartList(state, model.families, true)
    return true
end

function F.SortStep(model, budget)
    if not model.sorting then return true end
    budget = Budget(budget, SORT_BUDGET)
    local state, scratch = model.sortState, model.sortScratch
    while budget > 0 do
        if state.phase == "advance" then
            state.familyCursor = state.familyCursor + 1
            if state.familyCursor > table.getn(model.families) then
                model.sorting = false; state.list, state.phase = nil, nil; return true
            end
            StartList(state, model.families[state.familyCursor].children, false)
            budget = budget - 1
        elseif state.phase == "copy" then
            scratch[state.cursor] = state.list[state.cursor]
            state.cursor = state.cursor + 1; budget = budget - 1
            if state.cursor > state.length then StartMerge(state, 1); state.phase = "merge" end
        else
            local takeLeft = state.right > state.rightEnd or state.left <= state.leftEnd
                and not Compare(model, state.families, scratch[state.right], scratch[state.left])
            if takeLeft then state.list[state.write] = scratch[state.left]; state.left = state.left + 1
            else state.list[state.write] = scratch[state.right]; state.right = state.right + 1 end
            state.write = state.write + 1; budget = budget - 1
            if state.write > state.rightEnd then
                local nextFirst = state.first + state.width * 2
                if nextFirst <= state.length then StartMerge(state, nextFirst)
                else
                    state.width = state.width * 2
                    state.phase, state.cursor = state.width >= state.length and "advance" or "copy", 1
                end
            end
        end
    end
    return false
end

function F.Sort(model)
    if model.total > BUILD_BUDGET or not F.BeginSort(model) then return false end
    while not F.SortStep(model) do end
    return true
end
