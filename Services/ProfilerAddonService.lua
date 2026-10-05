local P = BootyProfiler
local Service = {}
P.Services.ProfilerAddon = Service

local ADDON_NAME, INVENTORY_LIMIT = "BootyProfiler", 4096
local status = { state = "unknown", installed = false, loaded = false, reason = "not-inspected" }
Service.INVENTORY_LIMIT = INVENTORY_LIMIT

local function ClientFlag(value)
    return value ~= nil and value ~= false and value ~= 0
end

-- Called only when opening Performance or accepting an explicit action. The
-- name form of stock GetAddOnInfo can echo a missing name; enumerate instead.
function Service.Refresh()
    local loaded = type(BootyProfiler) == "table"
    local result = { state = "unknown", installed = loaded, loaded = loaded,
        canReload = type(ReloadUI) == "function", reason = "inventory-unavailable" }
    if type(IsAddOnLoaded) == "function" then
        local ok, value = pcall(IsAddOnLoaded, ADDON_NAME)
        if ok and ClientFlag(value) then loaded, result.loaded, result.installed = true, true, true end
    end
    if type(GetNumAddOns) == "function" and type(GetAddOnInfo) == "function" then
        local ok, count = pcall(GetNumAddOns)
        if ok and type(count) == "number" and count == count and count >= 0 and count <= 1e300 and count == math.floor(count) then
            local limit, failed = math.min(count, INVENTORY_LIMIT), false
            local index
            for index = 1, limit do
                local read, name, _, _, enabled, loadable, reason = pcall(GetAddOnInfo, index)
                if not read or type(name) ~= "string" then failed = true end
                if read and name == ADDON_NAME then
                    result.installed, result.index = true, index
                    result.enabled, result.loadable, result.loadReason = ClientFlag(enabled), ClientFlag(loadable), reason
                    result.reason = nil
                    break
                end
            end
            if not result.installed then
                if count > INVENTORY_LIMIT then result.reason = "inventory-limit"
                elseif failed then result.reason = "inventory-read-failed"
                else result.state, result.reason = "absent", "not-installed" end
            end
        else result.reason = "inventory-invalid" end
    end
    if loaded then result.state = "loaded"
    elseif result.installed then result.state = "available" end
    result.canEnable = result.installed and not loaded and type(EnableAddOn) == "function" and result.canReload or false
    result.canDisable = result.installed and type(DisableAddOn) == "function" and result.canReload or false
    -- Reload does not unload code until the client actually reconstructs Lua.
    result.reloadRequired, result.pendingEnabled = status.reloadRequired, status.pendingEnabled
    status = result
    return status
end

function Service.GetStatus() return status end

function Service.SetEnabled(enabled, prepareDisable)
    if type(enabled) ~= "boolean" then return false, "invalid-state" end
    local current = Service.Refresh()
    if not current.installed then return false, current.reason or "not-installed" end
    local change = enabled and EnableAddOn or DisableAddOn
    if type(change) ~= "function" then return false, "addon-control-unavailable" end
    if not current.canReload then return false, "reload-unavailable" end
    if not enabled and current.loaded and type(prepareDisable) ~= "function" then return false, "cleanup-unavailable" end
    if not enabled and prepareDisable then
        local ok, ready, failure = pcall(prepareDisable)
        if not ok or ready ~= true then return false, "cleanup-failed", ok and failure or ready end
    end
    local ok, value = pcall(change, ADDON_NAME)
    if not ok or value == false then return false, "addon-control-failed", value end
    -- Stock setters return no result. Preserve the live loaded state while the
    -- explicit reload is pending; no other addon's enable flag is touched.
    current.enabled, current.pendingEnabled, current.reloadRequired = enabled, enabled, true
    return true
end

function Service.Reload()
    if type(ReloadUI) ~= "function" then return false, "reload-unavailable" end
    local runtime = BootyLib and BootyLib.Core and BootyLib.Core.Runtime
    if runtime and runtime.CanReload then
        local ready, reason = runtime.CanReload()
        if not ready then return false, reason end
    end
    local ok, failure = pcall(ReloadUI)
    if not ok or failure == false then return false, "reload-failed", failure end
    return true
end
