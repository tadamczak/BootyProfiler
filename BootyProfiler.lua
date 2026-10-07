local P = BootyProfiler
local controllers = {}
local Product = { id = "profiler", name = "BootyProfiler", version = P.version, apiVersion = 1, namespace = P }
P.Product = Product

local function CreateView(parent, host)
    local controller = controllers[host]
    if controller then return controller end
    local settings = P.Core.Settings
    local db = settings.Ensure()
    controller = P.Modules.Performance.Create(parent, {
        standalone = host.standalone == true,
        loadMonitorSize = settings.GetMonitorSize, saveMonitorSize = settings.SetMonitorSize,
        measureMemory = db.measureCallbackMemory, saveMemoryMode = settings.SetMemoryMode,
    })
    controllers[host] = controller
    return controller
end
Product.views = { { id = "profiler", label = "Profiler", icon = "performance", create = CreateView } }
function Product.Initialize() return P.Core.Settings.Ensure() end
function Product.Start() return P.Core.Settings.Ensure() ~= nil end
function Product.GetSettings() return P.Core.Settings.Describe() end
function Product.GetDatabase() return P.Core.Settings.Ensure() end
local function InactiveReason()
    if Product.stopped then return "This addon is paused. Resume it in Booty Suite Plugins." end
    return Product.failure
end
function Product.GetController(host)
    if InactiveReason() then return nil end
    return controllers[host] or host.GetView and host.GetView("profiler")
end
local function Action(host, name, show)
    return function()
        local failure = InactiveReason()
        if failure then if host.Print then host.Print(failure) end; return false, failure end
        if show and not host.OpenView("profiler") then return false end
        local controller = Product.GetController(host)
        if not controller then if host.Print then host.Print("Profiler view is unavailable.") end; return false end
        if name == "all" then return controller:SelectTab("All Addons") end
        if name == "booty" then return controller:SelectTab("Booty") end
        if name == "actionbars" then return controller:SelectTab("Action Bars") end
        if name == "login" then return controller:SelectTab("Analyze Login") end
        return controller:ExecuteQuickAction(name)
    end
end
function Product.GetQuickMenu(host)
    local available = InactiveReason() == nil
    local state = P.GetState()
    local controller = controllers[host]
    local db = P.Core.Settings.Ensure()
    local memory = db.measureCallbackMemory
    if controller then memory = controller.measureMemory end
    local conflict = controller and controller.HasCaptureConflict and controller:HasCaptureConflict() or false
    local foreignSession = controller and controller.HasForeignProfileSession and controller:HasForeignProfileSession() or false
    local advanced = {
        { text = state.recording and "Stop" or "Start", icon = state.recording and "stop" or "start", enabled = available and not conflict, action = Action(host, "startStop") },
        { text = "Reset", icon = "reset", enabled = available and state.session ~= nil and not foreignSession, action = Action(host, "reset") },
        { text = "Export", icon = "save", enabled = available and state.session ~= nil and not state.recording and not foreignSession, action = Action(host, "export") },
    }
    if not controller or controller.tab ~= "Action Bars" then
        table.insert(advanced, { text = memory and "Memory: ON" or "Memory: OFF", icon = "memory", checked = memory and true or false,
            enabled = available and not state.recording, keepOpen = true, action = Action(host, "memory") })
    end
    if not host.standalone then table.insert(advanced, { text = "Profile Booty", icon = "guild_stats", action = Action(host, "booty", true) }) end
    table.insert(advanced, { text = "Profile All", icon = "groups", action = Action(host, "all", true) })
    if type(P.HasActionBarsCapture) == "function" and P.HasActionBarsCapture() then
        table.insert(advanced, { text = "Profile Action Bars", icon = "list", action = Action(host, "actionbars", true) })
    end
    table.insert(advanced, { text = "Analyze Login", icon = "analyze", action = Action(host, "login", true) })
    local items = {
        { text = "Live Monitor", icon = "monitor", enabled = available and P.LiveMonitor ~= nil, action = Action(host, "live") },
        { text = "Advanced Profiler", icon = "performance", enabled = available, children = advanced },
        { text = "Health Check", icon = "health", enabled = available and P.GetLastHealthReport ~= nil, action = Action(host, "health", true) },
    }
    if host.standalone then
        table.insert(items, { text = "Settings", icon = "settings", action = host.OpenSettings })
    else
        table.insert(items, { text = "Disable", icon = "disable", action = Action(host, "addon", true) })
    end
    return items
end
function Product.Stop()
    for _, controller in pairs(controllers) do controller:Hide(); if controller.monitor then controller.monitor:Close() end end
    return P.Core.ProfilerBridge.PrepareDisable()
end
function Product.IsBusy()
    return P.GetState().recording or P.LoginMemory and P.LoginMemory.IsRecording() or false
end
function Product.OnSettingsChanged()
    local db = P.Core.Settings.Ensure()
    local host = P.host
    if host and host.minimap then
        if db.hideMinimapIcon or db.presentation and db.presentation.minimap and db.presentation.minimap.hidden then host.minimap:Hide()
        else host.minimap:Show() end
    end
    if not P.GetState().recording then
        for _, controller in pairs(controllers) do
            controller.measureMemory = db.measureCallbackMemory
            controller.callbackView = controller.measureMemory and "memory" or "time"
            if controller.frame:IsVisible() then controller:Refresh() end
        end
    end
end
function Product.OnHostReady(host)
    P.host = host
    SLASH_BOOTYPROFILER1, SLASH_BOOTYPROFILER2 = "/bootyprofiler", "/bp"
    SlashCmdList = SlashCmdList or {}
    SlashCmdList.BOOTYPROFILER = function(message)
        local command = string.lower(string.gsub(tostring(message or ""), "^%s*(.-)%s*$", "%1"))
        if command == "settings" then return host.OpenSettings() end
        local failure = InactiveReason()
        if failure then if host.Print then host.Print(failure) end; return false, failure end
        if command == "live" then return Action(host, "live")() end
        if command == "all" then return Action(host, "all", true)() end
        if command == "actionbars" then return Action(host, "actionbars", true)() end
        if command == "login" then return Action(host, "login", true)() end
        if command == "health" then return Action(host, "health", true)() end
        return host.OpenView("profiler")
    end
end
BootyLib.RegisterProduct(Product)
