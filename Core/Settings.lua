local P = BootyProfiler
local Settings = {}
P.Core.Settings = Settings
local defaults = { monitorWidth = 360, monitorHeight = 360 * 572 / 1024,
    measureCallbackMemory = false, hideMinimapIcon = false }
local function Dimension(value, fallback, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value <= 0 or value >= 1e300 then value = fallback end
    return math.max(minimum, math.min(maximum, value))
end
function Settings.Initialize(db)
    if db.monitorWidth == nil then db.monitorWidth = db.performanceMonitorWidth end
    if db.monitorHeight == nil then db.monitorHeight = db.performanceMonitorHeight end
    if db.schema == nil then db.schema = 1 end
    db.monitorWidth = Dimension(db.monitorWidth, defaults.monitorWidth, 300, 720)
    db.monitorHeight = Dimension(db.monitorHeight, defaults.monitorHeight, 148, 460)
    if type(db.measureCallbackMemory) ~= "boolean" then db.measureCallbackMemory = defaults.measureCallbackMemory end
    if type(db.hideMinimapIcon) ~= "boolean" then db.hideMinimapIcon = defaults.hideMinimapIcon end
    if type(db.minimap) ~= "table" then db.minimap = { angle = 225 } end
    db.performanceMonitorWidth, db.performanceMonitorHeight = nil, nil
    return db
end
function Settings.Ensure()
    local data = BootyLib and BootyLib.Data
    if data and data.GetOwner("profiler") then
        local db, failure = data.Ensure("profiler")
        if not db then error(failure or "Profiler settings migration failed.") end
        return db
    end
    if type(BootyProfilerDB) ~= "table" then BootyProfilerDB = {} end
    return Settings.Initialize(BootyProfilerDB)
end
function Settings.SetMemoryMode(value)
    Settings.Ensure().measureCallbackMemory = value and true or false
end
function Settings.GetMonitorSize()
    local db = Settings.Ensure()
    return db.monitorWidth, db.monitorHeight
end
function Settings.SetMonitorSize(width, height)
    local db = Settings.Ensure()
    db.monitorWidth = Dimension(width, defaults.monitorWidth, 300, 720)
    db.monitorHeight = Dimension(height, defaults.monitorHeight, 148, 460)
end
function Settings.Describe()
    return { db = Settings.Ensure(), fields = {
        { type = "checkbox", key = "measureCallbackMemory", label = "Measure callback memory by default", default = false,
            tooltip = "New Profile All recordings measure shared Lua memory changes around each callback. Adds two memory reads per measured call." },
        { type = "slider", key = "monitorWidth", legacyKey = "performanceMonitorWidth", label = "Live Monitor width", default = defaults.monitorWidth, min = 300, max = 720, step = 1 },
        { type = "slider", key = "monitorHeight", legacyKey = "performanceMonitorHeight", label = "Live Monitor height", default = defaults.monitorHeight, min = 148, max = 460, step = 1 },
        { type = "checkbox", key = "hideMinimapIcon", label = "Hide standalone minimap icon", default = false,
            tooltip = "Applies when BootyProfiler runs without Booty Suite. Use /bootyprofiler to open its window." },
    } }
end
if BootyLib and BootyLib.Data then
    BootyLib.Data.RegisterOwner("profiler", "BootyProfilerDB", function(key)
        return key == "performanceMonitorWidth" or key == "performanceMonitorHeight"
    end, Settings.Initialize)
end
