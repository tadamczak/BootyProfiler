local P = BootyProfiler
local Runtime = { driver = nil, elapsed = 0 }
P.Runtime = Runtime

local function Tick()
    local state = P.GetState()
    if not state.recording then return end
    local elapsed = P.ObserveFrame(tonumber(arg1))
    if state.session.callbacksRequested and P.Callbacks then
        local scanned, failure = pcall(P.Callbacks.Step, elapsed)
        if not scanned then P.Fail(failure); return end
    end
    Runtime.elapsed = Runtime.elapsed + elapsed
    if Runtime.elapsed >= 1 then
        Runtime.elapsed = 0
        local ok, failure = pcall(P.Sample)
        if not ok then P.Fail(failure) end
    end
end

function Runtime.SetRunning(running)
    if running then
        if not Runtime.driver then Runtime.driver = CreateFrame("Frame", nil, UIParent) end
        Runtime.elapsed = 0; Runtime.driver:SetScript("OnUpdate", Tick); Runtime.driver:Show()
    elseif Runtime.driver then
        Runtime.driver:SetScript("OnUpdate", nil); Runtime.driver:Hide(); Runtime.elapsed = 0
    end
end
