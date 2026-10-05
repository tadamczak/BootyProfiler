local P = BootyProfiler
local Bridge = {}
P.Core.ProfilerBridge = Bridge
local source = {}

function source.start(observer)
    local D = BootyLib.Diagnostics
    if D.sampleObserver then return nil, "Another Booty sample observer is active." end
    local scope = D.BeginScope("bootyprofiler")
    scope.previousTracking, scope.observer = D.trackOperations, observer
    D.SetSampleObserver(observer); D.SetTracking(true)
    return { scope = scope, operations = scope.operations }
end
function source.stop(handle)
    local D, scope = BootyLib.Diagnostics, handle.scope
    D.EndScope(scope)
    if D.sampleObserver == scope.observer then D.SetSampleObserver(nil) end
    D.SetTracking(scope.previousTracking)
end
function source.capabilities()
    local core = BootyLib.Core
    return core and core.ClientCapabilities and core.ClientCapabilities.Collect()
end
function Bridge.Resolve()
    if P.API_VERSION ~= 1 or type(P.GetState) ~= "function" or type(P.RegisterSource) ~= "function"
        or type(P.Runtime) ~= "table" or type(P.Runtime.SetRunning) ~= "function" then
        return nil, "BootyProfiler has an incompatible API. Install a compatible version and reload."
    end
    return P
end
function Bridge.Connect(standalone)
    local provider, failure = Bridge.Resolve()
    if not provider then return nil, failure end
    if not standalone and not provider.GetState().recording then
        local D = BootyLib.Diagnostics
        if not D or not D.BeginScope or not D.SetSampleObserver then return nil, "Booty diagnostics are unavailable." end
        local ok, message = provider.RegisterSource("Booty", source)
        if not ok then return nil, message end
    end
    return provider
end
function Bridge.GetAddonStatus(refresh)
    local service = P.Services.ProfilerAddon
    if refresh then return service.Refresh() end
    return service.GetStatus()
end
function Bridge.PrepareDisable()
    local ready, failure = true, nil
    if P.LiveMonitor then
        local ok, result = pcall(P.LiveMonitor.SetVisible, false)
        if not ok or result == false then ready, failure = false, "Live monitor cleanup failed." end
    end
    if P.GetState().recording then
        local ok, result = pcall(P.Stop)
        if not ok or result == false then ready, failure = false, "Profiler cleanup failed." end
    end
    local disabled = pcall(P.Enable, false)
    if not disabled then ready, failure = false, "Profiler shutdown failed." end
    if P.LoginMemory then
        local ok, result = pcall(P.LoginMemory.Cancel)
        if not ok or result == false then ready, failure = false, "Login capture cleanup failed." end
    end
    return ready, failure
end
function Bridge.SetAddonEnabled(enabled)
    return P.Services.ProfilerAddon.SetEnabled(enabled, Bridge.PrepareDisable)
end
function Bridge.ReloadUI() return P.Services.ProfilerAddon.Reload() end
-- Standalone captures never open a Suite operation source.
function Bridge.Create(standalone)
    return { Resolve = Bridge.Resolve,
        Connect = function() return Bridge.Connect(standalone) end,
        GetAddonStatus = Bridge.GetAddonStatus, PrepareDisable = Bridge.PrepareDisable,
        SetAddonEnabled = Bridge.SetAddonEnabled, ReloadUI = Bridge.ReloadUI }
end
