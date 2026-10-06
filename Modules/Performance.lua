local P = BootyProfiler
local UI = BootyLib.UI.Components
P.Modules.Performance = P.Modules.Performance or {}
local Performance = P.Modules.Performance
local Results=P.Services.ProfilerResults

local function Duration(value) return string.format("%.2f ms", (tonumber(value) or 0) * 1000) end
local function ClockGap(value)
    if type(value)~="number" then return "Not observed" end
    if value>0 and value<0.001 then return string.format("%.2f us",value*1000000) end
    return Duration(value)
end
local function ClockName(value)
    if type(value)~="string" then return "Unavailable" end
    if string.find(value,"debugprofilestop",1,true) then return "debugprofilestop" end
    if string.find(value,"GetTime",1,true) then return "GetTime" end
    return value
end
local function Memory(value)
    if type(value) ~= "number" then return "Unavailable" end
    if math.abs(value) >= 1024 then return string.format("%.2f MB", value / 1024) end
    return string.format("%.1f KB", value)
end
local function SignedMemory(value)
    if type(value)~="number" then return "Unavailable" end
    return (value>0 and "+" or "")..Memory(value)
end
local function FPS(value) return type(value)=="number" and tostring(math.floor(value+0.5)) or "-" end
local function Seconds(value) return type(value)=="number" and string.format("%.2f s",value) or "Pending" end
local function Latency(value) return type(value)=="number" and string.format("%.0f ms",value) or "-" end
local function CompareTime(a, b) if a.time == b.time then return a.name < b.name end return a.time > b.time end
local function CompareCallbackTime(a,b)
    if (a.selfTime or 0)==(b.selfTime or 0) then
        if a.name==b.name then return (a.script or "")<(b.script or "") end
        return a.name<b.name
    end
    return (a.selfTime or 0)>(b.selfTime or 0)
end
local function CompareHeapRise(a,b)
    if (a.heapRise or 0)==(b.heapRise or 0) then return a.name<b.name end
    return (a.heapRise or 0)>(b.heapRise or 0)
end
Performance.Profiles={}
function Performance.Profiles.IsTab(tab) return tab=="MOS" or tab=="All Addons" or tab=="Action Bars" end
function Performance.Profiles.IsAvailable(provider)
    return provider and type(provider.HasActionBarsCapture)=="function" and provider.HasActionBarsCapture() and true or false
end
function Performance.Profiles.Matches(session,tab,standalone)
    if not session or not Performance.Profiles.IsTab(tab) then return false end
    if (tab=="All Addons")~=(session.callbacksRequested and true or false) then return false end
    local expected="Booty"
    if tab=="Action Bars" then expected="Action Bars" elseif standalone then expected=false end
    if tab=="Action Bars" then return session.sourceName==expected end
    -- Older Booty reports did not identify their selected-operation source.
    return session.sourceName==nil or session.sourceName==expected or tab=="MOS" and session.sourceName=="MOS"
end
local rowColor = {1,1,1}
local sectionColor={0.015,0.015,0.015}
local healthColors={{0.72,0.72,0.72},{0.45,0.85,0.45},{1,0.78,0.25},{1,0.35,0.25}}
local emptyEntries = {}
local FAMILY_PAGE_SIZE=50
local tables = {
    operations = { first = "Operation", columns = {"Calls","Total","Average","Peak","Heap delta"}, minimum = 760, nameFraction = 0.34 },
    actionBarsOperations = { first = "Entry point", columns = {"Calls","Self","Average self","Peak self"}, minimum = 680, nameFraction = 0.38,
        hints={Self="Time excluding nested watched Action Bars entry points. Ordinary helpers and observer overhead stay included.",
            ["Average self"]="Average self time across valid timed calls.",["Peak self"]="Longest measured self time for one call; excludes nested watched entry points."} },
    slow = { first = "Operation", columns = {"At","Duration","Heap delta","Event"}, minimum = 680, nameFraction = 0.34 },
    memory = { first = "Addon", columns = {"Memory"}, minimum = 300, nameFraction = 0.70 },
    memoryActivity = { first = "Source addon", columns = {"Calls","Heap growth","Net heap delta","Peak growth"}, minimum = 680, nameFraction = 0.34 },
    callbackMemory = { first = "Frame family / script", columns = {"Calls","Heap growth","Net heap delta","Peak growth","Errors"}, minimum = 760, nameFraction = 0.34 },
    loginMemory = { first = "Stage / addon", columns = {"At","Lua heap","Net heap delta","Window"}, minimum = 680, nameFraction = 0.34,
        hints={At="Seconds since the profiler began observing this login.",
            ["Net heap delta"]="Shared Lua memory in this row minus the previous reading. Cleanup can reduce it; it is not memory owned by this addon.",
            Window="Time from the previous reading to this row. Includes loading, dependencies and event handling; it is not this addon's loading time alone."} },
    callbacks = { first = "Source addon", columns = {"Calls","Self","Inclusive","Peak","Errors"}, minimum = 760, nameFraction = 0.34 },
    callbackDetails = { first = "Frame family / script", columns = {"Calls","Self","Inclusive","Peak","Errors"}, minimum = 760, nameFraction = 0.34 },
    callbackSlow = { first = "Frame / script", columns = {"At","Duration","Self","Event","Errors"}, minimum = 760, nameFraction = 0.34 },
    diagnostic = { first = "Detail", columns = {"Value"}, minimum = 440, nameFraction = 0.60 },
    heapDrops = { first = "At", columns = {"Net decrease","Reading interval","Longest frame pause","Slow frames"}, minimum = 680, nameFraction = 0.18 },
    frameGaps = { first = "At", columns = {"Frame gap"}, minimum = 360, nameFraction = 0.35 },
}
local columnHints={
    Calls="Number of recorded calls. More calls mean more repeated work.",
    Total="Time recorded for this operation, including the cost of profiling.",
    Average="Average time per recorded call. Compare the cost of repeated work.",
    Self="Time in this script, excluding other recorded scripts it calls. Ordinary helpers stay included. Equals Inclusive when it calls no other recorded script.",
    Inclusive="Time in this script, including other recorded scripts it calls. Equals Self when it calls none; do not add overlapping totals.",
    Peak="Longest measured call. A large value can interrupt a frame.",
    Errors="Recorded script calls that raised a Lua error.",
    ["Heap delta"]="Shared Lua memory change during recorded calls. Cleanup can make it negative.",
    At="Seconds since recording started. Compare timestamps across tables.",
    Duration="Time for this call, including the cost of profiling.",
    Event="Client event handled by this call. A dash means no event.",
    FPS="FPS sampled once per second; brief stalls can be missed.",
    ["Lua heap"]="Lua memory used by addons and the UI. It does not include all game memory.",
    Latency="Network response delay in milliseconds; it is separate from rendering speed.",
    Memory="The client's last memory reading for this addon, updated manually.",
    ["Heap growth"]="Total shared Lua memory rises during measured calls. * means some calls were not measured. This is not memory owned by the addon; nested calls can overlap.",
    ["Net heap delta"]="Shared Lua memory change during calls; cleanup can make it negative. * means some calls were not measured. This is not addon-owned memory.",
    ["Peak growth"]="Largest shared Lua memory rise during one call. * means some calls were not measured. This is not memory kept by the addon.",
    ["Net decrease"]="Net Lua memory fall between samples. GC can contribute; this is not a confirmed collection event.",
    ["Reading interval"]="Time between the two memory checks; it does not measure how long cleanup took.",
    ["Longest frame pause"]="Longest pause between frames during this reading interval. It includes every cause, not just memory cleanup.",
    ["Slow frames"]="Number of pauses of at least 50 ms between frames during this reading interval.",
    ["Frame gap"]="Time between frames. This list shows pauses of at least 50 ms from any cause, not just addon work.",
    Detail="Diagnostic being checked. Hover its label for its purpose and effect.",
    Value="Observed diagnostic result for this recording.",
}
local firstHints={
    operations="Selected Booty operation being measured.",slow="Selected Booty operation that reached the slow-call threshold.",
    actionBarsOperations="Explicit BootyActionBars entry point. A zero-call row means this registered entry point was not invoked during the recording.",
    callbacks="Addon identified by the script's file. Unknown owner means the file could not be identified.",
    callbackDetails="Related frame scripts grouped together. Expand to see them; a family is not an addon.",
    callbackSlow="Frame script that reached the slow-call threshold.",memory="Addon named by the native memory API.",
    memoryActivity="Addon identified by the recorded script's file. Memory changes during its calls do not measure memory it owns.",
    callbackMemory="Related frame scripts grouped together. Expand to find which calls showed memory growth.",
    loginMemory="Loading stage or addon that reported loaded. Changes since the previous row include other addons and cleanup.",
}
local hints = {
    calls = "Calls to selected Booty operations; nested calls count once. More calls mean more work, not every addon action.",
    total = "Time spent in selected Booty operations. Larger totals mean more measured work; this is not total addon CPU.",
    peak = "Longest measured call. Large peaks can interrupt a frame; timing includes profiler overhead.",
    average = "Measured time per call. Useful for comparing repeated operations.",
    heap = "Shared Lua memory change, including garbage collection. It cannot identify addon ownership or prove a leak.",
    fps = "FPS sampled once per second. A low value shows reduced smoothness; it does not identify the cause.",
    lua = "Lua memory shared by all addons. Drops commonly include garbage collection; no per-addon ownership.",
    latency = "Network response delay. High latency affects responses, separately from FPS.",
    callbacks = "Recorded frame scripts only. More time means more Lua work; a long call can delay a frame.",
    source = "Addon files identify where recorded scripts came from. Scripts without a readable file still appear in frame families.",
    slow = "Calls above the slow threshold. Peaks may interrupt a frame; matching FPS samples does not prove causation.",
}
local sections = {
    operations={title="Booty operations",hint=hints.total,intro="Selected Booty work, ranked by measured time. High Total means repeated Lua work; a large Peak can delay a frame."},
    actionBarsOperations={title="Action Bars operations",expanded=true,hint="Selected BootyActionBars entry points; self time excludes nested watched targets.",intro="Self time excludes nested watched entry points. Ordinary helpers and observer overhead remain included. This is not total addon CPU. Zero-call entry points remain visible."},
    actionBarsCoverage={title="Action Bars capture",expanded=true,hint="Recorded activation, coverage and measurement failures."},
    slow={title="Slow Booty calls",hint=hints.slow,intro="Recent Booty calls lasting at least 5 ms. Large peaks can delay a frame; use the time and event to locate expensive work."},
    callbacks={title="Addon source ranking",hint=hints.source,intro="Recorded work grouped by the addon file it came from. More time means more Lua processing, which can reduce FPS. Some sources cannot be identified."},
    callbackDetails={title="Frame callbacks",hint="Frame scripts grouped by name or parent. A family is not an addon.",intro="Recorded frame scripts grouped into families. Expand to find frequent work or slow calls that may reduce FPS; the frame name does not identify its addon."},
    callbackSlow={title="Slow callbacks",hint=hints.slow,intro="Recent frame-script calls lasting at least 5 ms. Longer calls can delay a frame. Check their time and event; a nearby FPS drop does not prove the cause."},
    memory={title="Memory by addon",hint="Callback memory growth works without native addon counters. Native snapshots are shown separately when available."},
    loginMemory={title="Login results",hint="Loading readings and the short follow-up after entering the world.",intro="Each row compares memory with the previous reading. Its time includes loading and event handling; its memory change includes other addons and cleanup."},
    technical={title="Technical details",hint="Capture coverage, timing reliability and client support."},
    technicalTiming={title="Timing",nested=true,hint="Clocks, measurement precision and invalid readings."},
    technicalCoverage={title="Coverage",nested=true,hint="Which scripts were measured and how much work finding them took."},
    technicalSources={title="Source identification",nested=true,hint="How the profiler identifies the addon behind each script."},
    technicalHealth={title="Capture health",nested=true,hint="Inspection, inventory and wrapper cleanup failures."},
    technicalSupport={title="Client support",nested=true,hint="Available APIs and extension markers; markers alone do not prove support."},
    memoryGC={title="Memory and garbage collection",hint="Shared Lua memory, observed decreases and frame gaps. Decreases do not establish exact GC count or duration."},
    heapDrops={title="Heap drop windows",nested=true,hint="Memory decreases between readings and frame pauses in those intervals. This does not prove cleanup caused a pause."},
    frameGaps={title="Other slow frame gaps",nested=true,hint="Pauses of at least 50 ms not already shown with memory drops. The cause can be game, addon or profiler work."},
}
local sectionIcons={operations="performance",actionBarsOperations="list",actionBarsCoverage="info",slow="stop",callbacks="guild_stats",callbackDetails="groups",callbackSlow="stop",memory="memory",loginMemory="analyze",technical="info",technicalTiming="monitor",technicalCoverage="groups",technicalSources="list",technicalHealth="health",technicalSupport="settings",memoryGC="memory",heapDrops="memory",frameGaps="stop"}
for name,key in pairs(sectionIcons) do sections[name].icon=key end
local liveValues={"calls","count","time","selfTime","timedCalls","peak","failures","memory","maxTime","maxMemory","heapSamples","heapRise","heapDelta","heapPeak","heapUnsupportedCalls"}
local function ShortSource(value)
    value=string.gsub(tostring(value or ""),"[%c]"," ")
    if string.len(value)>160 then value=string.sub(value,1,157).."..." end
    return value
end
local function SourceHint(callbacks,text,category)
    for _,example in ipairs(callbacks and callbacks.sourceExamples or emptyEntries) do
        if example.category==category and example.source then return text.."\nExample: "..ShortSource(example.source) end
    end
    return text
end
local function ScanDate(value)
    if type(value)~="string" then return "Date unavailable" end
    local _,_,year,month,day,hour,minute=string.find(value,"^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d)")
    return year and day.."-"..month.."-"..year.." "..hour..":"..minute or value
end
local function ScanSeconds(value) return tostring(math.max(0,math.floor(tonumber(value) or 0))).."s" end
local function TooltipTitle() return this.reportTitle or "" end
local function TooltipBody()
    return this.reportHint or ""
end
local function FontSize(label,size)
    local applied=size-1+(UI.GetTextSizeDelta(label:GetParent()) or 0)
    local font,_,flags=label:GetFont();label:SetFont(font,applied,flags);return applied
end

function Performance.Create(parent,options)
    options=options or emptyEntries
    local bridge=options.bridge or P.Core.ProfilerBridge.Create(options.standalone)
    local page = UI.CreateContainer(nil, parent)
    page:SetPoint("TOPLEFT", parent, "TOPLEFT", 1.5, -3); page:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -1.5, 1.5); page:Hide()
    page.bodyHost=UI.CreateContainer(nil,page)
    page.canvas = UI.CreateResponsiveCanvas(page.bodyHost, "BootyProfilerPerformanceBody")
    page.header=UI.CreateContainer(nil,page)
    page.title = UI.CreateHeading(page.header, "BootyProfiler", 1, "gold", "performance")
    page.messageHost=UI.CreateContainer(nil,page.bodyHost);page.messageHost:EnableMouse(false)
    page.message = UI.CreateLabel(page.messageHost, nil, "OVERLAY", "GameFontHighlight")
    page.message:SetJustifyH("CENTER");page.message:SetJustifyV("MIDDLE");if page.message.SetWordWrap then page.message:SetWordWrap(true) end
    local module = { frame = page, items = {}, rows = {}, sessionEntries = {}, callbackEntries = {}, callbackDetails = {}, memoryEntries = {}, metricFlow = {}, detailsExpanded = {}, sectionState = {}, snapshots = {}, familyPages = {}, familyPage = 1, callbackView = options.measureMemory and "memory" or "time", measureMemory = options.measureMemory and true or false, loginPage = 1, loginPaging = {}, tableViews={}, tableSorts={}, tableFilters={}, tableRevision=0 }
    function module:HasActionBarsCapture() return Performance.Profiles.IsAvailable(self.provider or P) end
    function module:MatchesSession(session) return Performance.Profiles.Matches(session,self.tab,options.standalone) end
    function module:HasCaptureConflict()
        local state=self.provider and self.provider.GetState()
        return state and state.recording and Performance.Profiles.IsTab(self.tab) and not self:MatchesSession(state.session) and true or false
    end
    function module:HasForeignProfileSession()
        local provider=self.provider or P
        local state=provider and provider.GetState()
        return state and state.session and Performance.Profiles.IsTab(self.tab) and not self:MatchesSession(state.session) and true or false
    end
    function module:GetRows(schema,entries,key,noSort,noFilter)
        local state=not noSort and self.tableSorts[schema]
        local filtered=not noFilter and self.tableFilters[schema] or false
        if not state and not filtered then return entries end
        key=key or schema
        local view=self.tableViews[key]
        if not view then view=Results.Create();self.tableViews[key]=view end
        return Results.Bind(view,entries,schema,state and state.column,state and state.descending,filtered,self.tableRevision)
    end
    function module:InvalidateTables()
        self.tableRevision=self.tableRevision+1
    end
    function module:ClearTableViews()
        for _,view in pairs(self.tableViews) do
            view.source,view.revision=nil,nil
            for index=table.getn(view.rows),1,-1 do table.remove(view.rows,index) end
            for key in pairs(view.order) do view.order[key]=nil end
        end
        self.tableViews={};self:InvalidateTables()
    end
    function module:SortTable(schema,column)
        if self.captureConflict then return false end
        local state=self.tableSorts[schema]
        if state and state.column==column then state.descending=not state.descending
        else self.tableSorts[schema]={column=column,descending=false} end
        self:InvalidateTables();self.familyPage=1;self.familyPages={};self.loginPage=1
        self:Refresh()
    end
    function module:ToggleAddonFilter(schema)
        if self.captureConflict or not Results.CanFilterAddons(schema) then return false end
        self.tableFilters[schema]=not self.tableFilters[schema];self:InvalidateTables()
        if schema=="callbackDetails" or schema=="callbackMemory" then
            self:CancelFamilyJob();self.familyModel=nil;self.familyPage=1;self.familyPages={}
        elseif schema=="loginMemory" then self.loginPage=1 end
        self:Refresh();return true
    end
    module.filterBinding={ensure=function() end,get=function(key) return module.tableFilters[key] end,
        set=function(key,value) if value~=module.tableFilters[key] then module:ToggleAddonFilter(key) end end}
    local scrolled=page.canvas.layoutViewport:GetScript("OnVerticalScroll")
    page.canvas.layoutViewport:SetScript("OnVerticalScroll",function()
        if scrolled then scrolled() end
        if page:IsVisible() then module:LayoutBackground() end
    end)

    local function AddItem(kind, text, data, value, hint)
        module.itemCount = module.itemCount + 1
        local item = module.items[module.itemCount]
        if not item then item = {}; table.insert(module.items, item) end
        item.kind, item.text, item.operation, item.value, item.hint = kind, text, data, value, hint
        item.severity=nil
        item.indent=module.contentIndent or 0
    end
    local function AddMetric(name, value, hint, severity)
        AddItem("metric",name,nil,tostring(value),hint)
        module.items[module.itemCount].severity=severity
    end
    local function AddFilter(name) AddItem("tableFilter","Only addon results",nil,name) end
    local function AddTable(name,filterAdded)
        if not filterAdded then AddFilter(name) end
        AddItem("tableHeader",tables[name].first,tables[name],name)
    end
    local function AddDiagnostic(name,value,hint) AddItem("diagnostic",name,nil,tostring(value or "Unavailable"),hint) end

    function module:IsSectionExpanded(name)
        if name=="technical" then return self.detailsExpanded[self.tab] and true or false end
        local key=self.tab..":"..name
        if self.sectionState[key]==nil then return sections[name].expanded and true or false end
        return self.sectionState[key]
    end
    local function AddSection(name,count)
        local section=sections[name]
        module.contentIndent=section.nested and 1 or 0
        AddItem("section",section.title,name,count,section.hint)
        local expanded=module:IsSectionExpanded(name)
        module.contentIndent=expanded and module.contentIndent+1 or 0
        if expanded and section.intro then AddItem("message",section.intro) end
        return expanded
    end
    function module:SnapshotRows(name,entries,session,history)
        if not self.provider.GetState().recording then return entries end
        local key=self.tab..":"..name
        local snapshot=self.snapshots[key]
        if not snapshot then
            snapshot={rows={},byName={},bindings={}}
            self.snapshots[key]=snapshot
            for _,entry in ipairs(entries) do
                local row={}
                for field,value in pairs(entry) do if type(value)~="table" and type(value)~="function" then row[field]=value end end
                table.insert(snapshot.rows,row);table.insert(snapshot.bindings,entry)
                if entry.name then snapshot.byName[entry.name]=row end
            end
        elseif not history then
            local operations=name=="operations" or name=="actionBarsOperations"
            local updates=operations and entries or snapshot.bindings
            for index,entry in ipairs(updates) do
                local row=operations and snapshot.byName[entry.name] or snapshot.rows[index]
                if row then for _,field in ipairs(liveValues) do row[field]=entry[field] end end
            end
        end
        return snapshot.rows
    end
    local function AddRows(section,kind,entries,session,hint,empty,history,available)
        if not AddSection(section,available or table.getn(entries)) then return end
        AddFilter(section)
        local rows=module:GetRows(section,module:SnapshotRows(section,entries,session,history))
        if table.getn(rows)==0 then
            AddItem("message",empty or "No measurements. Use Update ranking after recording activity.")
            return
        end
        AddTable(section,true)
        for _,entry in ipairs(rows) do
            local title=entry.name or string.format("+%.1f s",entry.sampleAt or entry.at)
            AddItem(kind,title=="Roster refresh" and "Guild refresh" or title,entry)
        end
    end
    function module:HistoryRows(history,limit)
        local entries=self.historyEntries or {};self.historyEntries=entries
        for index=table.getn(entries),1,-1 do table.remove(entries,index) end
        for index=history.count,math.max(1,history.count-limit+1),-1 do table.insert(entries,self.provider.HistoryEntry(history,index)) end
        return entries
    end

    function module:GetSessionOperations()
        local state = self.provider and self.provider.GetState()
        local operations = state and state.session and state.session.operations or self.operationScope and self.operationScope.operations
        local entries, count, calls, total, heap, largest, slowestTime, slowest, timed = self.sessionEntries, 0, 0, 0, 0, 0, 0, nil, 0
        local name, operation
        if operations then
        for name, operation in pairs(operations) do
            calls, total, heap = calls + (operation.count or 0), total + (operation.time or 0), heap + (operation.memory or 0)
            timed=timed+(operation.timedCalls or operation.count or 0)
            if (operation.maxMemory or 0) > largest then largest = operation.maxMemory end
            if (operation.maxTime or 0) > slowestTime then slowestTime, slowest = operation.maxTime, name end
            if count < 128 then
                count = count + 1
                local entry = entries[count]
                if not entry then entry = {}; table.insert(entries, entry) end
                entry.name, entry.count, entry.time, entry.memory = name, operation.count or 0, operation.time or 0, operation.memory
                entry.maxTime, entry.maxMemory = operation.maxTime or 0, operation.maxMemory or 0
                entry.timedCalls,entry.failures=operation.timedCalls,operation.failures
            end
        end
        end
        for index = table.getn(entries), count + 1, -1 do table.remove(entries, index) end
        table.sort(entries, CompareTime)
        return calls, total, heap, largest, slowest, entries, slowestTime, timed
    end

    function module:CancelFamilyJob()
        page:SetScript("OnUpdate",nil)
        self.familyJob=nil;self.familyPending=nil
    end
    local function FamilyTick()
        local job=module.familyJob
        if not job then page:SetScript("OnUpdate",nil);return end
        if not page:IsVisible() or module.tab~="All Addons" or not module:IsSectionExpanded("callbackDetails") then
            module:CancelFamilyJob();return
        end
        local api=module.provider.CallbackFamilies
        local complete
        if job.phase=="sync" then
            if api.Sync(job.model,128) then api.BeginUpdate(job.model);job.phase="update" end
        elseif job.phase=="update" then
            if api.UpdateStep(job.model,128) then
                if job.build then api.BeginSort(job.model);job.phase="sort" else complete=true end
            end
        elseif job.phase=="sort" then complete=api.SortStep(job.model,1024) end
        if complete then
            local model=job.model
            module:CancelFamilyJob();module.familyModel=model
            module.familyUpdateReady=true;module:Refresh();module.familyUpdateReady=nil
        end
    end
    function module:QueueFamilyJob(model,phase,build)
        self.familyJob={model=model,phase=phase,build=build}
        if build then self.familyPending=model end
        page:SetScript("OnUpdate",FamilyTick)
    end
    function module:BuildFrameFamilies(callbacks,live)
        for index=table.getn(self.callbackDetails),1,-1 do table.remove(self.callbackDetails,index) end
        local api=self.provider.CallbackFamilies
        if not api then AddItem("message","Update BootyProfiler to view frame families.");return end
        local schema=self.callbackView=="memory" and "callbackMemory" or "callbackDetails"
        AddFilter(schema)
        local model=self.familyModel
        if not model then
            if not self.familyPending then
                model=api.Create(self:GetRows(schema,callbacks.operations or emptyEntries,"familyInput",true),self.callbackView=="memory" and "heapRise" or nil)
                if model.total<=128 then api.Sync(model,128);api.Update(model);api.Sort(model);self.familyModel=model
                else self:QueueFamilyJob(model,"sync",true) end
            end
            model=self.familyModel
        elseif live and not self.familyJob and not self.familyUpdateReady then
            if model.total<=128 then api.Update(model)
            else api.BeginUpdate(model);self:QueueFamilyJob(model,"update",false) end
        end
        if not model then AddItem("message","Preparing frame families...");return end
        local families=self:GetRows(schema,model.families,"families",false,true)
        local total=table.getn(families)
        if total==0 then AddItem("message","No frame callbacks captured.");return end
        self.familyPage=math.max(1,math.min(self.familyPage,math.ceil(total/FAMILY_PAGE_SIZE)))
        local first=(self.familyPage-1)*FAMILY_PAGE_SIZE+1
        if total>FAMILY_PAGE_SIZE then AddItem("familyPager",string.format("Families %d-%d / %d",first,math.min(total,first+FAMILY_PAGE_SIZE-1),total),model) end
        AddTable(schema,true)
        for index=first,math.min(total,first+FAMILY_PAGE_SIZE-1) do
            local family=families[index]
            local expanded=self.expandedFamily==family.name
            AddItem("family",(expanded and "- " or "+ ")..family.name.." ("..family.count..")",family,family.name)
            if expanded then
                self.contentIndent=self.contentIndent+1
                local childPage=math.max(1,math.min(self.familyPages[family.name] or 1,math.ceil(family.count/FAMILY_PAGE_SIZE)))
                self.familyPages[family.name]=childPage
                local childFirst=(childPage-1)*FAMILY_PAGE_SIZE+1
                if family.count>FAMILY_PAGE_SIZE then
                    AddItem("familyPager",string.format("Scripts %d-%d / %d",childFirst,math.min(family.count,childFirst+FAMILY_PAGE_SIZE-1),family.count),model,family.name)
                    AddTable(self.callbackView=="memory" and "callbackMemory" or "callbackDetails")
                end
                local children=self:GetRows(schema,family.children,"children",false,true)
                for child=childFirst,math.min(family.count,childFirst+FAMILY_PAGE_SIZE-1) do
                    local entry=children[child]
                    table.insert(self.callbackDetails,entry);AddItem("callbackDetail",entry.name,entry)
                end
                self.contentIndent=self.contentIndent-1
            end
        end
    end
    function module:ToggleFamily(name)
        self.expandedFamily=self.expandedFamily~=name and name or nil;self:Refresh()
    end
    function module:SetFamilyPage(name,direction)
        if name then self.familyPages[name]=math.max(1,(self.familyPages[name] or 1)+direction)
        else self.familyPage=math.max(1,self.familyPage+direction) end
        self:Refresh()
    end
    function module:BuildCallbackItems(callbacks,session)
        for index=table.getn(self.callbackDetails),1,-1 do table.remove(self.callbackDetails,index) end
        local entries,count=self.callbackEntries,0
        local previousCount=table.getn(entries)
        local live=self.provider.GetState().recording and not session.stopped
        local rankSources=not live or self:IsSectionExpanded("callbacks") and not self.snapshots[self.tab..":callbacks"]
        if not rankSources then count=previousCount
        elseif callbacks.addons then
            for _,entry in ipairs(callbacks.addons) do
                if count<256 then
                    count=count+1
                    if count<=previousCount then entries[count]=entry else table.insert(entries,entry) end
                end
            end
        end
        for index=table.getn(entries),count+1,-1 do table.remove(entries,index) end
        if rankSources then table.sort(entries,CompareCallbackTime) end
        if AddSection("callbackDetails",table.getn(callbacks.operations or emptyEntries)) then
            if callbacks.operationsTruncated then AddItem("message","Frame list limit reached; callback totals still include later calls.") end
            self:BuildFrameFamilies(callbacks,live)
        end
        AddRows("callbacks","callback",entries,session,hints.source.."\n"..hints.callbacks,"No identified addon sources yet.",false,table.getn(callbacks.addons or emptyEntries))
        if callbacks.history then
            AddRows("callbackSlow","callbackSlow",self:HistoryRows(callbacks.history,64),session,hints.slow,"No callbacks reached the slow threshold.",true)
        end
    end

    local function AddMemoryHistory(section,kind,history,session,empty)
        if module:IsSectionExpanded(section) then
            AddRows(section,kind,module:HistoryRows(history,64),session,nil,empty,true)
        else AddSection(section,history.count or 0) end
    end
    function module:BuildMemoryItems(session)
        local gc,gaps=session.gc or {},session.frameGaps or {}
        if AddSection("memoryGC") then
            AddMetric("Memory / GC",Memory(session.heap).." / "..Memory(session.gcThreshold),"Current shared Lua memory / current collection threshold. Includes addons and UI; not total game RAM.")
            AddMetric("Change since Start",session.heap and session.startHeap and SignedMemory(session.heap-session.startHeap) or "Unavailable","Current shared Lua memory minus the first sample. A negative value includes memory reclaimed between samples.")
            AddMetric("Observed heap drops",gc.heapDropCount or 0,"Memory samples with a net decrease. This can miss or combine collections; it is not an exact GC counter.")
            AddMetric("Last heap drop",gc.lastHeapDrop and Memory(gc.lastHeapDrop) or "-","Last memory decrease between readings. Open Heap drop windows to compare pauses in that interval.")
            AddMetric("Longest frame pause",gaps.maximum and Duration(gaps.maximum) or "-","Largest observed interval between frames, from any cause. This is not the time spent in garbage collection.")
            if gc.history then AddMemoryHistory("heapDrops","heapDrop",gc.history,session,"No net memory decreases observed.") end
            if gaps.history then
                local frozen=self.snapshots[self.tab..":frameGaps"]
                if self:IsSectionExpanded("frameGaps") then
                    local other=self.otherFrameGaps or {};self.otherFrameGaps=other
                    if not frozen or session.stopped then
                        for index=table.getn(other),1,-1 do table.remove(other,index) end
                        local dropHistory=gc.history
                        local dropIndex=dropHistory and dropHistory.count or 0
                        local dropFirst=math.max(1,dropIndex-63)
                        local drop=dropIndex>=dropFirst and self.provider.HistoryEntry(dropHistory,dropIndex) or nil
                        for index=gaps.history.count,math.max(1,gaps.history.count-63),-1 do
                            local gap=self.provider.HistoryEntry(gaps.history,index)
                            local at=gap.sampleAt
                            while at and drop and at<=drop.windowStart do
                                dropIndex=dropIndex-1
                                drop=dropIndex>=dropFirst and self.provider.HistoryEntry(dropHistory,dropIndex) or nil
                            end
                            if not at or not drop or at>drop.windowEnd then table.insert(other,gap) end
                        end
                    end
                    AddRows("frameGaps","frameGap",other,session,nil,"No other retained frame gaps reached 50 ms.",true)
                else
                    AddSection("frameGaps",frozen and table.getn(frozen.rows) or nil)
                end
            end
        end
    end

    function module:BuildAddonMemoryItems(session,state)
        local callbacks=session and session.callbacks
        local native=state.addonEntries or emptyEntries
        local activity=callbacks and callbacks.memoryRequested and callbacks.memoryAvailable
        if not activity and table.getn(native)==0 then return end
        local available=activity and table.getn(callbacks.addons or emptyEntries) or table.getn(native)
        if not AddSection("memory",available) then return end
        if activity then
            if (callbacks.heapUnsupportedCalls or 0)>0 then AddItem("message","Memory coverage is partial. * marks totals with unmeasured calls.") end
            local entries=self.memoryEntries
            local frozen=state.recording and self.snapshots[self.tab..":memoryActivity"]
            if not frozen then
                for index=table.getn(entries),1,-1 do table.remove(entries,index) end
                for index=1,math.min(256,table.getn(callbacks.addons or emptyEntries)) do table.insert(entries,callbacks.addons[index]) end
                table.sort(entries,CompareHeapRise)
            end
            AddFilter("memoryActivity")
            local rows=self:GetRows("memoryActivity",self:SnapshotRows("memoryActivity",entries,session,false))
            if table.getn(rows)>0 then
                AddTable("memoryActivity",true)
                for _,entry in ipairs(rows) do AddItem("memoryActivity",entry.name,entry) end
            else AddItem("message","No callback memory samples yet. Use Update ranking after activity.") end
        else
            AddItem("message",callbacks and callbacks.memoryRequested and "This capture could not read callback memory." or "Memory: ON, then Start in All Addons to measure callback memory growth.")
        end
        if table.getn(native)>0 then
            AddItem("heading","Client memory snapshot")
            AddTable("memory")
            for _,entry in ipairs(self:GetRows("memory",native)) do AddItem("memory",entry.name,entry) end
        end
    end

    local loginStages={BASELINE="Profiler loaded",VARIABLES_LOADED="Saved variables ready",PLAYER_LOGIN="Player login",PLAYER_ENTERING_WORLD="Entered world",SETTLE_SAMPLE="After entering world"}
    local loginReasons={ ["logout-before-settle"]="Logged out before completion",["user-cancelled"]="Cancelled by user",["capture-driver-hidden"]="Capture interrupted",["clock-or-heap-api-unavailable"]="Clock or memory API unavailable",["clock-unavailable-or-invalid"]="Invalid client clock",["heap-unavailable-or-invalid"]="Invalid memory reading",["invalid-frame-elapsed"]="Invalid frame interval" }
    function module:BuildLoginItems()
        local capture=self.provider.LoginMemory
        if not capture then return end
        local report=capture.GetReport()
        local count=report and table.getn(report.events or emptyEntries) or 0
        if not report then AddItem("message",capture.IsArmed() and "Capture ready for the next login or reload." or "Use Analyze Login to record the next loading sequence.");return end
        if self.loginReport~=report then self.loginReport=report;self.loginPage=1;self:InvalidateTables() end
        if self.loginEventCount~=count or self.loginKind~=report.kind then
            self.loginEventCount,self.loginKind=count,report.kind;self:InvalidateTables()
        end
        local status=report.kind=="completed" and "Success" or report.kind=="recording" and "Recording" or report.kind=="failed" and "Failed" or report.kind=="cancelled" and "Cancelled" or "Interrupted"
        if report.kind=="recording" and report.settleRemaining then status="Settling: "..Seconds(report.settleRemaining).." left" end
        AddMetric("Login capture",status,"Success means addon loading and the follow-up readings finished.")
        AddMetric("Login date",ScanDate(report.capturedDate),"Local date and time when this requested login capture began.")
        AddMetric("Login time",Seconds(report.firstWorldAt),"Time from capture start to entering the world. The follow-up readings are excluded.")
        AddMetric("Memory usage before capture",Memory(report.startHeap),"Shared Lua memory when this capture began.")
        AddMetric("Memory usage on login",Memory(report.heap),"Shared Lua memory at the latest loading or follow-up reading.")
        AddMetric("Change during login",SignedMemory(report.heapDelta),"Latest login sample minus the profiler-load baseline. Includes startup work and collection.")
        AddMetric("Observed login heap drops",report.heapDropCount or 0,"Loading windows with a net memory decrease. Collection may contribute; this is not an exact GC event count.")
        if report.baselineInventoryAvailable then
            local incomplete=report.baselineInventoryTruncated or (report.baselineInventoryFailures or 0)>0
            AddMetric("Addons loaded before capture",(incomplete and "At least " or "")..tostring(report.baselineLoadedAddonCount or 0),"Addons loaded before the profiler began measuring. Their loading is not recorded.")
        elseif report.baselineInventoryAvailable==false then
            AddMetric("Addons loaded before capture","Unavailable","The starting addon list was unavailable; later loads are still recorded.")
        end
        AddMetric("Later addon loads",report.addonEvents or 0,"Addon-loaded events after the baseline, including omitted rows.")
        if report.kind~="completed" and report.reason then AddItem("message","Capture stopped: "..(loginReasons[report.reason] or report.reason)) end
        if report.truncated then AddItem("message","Omitted loading rows: "..tostring(report.omittedRecords or 0)) end
        local rows=self:GetRows("loginMemory",report.events or emptyEntries)
        count=table.getn(rows)
        if not AddSection("loginMemory",count) then return end
        AddFilter("loginMemory")
        if count==0 then AddItem("message","No loading rows recorded.");return end
        self.loginPage=math.max(1,math.min(self.loginPage,math.ceil(count/FAMILY_PAGE_SIZE)))
        local first=(self.loginPage-1)*FAMILY_PAGE_SIZE+1
        self.loginPaging.total=count
        if count>FAMILY_PAGE_SIZE then AddItem("loginPager",string.format("Stages %d-%d / %d",first,math.min(count,first+FAMILY_PAGE_SIZE-1),count),self.loginPaging) end
        AddTable("loginMemory",true)
        for index=first,math.min(count,first+FAMILY_PAGE_SIZE-1) do
            local entry=rows[index]
            AddItem("loginMemory",entry.event=="ADDON_LOADED" and entry.addon and "Loaded: "..entry.addon or loginStages[entry.event] or entry.event,entry)
        end
    end

    function module:BuildTechnicalItems(session)
        local callbacks=session.callbacks
        if AddSection("technicalTiming") then
            AddFilter("diagnostic")
            AddDiagnostic("Booty clock",session.clock,"Timer used for Booty calls. Very short calls may round to zero.")
            AddDiagnostic("Clock precision","Not verified","The timer's smallest reliable unit has not been verified in this client.")
            AddDiagnostic("Scope","Selected Booty operations",hints.total)
            if self.tab=="All Addons" then
                AddDiagnostic("FPS sampling","1 per second",hints.fps)
                AddDiagnostic("Memory API",session.capabilities and session.capabilities.addonMemory and "Per-addon available" or "Shared Lua only",hints.lua)
            end
            if callbacks and self.tab=="All Addons" then
                AddDiagnostic("Callback clock",ClockName(callbacks.clock),"Timer used for script calls. Recorded time includes the cost of profiling.")
                AddDiagnostic("Smallest observed clock gap",ClockGap(callbacks.clockMinPositiveDelta),"Shortest gap seen between timer reads. It does not prove timer precision.")
                AddDiagnostic("Zero-duration calls",callbacks.zeroDurations or 0,"Calls with a zero timer reading. Very short calls can round to zero; zero does not mean no work.")
                AddDiagnostic("Invalid timings",callbacks.timingFailures or 0,"Calls counted but omitted from time totals because their timer readings were invalid.")
                AddDiagnostic("Clock read failures",callbacks.clockReadFailures or 0,"Failed timer reads. These calls cannot contribute a measured duration.")
                AddDiagnostic("Callback memory",callbacks.memoryRequested and (callbacks.memoryAvailable and "Measured" or "Unavailable") or "Off","Memory checks before and after script calls. They show shared memory change, not memory owned by the script.")
                AddDiagnostic("Memory read failures",callbacks.heapReadFailures or 0,"Failed memory checks. Script calls and valid time readings are still recorded.")
                AddDiagnostic("Metric failures",callbacks.metricFailures or 0,"Measurement results that could not be recorded.")
                AddDiagnostic("Clock baseline",ClockGap(callbacks.overhead),"Cost of reading the timer alone; it does not measure the full cost of profiling.")
            end
        end
        if callbacks and self.tab=="All Addons" then
            if AddSection("technicalCoverage") then
                AddFilter("diagnostic")
                AddDiagnostic("Callback frames",callbacks.discovered or 0,"Frames found with event or per-frame scripts. The profiler does not measure every addon function.")
                AddDiagnostic(session.stopped and "Hooks at Stop" or "Active hooks",callbacks.activeHookedAtStop or callbacks.hooked or 0,"Script callbacks set up for measurement. Only recorded calls appear in the ranking.")
                AddDiagnostic("Unknown-source hooks",callbacks.unknownAtStop or callbacks.unknown or 0,"Measured scripts whose addon file could not be identified. Their calls still appear in frame families.")
                AddDiagnostic("Callbacks wrapped",callbacks.everHooked or 0,"Total script callbacks set up for measurement. Replacing a script can increase this count.")
                if callbacks.fastCalls~=nil then
                    AddDiagnostic("Optimized / compatibility calls",tostring(callbacks.fastCalls).." / "..tostring(callbacks.genericCalls or 0),"First: measurements without temporary argument storage. Second: a compatibility method that preserves the script's inputs and results but adds memory work.")
                    AddDiagnostic("Unmeasured memory calls",callbacks.heapUnsupportedCalls or 0,"Calls whose memory checks were skipped because temporary profiling storage would distort the result.")
                end
                local discovery=callbacks.available==false and "Unavailable" or callbacks.pending and not session.stopped and "In progress" or callbacks.truncated and "Limit reached" or callbacks.firstScanComplete and "Initial scan complete" or session.stopped and "Stopped before first scan" or "Incomplete"
                AddDiagnostic("Discovery",discovery,"Progress finding scripts to measure. Calls before a script is found are not recorded.")
                AddDiagnostic("Completed sweeps",callbacks.scans or 0,"Full checks for new or replaced frame scripts.")
                AddDiagnostic("Discovery time",Duration(callbacks.discoveryTime),"Time the profiler spent finding scripts, separate from the scripts' own work.")
                AddDiagnostic("Frame visits",callbacks.scanned or 0,"Frame checks performed. The same frame can be checked more than once.")
                AddDiagnostic("Visits without callbacks",callbacks.inertSkipped or 0,"Frames checked that had no scripts to measure. They use no script-record slots.")
                AddDiagnostic("Script replacements",callbacks.replacements or 0,"Scripts changed by addons and found again by the profiler.")
                AddDiagnostic("Known scripts skipped",callbacks.skippedKnown or 0,"Client and profiler scripts deliberately left out of addon rankings.")
            end
            if AddSection("technicalSources") then
                AddFilter("diagnostic")
                local debugReads,dumpReads=callbacks.sourceDebug or 0,callbacks.sourceDump or 0
                local lookup=debugReads>0 and (dumpReads>0 and "Debug + bytecode" or "Debug metadata") or dumpReads>0 and "Lua 5.0 bytecode" or "None succeeded"
                AddDiagnostic("Source lookup",lookup,"Method used to read script file names and identify their addons.")
                AddDiagnostic("Debug metadata reads",debugReads,"Script file names read through a client debug API.")
                AddDiagnostic("Bytecode source reads",dumpReads,"Script file names read from Lua function data. An addon file name is needed to identify the addon.")
                AddDiagnostic("Source unavailable",callbacks.sourceUnavailable or 0,"Scripts with no readable file name. Their time still appears in frame families.")
                AddDiagnostic("Dump rejected",callbacks.sourceDumpRejected or 0,SourceHint(callbacks,"The client refused access to this function's data. Its file name could not be read this way.","dump-rejected"))
                AddDiagnostic("Unsupported dump",callbacks.sourceUnsupportedDump or 0,SourceHint(callbacks,"Function data had a format or size the profiler could not read.","unsupported-dump"))
                AddDiagnostic("Missing source API",callbacks.sourceApiUnavailable or 0,SourceHint(callbacks,"The client offered no working way to read this script's file name.","no-source-api"))
                AddDiagnostic("XML-shaped script labels",callbacks.sourceFrameScripts or 0,SourceHint(callbacks,"Labels identify a frame and script but give no addon file name.","frame-script"))
                AddDiagnostic("Other non-file sources",math.max(0,(callbacks.sourceNonFile or 0)-(callbacks.sourceFrameScripts or 0)),SourceHint(callbacks,"Script labels give no verified addon file. Their calls still appear in frame families.","code-chunk"))
                AddDiagnostic("Folder not in inventory",callbacks.sourceUnmatchedFolder or 0,SourceHint(callbacks,"The script's folder was not found in the installed addon list.","folder-unmatched"))
                AddDiagnostic("Installed addon folders",callbacks.inventoryCount or 0,"Addon folders checked against script file names to identify their source.")
            end
            if AddSection("technicalHealth") then
                AddFilter("diagnostic")
                AddDiagnostic("Inventory read failures",callbacks.inventoryReadFailures or 0,"Failed addon-list reads that can prevent a script's addon from being identified.")
                AddDiagnostic("Inspection failures",callbacks.inspectionFailures or 0,"Frames whose script settings could not be read.")
                AddDiagnostic("Source failures",callbacks.sourceFailures or 0,"Errors reading script file names while finding callbacks.")
                AddDiagnostic("Restore failures",callbacks.restoreFailures or 0,"Script measurements could not be fully detached. Reload before profiling other addons again.")
                AddDiagnostic("Depth-limit skips",callbacks.depthSkipped or 0,"Calls nested beyond the profiler's safety limit. They still run but their work is not measured.")
            end
        end
        if AddSection("technicalSupport") then
            AddFilter("diagnostic")
            AddDiagnostic("BootyProfiler",self.provider.version)
            local capabilities=session.capabilities or {}
            AddDiagnostic("Runtime",capabilities.lua or "Not identified","Lua version reported by the client. Measurement features are checked separately.")
            AddDiagnostic("Lua heap",capabilities.heap and "Available" or "Unavailable",hints.lua)
            AddDiagnostic("ClassicAPI",capabilities.classicAPIVersion or capabilities.classicAPI and "Present" or "Absent","Client extension detected. Its measurement features are checked separately.")
            AddDiagnostic("SuperAPI",capabilities.superAPI and "Present" or "Absent","Client extension detected. Its measurement features are checked separately.")
            AddDiagnostic("SuperWoW",capabilities.superwow or "Absent","Client extension detected. Its measurement features are checked separately.")
            AddDiagnostic("Nampower",capabilities.nampower or "Absent","Client extension detected. Its measurement features are checked separately.")
        end
    end

    function module:BuildHealthItems(state)
        local report=self.provider.GetLastHealthReport and self.provider.GetLastHealthReport()
        self.healthReport,self.healthRecording=report,state.recording
        if not report or not report.available then
            AddItem("message",state.recording and "A scan is recording. Stop it to create a Health Check report." or "No completed scan. Choose Profile Booty or Profile All, record activity, then Stop.")
            return
        end
        if state.recording then AddItem("message","A scan is recording. This report shows the previous completed scan.") end
        AddMetric("Health",report.status,report.summary,report.severity or 0)
        AddMetric("Profile",report.scope or "Unavailable","The profile used for this completed scan.")
        AddMetric("Last scan",ScanDate(report.date),"Local date and time when the scan began.")
        if report.summary then AddItem("message",report.summary) end
        for _,finding in ipairs(report.findings or emptyEntries) do
            AddItem("heading",finding.title)
            self.items[self.itemCount].severity=finding.severity
            self.contentIndent=1
            if finding.evidence then AddItem("healthDetail","Evidence",nil,(string.gsub(finding.evidence,"^Roster refresh:","Guild refresh:"))) end
            if finding.reason then AddItem("healthDetail","Reason",nil,finding.reason) end
            if finding.action then AddItem("healthDetail","Tip",nil,finding.action) end
            self.contentIndent=0
        end
    end

    local function StateValue(value)
        if value==true then return "Yes" elseif value==false then return "No" end
        return value~=nil and tostring(value) or "Unavailable"
    end
    local function AddCapturedState(label,captured)
        local fields={{"Active","active"},{"Requested","requested"},{"Event subscriptions","subscribed"},
            {"Frames initialized","framesInitialized"},{"Product stopped","runtimeStopped"},{"Setting enabled","settingsEnabled"},
            {"Configured extra bars","customConfiguredCount"},{"Visible extra bars","customActiveCount"}}
        for _,field in ipairs(fields) do AddDiagnostic(label..": "..field[1],StateValue(captured and captured[field[2]]),"Product state recorded at the capture boundary; this is not a live frame inspection.") end
    end
    function module:BuildActionBarsItems(session)
        local calls,total,_,_,_,entries,peak,timed=self:GetSessionOperations()
        local measured=calls==0 or timed>0
        AddMetric("Measured calls",calls,"Calls to registered BootyActionBars entry points. This is not every addon or client call.")
        AddMetric("Timed calls",timed,"Calls with a valid measured duration. Missing timings remain counted separately.")
        AddMetric("Measured self time",measured and Duration(total) or "Unavailable","Time excluding nested watched entry points, including ordinary helpers and observer overhead; not total addon CPU.")
        AddMetric("Average self time",measured and Duration(timed>0 and total/timed or 0) or "Unavailable","Average self time across calls with valid timings.")
        AddMetric("Peak self time",measured and Duration(peak) or "Unavailable","Longest measured self time; excludes nested watched entry points.")
        AddMetric("Average FPS",FPS(session.averageFps),hints.fps)
        AddMetric("FPS min / max",FPS(session.minFps).." / "..FPS(session.maxFps),"Sampled once per second. These game-wide readings do not establish causal addon impact.")
        local heap=session.endHeap or session.heap
        AddMetric("Shared Lua heap",Memory(heap),hints.lua)
        AddMetric("Change since Start",type(heap)=="number" and type(session.startHeap)=="number" and SignedMemory(heap-session.startHeap) or "Unavailable",hints.heap)
        AddItem("message","Per-call memory is not measured in this profile. Shared Lua heap includes every addon and the UI.")
        if AddSection("actionBarsOperations",table.getn(entries)) then
            local rows=self:GetRows("actionBarsOperations",self:SnapshotRows("actionBarsOperations",entries,session,false))
            AddTable("actionBarsOperations",true)
            for _,entry in ipairs(rows) do AddItem("actionBarsOperation",entry.name,entry,nil,"Explicitly registered entry point. Self time excludes nested watched targets; ordinary helpers and observer overhead remain included. No per-call memory measurement.") end
        end
        if AddSection("actionBarsCoverage") then
            local metadata=session.profileMetadata or emptyEntries
            AddDiagnostic("Coverage",metadata.coverage or session.coverage,"Only explicitly registered Action Bars entry points are timed. Native work and unrelated callbacks are outside this scope.")
            AddDiagnostic("Timing clock",ClockName(metadata.clock),"Clock reported by the selected-operation observer; separate from the session timeline clock.")
            AddDiagnostic("Product version",metadata.productVersion or metadata.start and metadata.start.productVersion,"Version recorded by the Action Bars source.")
            AddDiagnostic("Registered entry points",metadata.targetCount or metadata.start and metadata.start.targetCount or table.getn(entries),"The bounded set registered for this capture. Zero-call entries remain in the table.")
            AddCapturedState("Start",metadata.start)
            if session.stopped then AddCapturedState("Stop",metadata["end"]) end
            for _,field in ipairs({{"Clock read failures","clockReadFailures"},{"Clock probe failures","clockProbeFailures"},{"Invalid timings","timingFailures"},
                {"Observer failures","observerFailures"},{"Restore failures","restoreFailures"},{"Replaced targets","replacedTargets"},{"Depth-skipped calls","depthSkipped"}}) do
                AddDiagnostic(field[1],StateValue(metadata[field[2]]),"Recorded observer coverage or cleanup failures. Invalid timings do not contribute to duration totals.")
            end
            AddDiagnostic("Partial coverage",StateValue(metadata.partial),"Whether the source reported incomplete capture or cleanup coverage.")
            AddDiagnostic("Targets changed",StateValue(metadata.targetsChanged),"Whether the source reported that its registered target set changed during the capture.")
            AddDiagnostic("Bar setup changed",StateValue(metadata.configurationChanged),"Whether any bar was moved or scaled, its columns or spacing changed, its title/key/count labels toggled, or extra bars were added, removed or individually shown/hidden during recording. Finish editing the bars before starting a comparison.")
            if session.stopped then
                AddDiagnostic("Wrappers restored",StateValue(metadata.restored),"Whether the source restored its temporary wrappers after Stop.")
                AddDiagnostic("Restoration blocked",StateValue(metadata.restorationBlocked),"A replaced entry point may prevent safe restoration; the profiler does not overwrite a foreign replacement.")
            end
        end
        self.contentIndent=0
    end
    function module:BuildItems()
        self.itemCount=0;self.contentIndent=0
        local state=self.provider.GetState()
        local session=state.session
        if self.snapshotSession~=session or self.snapshotRecording~=state.recording then
            self.snapshots={};self.snapshotSession=session;self.snapshotRecording=state.recording
            self:ClearTableViews()
            self:CancelFamilyJob();self.familyModel=nil
            for _,entries in ipairs({self.sessionEntries,self.callbackEntries,self.callbackDetails,self.memoryEntries,self.historyEntries or emptyEntries,self.otherFrameGaps or emptyEntries}) do
                for index=table.getn(entries),1,-1 do table.remove(entries,index) end
            end
        end
        if self.tab=="Analyze Login" or self.tab=="Health Check" then
            if self.tab=="Analyze Login" then self:BuildLoginItems() else self:BuildHealthItems(state) end
            for index=table.getn(self.items),self.itemCount+1,-1 do table.remove(self.items,index) end
            return
        end
        if not session or not session.callbacks then
            self:CancelFamilyJob();self.familyModel=nil
            for index=table.getn(self.callbackEntries),1,-1 do table.remove(self.callbackEntries,index) end
            for index=table.getn(self.callbackDetails),1,-1 do table.remove(self.callbackDetails,index) end
        end
        if self.captureConflict then
            for index=table.getn(self.items),1,-1 do table.remove(self.items,index) end
            return
        end
        local compatible=self:MatchesSession(session)
        local health=compatible and session.health
        local healthHint=health and health.reason or "Start this profile to check FPS, latency and memory."
        if health and session.stopped then healthHint="Recorded result. "..healthHint end
        AddMetric("Health check",health and health.status or compatible and "Checking" or "No capture",healthHint,health and health.severity or 0)
        if not session then
            for index=table.getn(self.sessionEntries),1,-1 do table.remove(self.sessionEntries,index) end
            for index=table.getn(self.historyEntries or emptyEntries),1,-1 do table.remove(self.historyEntries,index) end
            AddItem("message","Press Start, use the addon, then Stop to inspect results.")
        elseif not compatible then
            AddItem("message",state.recording and "Another profile is recording. Stop it before starting this profile." or "No scan for this profile. Press Start to record it.")
        elseif self.tab=="Action Bars" then
            self:BuildActionBarsItems(session)
        elseif self.tab=="MOS" then
            local calls,total,heap,_,_,entries,peak=self:GetSessionOperations()
            AddMetric("Measured calls",calls,hints.calls);AddMetric("Measured time",Duration(total),hints.total)
            AddMetric("Peak call time",calls>0 and Duration(peak) or "-",hints.peak);AddMetric("Average call time",calls>0 and Duration(total/calls) or "-",hints.average)
            AddMetric("Heap delta during Booty calls",SignedMemory(heap),hints.heap)
            self:BuildMemoryItems(session)
            AddRows("operations","operation",entries,session,hints.total.."\n"..hints.heap,"No displayed Booty calls. Use Update ranking after activity.")
            AddRows("slow","slow",self:HistoryRows(session.history,64),session,hints.slow.."\n"..hints.heap,"No Booty calls reached 5 ms.",true)
        elseif not session.callbacksRequested then
            AddItem("message",state.recording and "Another profile is recording. Stop it before starting this profile." or "No scan for this profile. Press Start to record it.")
        else
            AddMetric("FPS min / max",FPS(session.minFps).." / "..FPS(session.maxFps),"Lowest and highest valid once-per-second FPS readings in the whole session. Brief stalls can fall between readings.")
            AddMetric("Average FPS",FPS(session.averageFps),"Average of all valid FPS readings in this scan.")
            AddMetric("Latency min / max",Latency(session.minLatency).." / "..Latency(session.maxLatency),"Lowest and highest valid network-delay readings over the whole session.")
            AddMetric("Average latency",Latency(session.averageLatency),"Mean of valid network-delay readings over the whole session. This is separate from rendering speed.")
            AddMetric("Last latency",Latency(session.latency),"Last recorded network response delay. High delay can slow server responses, separately from FPS.")
            self:BuildMemoryItems(session)
            if session.callbacks then
                local callbacks=session.callbacks
                self:BuildCallbackItems(callbacks,session)
            else
                AddItem("message","Callbacks were not recorded. Start from All Addons to measure frame scripts.")
            end
        end
        if self.tab=="All Addons" and (not session or session.callbacksRequested) then
            self:BuildAddonMemoryItems(session,state)
        end
        if compatible and self.tab~="Action Bars" and (self.tab=="MOS" or session.callbacksRequested) and AddSection("technical") then self:BuildTechnicalItems(session) end
        for index=table.getn(self.items),self.itemCount+1,-1 do table.remove(self.items,index) end
    end
    local function EnsureRow(index)
        local row = module.rows[index]
        if row then return row end
        row = UI.CreateControl(nil,page.canvas)
        row.label=UI.CreateLabel(row,nil,"OVERLAY","GameFontHighlightSmall")
        row.detail=UI.CreateLabel(row,nil,"OVERLAY","GameFontHighlightSmall")
        row.columns, row.values = {}, {}
        for column=1,5 do row.columns[column]=UI.CreateLabel(row,nil,"OVERLAY","GameFontHighlightSmall") end
        for _,label in ipairs({row.label,row.detail}) do
            label:SetJustifyH("LEFT");if label.SetWordWrap then label:SetWordWrap(true) end
            if label.SetNonSpaceWrap then label:SetNonSpaceWrap(true) end
        end
        UI.StyleSelectableTableRow(row,false,false)
        local hoverEnter=row:GetScript("OnEnter")
        UI.AttachTooltip(row,TooltipTitle,TooltipBody)
        local tooltipEnter=row:GetScript("OnEnter")
        row:SetScript("OnEnter",function() if this.reportHint then tooltipEnter() elseif hoverEnter then hoverEnter() end end)
        table.insert(module.rows,row);return row
    end
    local function ResetRow(row,item,width)
        row.mosTableRowHover:SetAlpha(0.07)
        row:SetWidth(width);row.label:ClearAllPoints();row.label:SetPoint("TOPLEFT",row,"TOPLEFT",8,-6)
        row.label:SetWidth(math.max(1,width-16));row.label:SetHeight(0);FontSize(row.label,11);row.label:SetJustifyV("TOP")
        row.label:SetText(item.text);row.label:SetTextColor(1,1,1);row.label:Show()
        row.detail:Hide();for column=1,5 do row.columns[column]:Hide() end
        if row.headerHits then for _,hit in ipairs(row.headerHits) do hit:Hide() end end
        if row.previous then row.previous:Hide();row.next:Hide() end
        if row.filterCheck then row.filterCheck:Hide() end
        row:SetScript("OnClick",nil);row.familyName=nil
        if row.heading then row.heading:Hide() end
        row.reportTitle,row.reportHint,row.reportSchema=item.text,item.hint,nil
        if row.label.SetNonSpaceWrap then row.label:SetNonSpaceWrap(true) end
        row:EnableMouse(item.hint~=nil)
        UI.SetRowColor(row,rowColor,0);row.mosTableRowSelection:Hide();row.mosTableRowHover:Hide();UI.SetProjectButtonOutline(row,false)
        row.mosTableRowEven=false;row.mosTableRowSelected=false
    end
    function module:MeasureFilter(row,item,width)
        local check=row.filterCheck
        if not check then
            check=UI.Settings.CreateCheckbox(row,8,-2,"Only addon results",item.value,nil,self.filterBinding)
            check:SetWidth(20);check:SetHeight(20);row.filterCheck=check
            UI.AttachTooltip(check,"Only addon results",function() return this.filterHint end)
            UI.AttachTooltip(check.labelHit,"Only addon results",function() return this.owner.filterHint end)
        end
        local available=Results.CanFilterAddons(item.value)
        check.settingKey=item.value
        check.filterHint=not available and "These measurements describe the whole game and cannot be separated by addon." or item.value=="loginMemory" and "Hide built-in Blizzard addon loads. Login stages stay visible. Export still includes everything." or "Show rows from installed addons. Built-in game scripts and rows with an unknown source are hidden. Export still includes everything."
        check:SetChecked(self.tableFilters[item.value] and 1 or nil)
        UI.SetButtonEnabled(check,available);UI.SetButtonEnabled(check.labelHit,available)
        row.label:Hide();row:EnableMouse(false)
        check.label:SetWidth(math.max(1,width-44));FontSize(check.label,11)
        if available then check.label:SetTextColor(1,1,1) else check.label:SetTextColor(0.5,0.5,0.5) end
        if check.label.SetWordWrap then check.label:SetWordWrap(true) end
        local height=math.max(24,UI.MeasureTextHeight(check.label,math.max(1,width-44))+6)
        check.label:SetHeight(height);check.labelHit:SetWidth(math.max(1,width-44));check.labelHit:SetHeight(height)
        check:Show();return height
    end
    local function SetValue(row,index,value) row.values[index]=tostring(value) end
    local function SectionClick() this.reportModule:ToggleSection(this.reportSection) end
    local function ColumnTitle() return this.columnTitle end
    local function ColumnHint() return this.columnHint end
    local function ColumnSort() this.reportModule:SortTable(this.sortSchema,this.sortColumn) end
    local function HeaderHit(row,index,label,title,hint,width,height)
        row.headerHits=row.headerHits or {}
        while table.getn(row.headerHits)<index do
            local created=UI.CreateControl(nil,row);UI.AttachTooltip(created,ColumnTitle,ColumnHint);table.insert(row.headerHits,created)
        end
        local hit=row.headerHits[index]
        hit.columnTitle,hit.columnHint=title,hint
        hit.reportModule,hit.sortSchema,hit.sortColumn=module,row.sortSchema,index
        hit:SetScript("OnClick",ColumnSort)
        hit:ClearAllPoints();hit:SetPoint("TOPLEFT",label,"TOPLEFT",0,0);hit:SetWidth(math.max(1,width));hit:SetHeight(math.max(1,height));hit:EnableMouse(true);hit:Show()
    end
    local function FirstHint(schema)
        for name,entry in pairs(tables) do if entry==schema then return firstHints[name] or columnHints[schema.first] or columnHints.Detail end end
    end
    local function ColumnHintFor(schema,name) return schema.hints and schema.hints[name] or columnHints[name] end
    local function FamilyClick() this.reportModule:ToggleFamily(this.familyName) end
    local function PagerClick()
        if this.pagerLogin then this.reportModule:SetLoginPage(this.direction)
        else this.reportModule:SetFamilyPage(this.pagerFamily,this.direction) end
    end
    local function MeasurePager(row,item,width)
        if not row.previous then
            row.previous=UI.CreateButton(row,nil,"Previous",74,24);row.next=UI.CreateButton(row,nil,"Next",56,24)
            row.pagerFlow={row.previous,row.next}
            row.previous.mosFlowWidth=74;row.next.mosFlowWidth=56
            row.previous.mosFlowFitLabel=true;row.next.mosFlowFitLabel=true
            row.previous.direction=-1;row.next.direction=1
            row.previous:SetScript("OnClick",PagerClick);row.next:SetScript("OnClick",PagerClick)
        end
        local model=item.operation
        local login=item.kind=="loginPager"
        local total=login and model.total or item.value and model.familyMap[item.value].count or table.getn(model.families)
        local current=login and module.loginPage or item.value and module.familyPages[item.value] or module.familyPage
        for _,button in ipairs(row.pagerFlow) do button.reportModule=module;button.pagerFamily=item.value;button.pagerLogin=login;button:Show() end
        UI.SetButtonEnabled(row.previous,current>1);UI.SetButtonEnabled(row.next,current<math.ceil(total/FAMILY_PAGE_SIZE))
        local labelHeight=UI.MeasureTextHeight(row.label,width-16)
        return UI.LayoutFlow(row,row.pagerFlow,8,labelHeight+10,math.max(1,width-16),4)+4
    end
    local function MeasureTableRow(row,item,schema,width,stripe)
        local count=table.getn(schema.columns)
        row.reportSchema=schema
        local values=row.values
        if item.kind=="tableHeader" then
            row.sortSchema=item.value
            local sort=module.tableSorts[item.value]
            row.label:SetText(item.text..(sort and sort.column==1 and (sort.descending and " v" or " ^") or ""))
            for index=1,count do SetValue(row,index,schema.columns[index]..(sort and sort.column==index+1 and (sort.descending and " v" or " ^") or "")) end
        elseif item.kind=="diagnostic" then SetValue(row,1,item.value)
        elseif item.kind=="actionBarsOperation" then
            local data=item.operation
            SetValue(row,1,data.count or 0)
            for index=2,4 do
                local value=Results.Value("actionBarsOperations",index+1,data)
                SetValue(row,index,value~=nil and Duration(value) or "-")
            end
        elseif item.kind=="operation" then
            local data=item.operation
            SetValue(row,1,data.count);SetValue(row,2,Duration(data.time));SetValue(row,3,Duration(data.count>0 and data.time/data.count or 0))
            SetValue(row,4,Duration(data.maxTime));SetValue(row,5,data.memory~=nil and Memory(data.memory) or "-")
        elseif item.kind=="slow" then
            local data=item.operation
            SetValue(row,1,string.format("+%.1f s",data.at));SetValue(row,2,Duration(data.elapsed));SetValue(row,3,Memory(data.heapChange));SetValue(row,4,data.event or "-")
        elseif item.kind=="heapDrop" then
            local data=item.operation
            SetValue(row,1,Memory(data.heapDrop));SetValue(row,2,string.format("%.2f s",data.windowDuration));SetValue(row,3,Duration(data.maxFrameGap));SetValue(row,4,data.slowFrames or 0)
        elseif item.kind=="frameGap" then SetValue(row,1,Duration(item.operation.elapsed))
        elseif item.kind=="loginMemory" then
            local data=item.operation
            SetValue(row,1,data.at and string.format("+%.1f s",data.at) or "-");SetValue(row,2,Memory(data.heap))
            SetValue(row,3,SignedMemory(data.delta));SetValue(row,4,data.windowElapsed and string.format("%.2f s",data.windowElapsed) or "-")
        elseif item.kind=="memoryActivity" or schema==tables.callbackMemory then
            local data=item.operation
            local measured=(data.heapSamples or 0)>0
            local partial=(data.heapUnsupportedCalls or 0)>0
            local suffix=partial and " *" or ""
            local unavailable=partial and "Not measured" or "-"
            SetValue(row,1,data.calls or 0);SetValue(row,2,measured and Memory(data.heapRise)..suffix or unavailable)
            SetValue(row,3,measured and SignedMemory(data.heapDelta)..suffix or unavailable);SetValue(row,4,measured and Memory(data.heapPeak)..suffix or unavailable)
            if schema==tables.callbackMemory then SetValue(row,5,data.failures or 0) end
        elseif item.kind=="callback" or item.kind=="callbackDetail" or item.kind=="family" then
            local data=item.operation
            local measured=data.timedCalls~=0
            SetValue(row,1,data.calls or 0);SetValue(row,2,measured and Duration(data.selfTime) or "Unavailable");SetValue(row,3,measured and Duration(data.time) or "Unavailable")
            SetValue(row,4,measured and Duration(data.peak) or "Unavailable");SetValue(row,5,data.failures or 0)
        elseif item.kind=="callbackSlow" then
            local data=item.operation
            SetValue(row,1,string.format("+%.1f s",data.at));SetValue(row,2,Duration(data.elapsed));SetValue(row,3,Duration(data.selfTime))
            SetValue(row,4,data.event or "-");SetValue(row,5,data.failed and 1 or 0)
        else SetValue(row,1,Memory(item.operation.memory)) end
        if item.kind~="tableHeader" then
            UI.SetRowColor(row,rowColor,math.mod(stripe,2)==0 and 0.14 or 0.025);row:EnableMouse(true)
            row.reportHint=item.hint
            if item.kind=="family" then
                UI.SetRowColor(row,sectionColor,1);UI.SetProjectButtonOutline(row,true)
                row.familyName=item.value;row.reportModule=module;row:SetScript("OnClick",FamilyClick)
                row.label:SetTextColor(unpack(UI.Theme.colors.goldText))
            end
        end
        if item.kind=="diagnostic" and width>=tables.diagnostic.minimum then
            local captionWidth=math.min(280,math.floor((width-24)*0.60))
            local height=math.max(24,UI.MeasureTextHeight(row.label,captionWidth)+8)
            row.label:ClearAllPoints();row.label:SetPoint("TOPLEFT",row,"TOPLEFT",8,0)
            row.label:SetWidth(captionWidth);row.label:SetHeight(height);row.label:SetJustifyV("MIDDLE")
            FontSize(row.columns[1],11)
            UI.Table.Cell(row.columns[1],row,captionWidth+16,width-captionWidth-24,height,values[1])
            if row.columns[1].SetWordWrap then row.columns[1]:SetWordWrap(true) end
            height=math.max(height,UI.MeasureTextHeight(row.columns[1],width-captionWidth-24)+8)
            row.label:SetHeight(height);row.columns[1]:SetHeight(height);row.columns[1]:Show()
            return height
        end
        if width>=schema.minimum then
            local nameWidth=math.floor((width-16)*schema.nameFraction)
            local cellWidth=(width-16-nameWidth)/count
            row.label:SetWidth(nameWidth-8)
            local height=math.max(24,UI.MeasureTextHeight(row.label,nameWidth-8)+8)
            row.label:SetHeight(height);row.label:ClearAllPoints();row.label:SetPoint("TOPLEFT",row,"TOPLEFT",8,0);row.label:SetJustifyV("MIDDLE")
            for index=1,count do
                local label=row.columns[index];FontSize(label,11)
                UI.Table.Cell(label,row,8+nameWidth+(index-1)*cellWidth,cellWidth-8,height,values[index]);label:SetJustifyH("RIGHT")
                if item.kind=="tableHeader" then label:SetTextColor(unpack(UI.Theme.colors.goldText)) else label:SetTextColor(1,1,1) end
                label:Show()
                if item.kind=="tableHeader" then HeaderHit(row,index+1,label,schema.columns[index],ColumnHintFor(schema,schema.columns[index]),cellWidth-8,height) end
            end
            if item.kind=="tableHeader" then row.label:SetTextColor(unpack(UI.Theme.colors.goldText));row:EnableMouse(false);HeaderHit(row,1,row.label,schema.first,FirstHint(schema),nameWidth-8,height) end
            return height
        end
        local height=UI.MeasureTextHeight(row.label,width-16)+10
        if item.kind=="tableHeader" then
            row.label:SetTextColor(unpack(UI.Theme.colors.goldText));row:EnableMouse(false)
            HeaderHit(row,1,row.label,schema.first,FirstHint(schema),width-16,height-10)
        end
        local columns=width>=360 and 2 or 1
        local cellWidth=(width-16)/columns
        for first=1,count,columns do
            local bandHeight=0
            for index=first,math.min(count,first+columns-1) do
                local label=row.columns[index];FontSize(label,11);label:ClearAllPoints()
                label:SetPoint("TOPLEFT",row,"TOPLEFT",8+(index-first)*cellWidth,-height)
                label:SetWidth(math.max(1,cellWidth-8));label:SetHeight(0);label:SetJustifyH("LEFT")
                if label.SetWordWrap then label:SetWordWrap(true) end
                if label.SetNonSpaceWrap then label:SetNonSpaceWrap(true) end
                label:SetText((item.kind=="diagnostic" or item.kind=="tableHeader") and values[index] or schema.columns[index]..": "..values[index]);label:SetTextColor(0.86,0.86,0.86);label:Show()
                -- Reserve two lines so changing numeric precision does not move following sections.
                bandHeight=math.max(bandHeight,24,UI.MeasureTextHeight(label,cellWidth-8))
                if item.kind=="tableHeader" then
                    label:SetTextColor(unpack(UI.Theme.colors.goldText));HeaderHit(row,index+1,label,schema.columns[index],ColumnHintFor(schema,schema.columns[index]),cellWidth-8,bandHeight)
                end
            end
            height=height+bandHeight+4
        end
        return height+4
    end
    local function MeasureItems(width, top)
        local y,index,stripe,schema=top,1,0,nil
        for _,toggle in pairs(page.sectionToggles) do toggle:Hide() end
        while index<=module.itemCount do
            local item,row=module.items[index],EnsureRow(index)
            local inset=(item.indent or 0)*16
            local rowWidth=math.max(1,width-inset)
            if item.kind=="metric" then
                local columns=math.min(3,math.max(1,math.floor((rowWidth+8)/228)))
                local cardWidth=math.floor((rowWidth-(columns-1)*8)/columns)
                local flow,count,height=module.metricFlow,0,0
                while index<=module.itemCount and module.items[index].kind=="metric" and (module.items[index].indent or 0)*16==inset do
                    item,row=module.items[index],EnsureRow(index);ResetRow(row,item,cardWidth)
                    row.label:SetTextColor(unpack(UI.Theme.colors.goldText));row.label:ClearAllPoints();row.label:SetPoint("TOPLEFT",row,"TOPLEFT",8,-8);row.label:SetWidth(math.max(1,cardWidth-16))
                    local labelHeight=UI.MeasureTextHeight(row.label,cardWidth-16)
                    row.detail:ClearAllPoints();row.detail:SetPoint("TOPLEFT",row,"TOPLEFT",8,-labelHeight-12);row.detail:SetWidth(math.max(1,cardWidth-16))
                    row.detail.mosFitFontSize=FontSize(row.detail,15);row.detail:SetText(item.value)
                    if item.severity~=nil then row.detail:SetTextColor(unpack(healthColors[item.severity+1] or healthColors[1])) else row.detail:SetTextColor(1,1,1) end
                    row.detail:Show()
                    UI.FitButtonLabel(row.detail,math.max(1,cardWidth-16));row.detail:SetHeight(18);row.detail:SetJustifyV("MIDDLE")
                    height=math.max(height,labelHeight+18+16)
                    UI.SetRowColor(row,rowColor,0.11);row.mosTableRowHover:SetAlpha(0.08);row.mosFlowWidth=cardWidth;row:Show()
                    count=count+1
                    if count<=table.getn(flow) then flow[count]=row else table.insert(flow,row) end
                    index=index+1
                end
                for tail=table.getn(flow),count+1,-1 do table.remove(flow,tail) end
                for card=1,count do flow[card]:SetHeight(height) end
                y=UI.LayoutFlow(page.canvas,flow,8+inset,y,rowWidth,8)+12
            else
                ResetRow(row,item,rowWidth);row:ClearAllPoints();row:SetPoint("TOPLEFT",page.canvas,"TOPLEFT",8+inset,-y)
                local height=math.max(22,UI.MeasureTextHeight(row.label,rowWidth-16)+12)
                if item.kind=="tableFilter" then height=module:MeasureFilter(row,item,rowWidth)
                elseif item.kind=="tableHeader" then schema=item.operation;stripe=0;height=MeasureTableRow(row,item,schema,rowWidth,0)
                elseif item.kind=="diagnostic" then stripe=stripe+1;height=MeasureTableRow(row,item,tables.diagnostic,rowWidth,stripe)
                elseif item.kind=="operation" or item.kind=="actionBarsOperation" or item.kind=="slow" or item.kind=="memory" or item.kind=="memoryActivity" or item.kind=="loginMemory" or item.kind=="callback" or item.kind=="callbackDetail" or item.kind=="callbackSlow" or item.kind=="family" or item.kind=="heapDrop" or item.kind=="frameGap" then
                    stripe=stripe+1;height=MeasureTableRow(row,item,schema,rowWidth,stripe)
                elseif item.kind=="familyPager" or item.kind=="loginPager" then height=MeasurePager(row,item,rowWidth)
                elseif item.kind=="healthDetail" then
                    row.label:SetText(item.text..": "..item.value)
                    row.label:SetTextColor(1,1,1)
                    row.label:SetWidth(rowWidth-16);row.label:SetHeight(0)
                    height=math.max(24,UI.MeasureTextHeight(row.label,rowWidth-16)+12)
                    row:EnableMouse(true);UI.SetRowColor(row,rowColor,0.045)
                elseif item.kind=="heading" then
                    if not row.heading then row.heading=UI.CreateHeading(row,"",3,"gold","health") end
                    row.label:Hide();row.heading:ClearAllPoints();row.heading:SetPoint("TOPLEFT",row,"TOPLEFT",8,-6)
                    row.heading:SetWidth(math.max(1,rowWidth-16));row.heading:SetHeight(0);FontSize(row.heading,12)
                    row.heading:SetText(item.text);row.heading:SetTextColor(unpack(item.severity and item.severity>=2 and healthColors[item.severity+1] or UI.Theme.colors.goldText));row.heading:Show()
                    height=UI.MeasureTextHeight(row.heading,rowWidth-16)+16
                elseif item.kind=="section" then
                    row.label:Hide();row:EnableMouse(false)
                    local name=item.operation
                    local toggle=page.sectionToggles[name]
                    if not toggle then
                        toggle=UI.Settings.CreateSectionAccordion(page.canvas,item.text,0)
                        UI.SetHeadingIcon(toggle.label,sections[name].icon or "info")
                        toggle.reportModule=module;toggle.reportSection=name;toggle:SetScript("OnClick",SectionClick)
                        UI.SetProjectButtonOutline(toggle,true)
                        UI.AttachTooltip(toggle,item.text,item.hint)
                        page.sectionToggles[name]=toggle
                        if name=="technical" then page.detailsToggle=toggle end
                    end
                    if toggle:GetParent()~=row then toggle:SetParent(row) end
                    -- Reused rows must not carry a preceding table's stripe or hover.
                    UI.SetRowColor(row,rowColor,0.045);row.mosTableRowHovered=nil
                    toggle.sectionHovered=nil;UI.SetProjectButtonOutline(toggle,true)
                    local nested=sections[name].nested
                    local sectionHeight=nested and 24 or 28
                    toggle:ClearAllPoints();toggle:SetPoint("TOPLEFT",row,"TOPLEFT",0,0);toggle:SetWidth(rowWidth);toggle:SetHeight(sectionHeight)
                    toggle.mosFitFontSize=FontSize(toggle.label,nested and 12 or 13)
                    toggle.label:SetText((module:IsSectionExpanded(name) and "- " or "+ ")..item.text..(item.value~=nil and " ("..item.value..")" or ""))
                    UI.FitButtonLabel(toggle,math.max(1,rowWidth-32));toggle.label:SetJustifyH("LEFT")
                    toggle.indicator:ClearAllPoints();toggle.indicator:SetPoint("LEFT",toggle,"LEFT",8,0)
                    toggle.label:ClearAllPoints();toggle.label:SetPoint("LEFT",toggle,"LEFT",20,0)
                    toggle.label.mosAccordionPrefixInset=20
                    toggle.rule:Hide();toggle:SetExpanded(module:IsSectionExpanded(name));toggle:Show();height=sectionHeight
                    UI.SetRowColor(toggle,sectionColor,1)
                else row.label:SetTextColor(0.78,0.78,0.78) end
                row:SetHeight(math.max(1,height));if height>0 then row:Show();y=y+height+2 else row:Hide() end
                index=index+1
            end
        end
        for index=module.itemCount+1,table.getn(module.rows) do module.rows[index]:Hide() end
        return y+8
    end

    local function ProfileClick() module:SelectTab(this.profile) end
    local function CreateProfileOption(profile)
        local option=UI.CreateButton(page.advancedMenu,nil,profile[1],182,26);UI.StyleActionButton(option)
        option.profile=profile[2];option:SetScript("OnClick",ProfileClick)
        option.mosActionAlign="LEFT";option.mosLabelJustify="LEFT";if option.label.SetWordWrap then option.label:SetWordWrap(false) end
        UI.SetActionButtonIcon(option,profile[3]);return option
    end
    function module:UpdateProfileMenu()
        if not page.advancedMenu then return end
        local available=self:HasActionBarsCapture()
        if available and not page.actionBarsProfileOption then
            local option=CreateProfileOption({"Profile Action Bars","Action Bars","list"})
            page.actionBarsProfileOption=option
            table.insert(page.advancedMenu.options,table.getn(page.advancedMenu.options),option)
        end
        local count=0
        for _,option in ipairs(page.advancedMenu.options) do
            if option.profile~="Action Bars" or available then
                option:ClearAllPoints();option:SetPoint("TOPLEFT",page.advancedMenu,"TOPLEFT",4,-4-count*30)
                option:Show();count=count+1
            else option:Hide() end
        end
        page.advancedMenu:SetHeight(6+count*30)
    end
    function module:EnsureUI()
        if page.controls then return end
        page.tabs=UI.CreateToolbarSurface(page.header,true,true);page.controls=UI.CreateToolbarSurface(page.header,false,true)
        UI.AddToolbarBackground(page.tabs,0.42)
        page.advancedButton=UI.CreateButton(page.tabs,nil,"Advanced Profiler",170,26)
        if not options.standalone then page.enableButton=UI.CreateButton(page.tabs,nil,"Enable",110,26) end
        page.startButton=UI.CreateButton(page.controls,nil,"Start",94,26)
        page.resetButton=UI.CreateButton(page.controls,nil,"Reset",94,26);page.exportButton=UI.CreateButton(page.controls,nil,"Export",94,26)
        page.monitorButton=UI.CreateButton(page.tabs,nil,"Live Monitor",140,26)
        page.healthButton=UI.CreateButton(page.tabs,nil,"Health Check",140,26)
        page.refreshButton=UI.CreateButton(page.controls,nil,"Update ranking",154,26)
        page.memoryButton=UI.CreateButton(page.controls,nil,"Refresh memory",154,26)
        page.memoryModeButton=UI.CreateButton(page.controls,nil,"Memory: OFF",132,26)
        page.callbackViewButton=UI.CreateButton(page.controls,nil,"View: Time",136,26)
        page.loginButton=UI.CreateButton(page.controls,nil,"Analyze Login",154,26)
        page.tabFlow={page.monitorButton,page.advancedButton,page.healthButton};page.visibleTabs={};page.actions={page.startButton,page.resetButton,page.exportButton,page.memoryModeButton,page.callbackViewButton,page.memoryButton,page.refreshButton,page.loginButton};page.flow={}
        for _,flow in ipairs({page.tabFlow,page.actions,page.enableButton and {page.enableButton} or emptyEntries}) do for _,button in ipairs(flow) do
            button.mosFlowWidth=button:GetWidth();UI.StyleActionButton(button)
            if button.label.SetWordWrap then button.label:SetWordWrap(false) end
        end end
        UI.SetActionButtonIcon(page.advancedButton,"performance");UI.SetActionButtonIcon(page.monitorButton,"monitor");UI.SetActionButtonIcon(page.healthButton,"health");UI.SetActionButtonIcon(page.loginButton,"start")
        if page.enableButton then UI.SetActionButtonIcon(page.enableButton,"enable") end
        UI.SetActionButtonIcon(page.startButton,"start");UI.SetActionButtonIcon(page.resetButton,"reset")
        UI.SetActionButtonIcon(page.exportButton,"save");UI.SetActionButtonIcon(page.refreshButton,"refresh");UI.SetActionButtonIcon(page.memoryButton,"memory")
        UI.SetActionButtonIcon(page.memoryModeButton,"settings");UI.SetActionButtonIcon(page.callbackViewButton,"list")
        local profiles=options.standalone and {{"Profile All","All Addons","groups"},{"Analyze Login","Analyze Login","analyze"}}
            or {{"Profile Booty","MOS","guild_stats"},{"Profile All","All Addons","groups"},{"Analyze Login","Analyze Login","analyze"}}
        page.advancedMenu=UI.CreateDropdownPanel(page.tabs,page.advancedButton,190,6+table.getn(profiles)*30)
        for index,profile in ipairs(profiles) do
            local option=CreateProfileOption(profile)
            option:SetPoint("TOPLEFT",page.advancedMenu,"TOPLEFT",4,-4-(index-1)*30)
            table.insert(page.advancedMenu.options,option)
        end
        self:UpdateProfileMenu()
        local menuShown=page.advancedMenu:GetScript("OnShow")
        page.advancedMenu:SetScript("OnShow",function()
            if menuShown then menuShown() end
            module:UpdateProfileMenu()
            for _,option in ipairs(page.advancedMenu.options) do UI.FitButtonLabel(option,option:GetWidth()-16) end
        end)
        page.backgroundHost=UI.CreateContainer(nil,page);page.backgroundHost:EnableMouse(false)
        page.backgroundHost:SetFrameLevel(page:GetFrameLevel())
        page.art=UI.CreatePerformanceBackground(page.backgroundHost,1)
        -- One shared content layer; row fills retain the project's own palette.
        page.contentDim=UI.CreateTexture(page.backgroundHost,nil,"ARTWORK")
        page.contentDim:SetTexture(0,0,0,1);page.contentDim:SetAlpha(0.86);page.contentDim:SetAllPoints(page.backgroundHost)
        page.status=UI.CreateLabel(page.header,nil,"OVERLAY","GameFontHighlightSmall");page.status:SetJustifyH("LEFT");if page.status.SetWordWrap then page.status:SetWordWrap(true) end
        page.sectionToggles={}
        page.advancedButton:SetScript("OnClick",function() if page.advancedMenu:IsShown() then page.advancedMenu:Hide() else page.advancedMenu:Show() end end)
        if page.enableButton then page.enableButton:SetScript("OnClick",function() module:ToggleAddon() end) end
        page.startButton:SetScript("OnClick",function() if module.provider.GetState().recording then module:Stop() else module:Start() end end)
        page.resetButton:SetScript("OnClick",function() module:Reset() end);page.exportButton:SetScript("OnClick",function() module:Export() end)
        page.monitorButton:SetScript("OnClick",function() module:ToggleMonitor() end)
        page.healthButton:SetScript("OnClick",function() module:SelectTab("Health Check") end)
        page.refreshButton:SetScript("OnClick",function() module:RefreshTables() end)
        page.memoryButton:SetScript("OnClick",function() module:RefreshAddons() end)
        page.memoryModeButton:SetScript("OnClick",function() module:ToggleMemoryCapture() end)
        page.callbackViewButton:SetScript("OnClick",function() module:ToggleCallbackView() end)
        page.loginButton:SetScript("OnClick",function()
            if module.tab~="Analyze Login" then module:SelectTab("Analyze Login") end
            module:ToggleLoginCapture()
        end)
        UI.AttachTooltip(page.exportButton,"Export session","Stop first. Saves one report; reload or logout writes it to disk.")
        if page.enableButton then UI.AttachTooltip(page.enableButton,"Enable / Disable BootyProfiler","Changes whether the client loads BootyProfiler. Requires a UI reload; disabling stops its measurements first.") end
        UI.AttachTooltip(page.startButton,"Start / Stop recording","Start records the chosen profile. Profile Booty measures selected Booty operations; Profile All also intercepts frame callbacks. Switching views does not restart a capture.")
        UI.AttachTooltip(page.advancedButton,"Advanced Profiler","Choose a callback profile or login analysis. Selecting a view does not start recording.")
        UI.AttachTooltip(page.monitorButton,"Live Monitor","Lightweight current readings, once per second while its window is visible. Independent of advanced captures; no report is saved.")
        UI.AttachTooltip(page.healthButton,"Health Check","Diagnosis and tips from the last completed scan. This view starts no measurement.")
        UI.AttachTooltip(page.refreshButton,"Update ranking","Show newly recorded rows, update recent-call lists and sort by current totals. During recording, rows stay in place until you click this button.")
        UI.AttachTooltip(page.memoryButton,"Native memory snapshot","Refresh the client's per-addon memory counters when available. Callback growth is measured separately.")
        UI.AttachTooltip(page.memoryModeButton,"Measure callback memory","Enable before Start in All Addons. Measures heap growth around callbacks, including profiling overhead; adds two reads per call.")
        UI.AttachTooltip(page.callbackViewButton,"Callback view","Switch family columns and ranking between time and memory growth. This does not change a running capture.")
        UI.AttachTooltip(page.loginButton,"Analyze Login","Prepare one loading capture and choose whether to reload now or later. It also observes the first ten seconds in the world.")
    end
    local function LayoutTabs(width)
        local available=math.max(1,width-16)
        local required,count=0,0
        for _,button in ipairs(page.tabFlow) do if button:IsShown() then
            required=required+button.mosFlowWidth+8;count=count+1
            if count<=table.getn(page.visibleTabs) then page.visibleTabs[count]=button else table.insert(page.visibleTabs,button) end
        end end
        for index=table.getn(page.visibleTabs),count+1,-1 do table.remove(page.visibleTabs,index) end
        if required>0 then required=required-8 end
        if not page.enableButton then return UI.LayoutFlow(page.tabs,page.visibleTabs,8,8,available,8)+8 end
        local inline=count==0 or required+page.enableButton.mosFlowWidth+8<=available
        local bottom=UI.LayoutFlow(page.tabs,page.visibleTabs,8,8,math.max(1,inline and available-page.enableButton.mosFlowWidth-8 or available),8)
        local actionTop=inline and 8 or bottom+8
        page.enableButton:ClearAllPoints();page.enableButton:SetPoint("TOPRIGHT",page.tabs,"TOPRIGHT",-8,-actionTop)
        page.enableButton:SetWidth(math.min(page.enableButton.mosFlowWidth,available));UI.FitButtonLabel(page.enableButton,math.max(1,page.enableButton:GetWidth()-16))
        return math.max(bottom,actionTop+26)+8
    end
    local function MeasureHeader(width)
        page.header:SetWidth(width)
        page.title:ClearAllPoints();page.title:SetPoint("TOPLEFT",page.header,"TOPLEFT",8,-8);UI.FitButtonLabel(page.title,width-16)
        if not page.tabs then page.toolbarHeight=38;page.header:SetHeight(38);return 38 end
        local tabHeight=LayoutTabs(width)
        page.tabs:ClearAllPoints();page.tabs:SetPoint("TOPLEFT",page.header,"TOPLEFT",0,-38);page.tabs:SetWidth(width);page.tabs:SetHeight(tabHeight)
        if not module.provider or not module.tab then page.toolbarHeight=38+tabHeight;page.header:SetHeight(page.toolbarHeight);return page.toolbarHeight end
        local controlHeight=page.controls:IsShown() and UI.LayoutFlow(page.controls,page.flow,8,8,width-16,8)+8 or 0
        page.controls:ClearAllPoints();page.controls:SetPoint("TOPLEFT",page.header,"TOPLEFT",0,-38-tabHeight);page.controls:SetWidth(width);page.controls:SetHeight(controlHeight)
        page.toolbarHeight=38+tabHeight+controlHeight
        local top=page.toolbarHeight+4
        page.status:ClearAllPoints();page.status:SetPoint("TOPLEFT",page.header,"TOPLEFT",8,-top);page.status:SetWidth(math.max(1,width-16));page.status:SetHeight(0)
        FontSize(page.status,11)
        top=top+math.max(22,UI.MeasureTextHeight(page.status,width-16))+2;page.header:SetHeight(top);return top
    end
    local function MeasurePage(width)
        local top=8
        if not module.headerPinned then top=MeasureHeader(width)+8 end
        if not module.provider or not module.tab or module.captureConflict then
            local messageHeight
            page.message:SetWidth(math.max(1,width-32));FontSize(page.message,module.captureConflict and 19 or 12)
            messageHeight=UI.MeasureTextHeight(page.message,math.max(1,width-32));page.message:SetHeight(messageHeight)
            local host=page.messageHost
            local scrolling=module.captureConflict and not module.headerPinned
            host:SetParent(scrolling and page.canvas or page.bodyHost);host:ClearAllPoints()
            host:SetWidth(width);host:SetHeight(math.max(messageHeight+16,page.bodyHost:GetHeight()))
            if scrolling then host:SetPoint("TOPLEFT",page.canvas,"TOPLEFT",0,-top)
            else host:SetPoint("CENTER",page.bodyHost,"CENTER",0,0) end
            page.message:ClearAllPoints();page.message:SetPoint("CENTER",host,"CENTER",0,0)
            if scrolling then return top+host:GetHeight() end
            return 0
        end
        return MeasureItems(math.max(1,width-16),top)
    end
    function module:LayoutBackground()
        if not page.backgroundHost then return end
        local width,height=self.backgroundOwnerWidth,self.backgroundOwnerHeight
        if not width then width,height=UI.GetFrameSpan(parent) end
        local scroll=not self.headerPinned and page.canvas.layoutViewport:GetVerticalScroll() or 0
        local top=math.max(0,math.min(height,3+(page.toolbarHeight or 0)-scroll))
        page.backgroundTop=top
        page.backgroundHost:ClearAllPoints();page.backgroundHost:SetPoint("TOPLEFT",parent,"TOPLEFT",0,-top)
        page.backgroundHost:SetPoint("BOTTOMRIGHT",parent,"BOTTOMRIGHT",0,0)
        page.backgroundHost:SetWidth(width);page.backgroundHost:SetHeight(math.max(1,height-top))
        UI.LayoutPerformanceBackground(page.art,page.backgroundHost,width,math.max(1,height-top));page.art:Show()
        if self.provider and self.tab then page.contentDim:Show() else page.contentDim:Hide() end
    end
    function module:Layout()
        local width,height=UI.GetFrameSpan(parent)
        self.backgroundOwnerWidth,self.backgroundOwnerHeight=width,height
        width,height=math.max(80,width-3),math.max(80,height-4.5)
        page:SetWidth(width);page:SetHeight(height)
        local headerHeight=MeasureHeader(width)
        self.headerPinned=self.provider==nil or self.tab==nil or height>=headerHeight+120
        local headerParent=self.headerPinned and page or page.canvas
        if page.header:GetParent()~=headerParent then page.header:SetParent(headerParent) end
        page.header:ClearAllPoints();page.header:SetPoint("TOPLEFT",headerParent,"TOPLEFT",0,0)
        local inset=self.headerPinned and headerHeight or 0
        page.bodyHost:ClearAllPoints();page.bodyHost:SetPoint("TOPLEFT",page,"TOPLEFT",0,-inset)
        height=math.max(1,height-inset)
        page.bodyHost:SetWidth(width);page.bodyHost:SetHeight(height)
        UI.LayoutResponsiveCanvas(page.canvas,MeasurePage,self,width,height)
        self:LayoutBackground()
    end
    function module:Refresh()
        if not page:IsVisible() then return end
        self:EnsureUI();self:UpdateAddonControl()
        if not self.provider then
            self:UpdateAvailabilityMessage();page.controls:Hide();page.status:Hide();self:Layout()
            return
        end
        local state=self.provider.GetState()
        page.message:Hide()
        if not self.tab then
            self.itemCount=0;for _,row in ipairs(self.rows) do row:Hide() end
            for _,toggle in pairs(page.sectionToggles) do toggle:Hide() end
            page.controls:Hide();page.status:Hide();self:Layout();return
        end
        local profileView=Performance.Profiles.IsTab(self.tab)
        self.captureConflict=self:HasCaptureConflict()
        if self.captureConflict then
            self:CancelFamilyJob()
            page.message:SetText("Another profile is recording. Stop it before starting this profile.");page.message:Show()
            for _,row in ipairs(self.rows) do row:Hide() end
            for _,toggle in pairs(page.sectionToggles) do toggle:Hide() end
        end
        if self.tab=="Health Check" then page.controls:Hide() else page.controls:Show() end
        page.status:Show();self:BuildItems()
        local memorySupported=state.session and state.session.capabilities and state.session.capabilities.addonMemory
        if self.provider.HasNativeAddonMemory then memorySupported=memorySupported~=false and self.provider.HasNativeAddonMemory() end
        local login=self.provider.LoginMemory
        local actionCount=0
        local previousCount=table.getn(page.flow)
        for _,button in ipairs(page.actions) do
            local show=profileView and button~=page.loginButton or self.tab=="Analyze Login" and button==page.loginButton
            if button==page.memoryModeButton or button==page.callbackViewButton then show=self.tab=="All Addons"
            elseif button==page.memoryButton then show=self.tab=="All Addons" and memorySupported~=false end
            if show then
                actionCount=actionCount+1
                if actionCount<=previousCount then page.flow[actionCount]=button else table.insert(page.flow,button) end
                button:Show()
            else button:Hide() end
        end
        for index=table.getn(page.flow),actionCount+1,-1 do table.remove(page.flow,index) end
        page.startButton:SetText(state.recording and "Stop" or "Start")
        UI.SetActionButtonIcon(page.startButton,state.recording and "stop" or "start")
        local pendingDisable=self.addonStatus and self.addonStatus.reloadRequired and self.addonStatus.pendingEnabled==false
        UI.SetButtonEnabled(page.startButton,not pendingDisable)
        local foreignSession=self:HasForeignProfileSession()
        UI.SetButtonEnabled(page.resetButton,state.session~=nil and not foreignSession);UI.SetButtonEnabled(page.exportButton,state.session~=nil and not state.recording and not foreignSession)
        UI.SetButtonEnabled(page.refreshButton,state.session~=nil or login and login.GetReport()~=nil)
        UI.SetButtonEnabled(page.memoryButton,not pendingDisable and self.tab=="All Addons" and memorySupported~=false)
        page.memoryModeButton:SetText(self.measureMemory and "Memory: ON" or "Memory: OFF")
        page.callbackViewButton:SetText(self.callbackView=="memory" and "View: Memory" or "View: Time")
        UI.SetButtonEnabled(page.memoryModeButton,not state.recording)
        UI.SetButtonEnabled(page.callbackViewButton,self.measureMemory or state.session and state.session.callbackMemoryRequested)
        if self.captureConflict then for _,button in ipairs(page.actions) do UI.SetButtonEnabled(button,false) end end
        local capture=state.session
        local viewing=self.tab=="MOS" and "Profile Booty" or self.tab=="All Addons" and "Profile All" or self.tab
        local detail="Ready"
        if self.tab=="Health Check" then
            local report=self.healthReport
            detail=report and report.available and "Last scan: "..ScanDate(report.date)..", "..ScanSeconds(report.elapsed) or "No completed scan"
        elseif self.tab=="Analyze Login" then
            local report=login and login.GetReport()
            detail=report and (report.kind=="recording" and "Recording..." or "Last scan: "..ScanDate(report.capturedDate)..", "..ScanSeconds(report.elapsed)) or login and login.IsArmed() and "Ready for next reload" or "No login scan"
        elseif self.captureConflict then detail="Another profile is recording"
        elseif capture and profileView and not self:MatchesSession(capture) then
            detail=state.recording and "Another profile is recording" or "No scan for this profile"
        elseif capture then
            detail=state.recording and "Recording... "..ScanSeconds(capture.elapsed) or "Last scan: "..ScanDate(capture.capturedDate)..", "..ScanSeconds(capture.elapsed)
        end
        if pendingDisable then detail="Disabled after next reload" end
        local gold=UI.Theme.colors.goldText
        local prefix=string.format("|cff%02x%02x%02x",math.floor(gold[1]*255),math.floor(gold[2]*255),math.floor(gold[3]*255))
        page.status:SetText(prefix..viewing.."|r | "..detail..(state.error and "\n"..state.error or self.notice and "\n"..self.notice or ""))
        page.status:SetTextColor(1,1,1)
        self:Layout()
    end
    local function Updated()
        if module.tab=="Health Check" then
            local state=module.provider.GetState()
            local report=module.provider.GetLastHealthReport and module.provider.GetLastHealthReport()
            if module.healthRecording==state.recording and module.healthReport==report then return end
        end
        module:Refresh()
    end
    local function Subscribe()
        if module.provider then module.provider.SetListener(page:IsVisible() and module.tab and module.tab~="Analyze Login" and Updated or nil) end
        if module.provider and module.provider.LoginMemory then module.provider.LoginMemory.SetListener(page:IsVisible() and module.tab=="Analyze Login" and Updated or nil) end
    end
    function module:SelectTab(tab)
        if tab=="Booty" then tab="MOS" end
        if options.standalone and tab=="MOS" then return false end
        if tab=="Action Bars" and not self:HasActionBarsCapture() then return false end
        if not Performance.Profiles.IsTab(tab) and tab~="Analyze Login" and tab~="Health Check" then return false end
        self:ClearTableViews();self:CancelFamilyJob();self.familyModel=nil;self.tab=tab
        if Performance.Profiles.IsTab(tab) then self.lastProfile=tab end
        self.sectionState={};self.detailsExpanded={};self.expandedFamily=nil;self.familyPages={};self.familyPage=1
        if page.advancedMenu then page.advancedMenu:Hide() end
        page.canvas.layoutViewport:SetVerticalScroll(0);Subscribe();self:Refresh();return true
    end
    function module:ToggleSection(name)
        if name=="technical" then self.detailsExpanded[self.tab]=not self.detailsExpanded[self.tab]
        else self.sectionState[self.tab..":"..name]=not self:IsSectionExpanded(name) end
        if self:IsSectionExpanded(name) then self.snapshots[self.tab..":"..name]=nil end
        if name=="callbackDetails" then self:ClearTableViews();self:CancelFamilyJob();self.familyModel=nil end
        self:Refresh()
    end
    function module:ToggleDetails() self:ToggleSection("technical") end
    function module:RefreshTables()
        if self.captureConflict then return false end
        self:ClearTableViews();self:CancelFamilyJob();self.familyModel=nil;self.snapshots={};self:Refresh()
    end
    function module:ToggleMemoryCapture()
        if self.captureConflict or self.provider.GetState().recording then return false end
        self.measureMemory=not self.measureMemory
        if options.saveMemoryMode then options.saveMemoryMode(self.measureMemory) end
        self.callbackView=self.measureMemory and "memory" or "time"
        self:RefreshTables()
    end
    function module:ToggleCallbackView()
        if self.captureConflict then return false end
        self.callbackView=self.callbackView=="memory" and "time" or "memory"
        self:RefreshTables()
    end
    function module:ToggleLoginCapture()
        local capture=self.provider and self.provider.LoginMemory
        if not capture then return end
        if not self.addonStatus or not self.addonStatus.canReload then return end
        if self.addonStatus.reloadRequired and self.addonStatus.pendingEnabled==false then return end
        local ok,message=capture.Arm(true)
        self.notice=ok and nil or message
        self:Refresh()
        if not ok then return end
        if not self.loginDialog then
            self.loginDialog=UI.Window.CreateProjectConfirmation(nil,"Analyze Login","Reload now","analyze")
            self.loginDialog:SetWidth(400);self.loginDialog.no:SetText("Later")
            self.loginDialog.yes:SetWidth(110);self.loginDialog.no:ClearAllPoints();self.loginDialog.no:SetPoint("BOTTOMRIGHT",self.loginDialog,"BOTTOMRIGHT",-126,8)
        end
        self.loginDialog:Open("Records addon loading and memory changes on the next UI reload or login, then ten seconds in the world. Reload now?",function()
            local reloaded,failure=bridge.ReloadUI()
            if not reloaded then module.notice="UI reload failed: "..tostring(failure);module:Refresh() end
        end)
    end
    function module:UpdateAddonControl()
        local status=self.addonStatus or {}
        if page.enableButton then
            page.enableButton:SetText(status.reloadRequired and "Reload UI" or status.loaded and "Disable" or "Enable")
            UI.SetActionButtonIcon(page.enableButton,status.reloadRequired and "reload" or status.loaded and "disable" or "enable")
            UI.SetButtonEnabled(page.enableButton,status.reloadRequired and status.canReload or status.loaded and status.canDisable or not status.loaded and status.canEnable or false)
        end
        local ready=self.provider and not (status.reloadRequired and status.pendingEnabled==false)
        local login=self.provider and self.provider.LoginMemory
        UI.SetButtonEnabled(page.advancedButton,ready and true or false)
        UI.SetButtonEnabled(page.monitorButton,ready and self.provider.LiveMonitor and Performance.CreateLiveMonitor and true or false)
        UI.SetButtonEnabled(page.healthButton,ready and self.provider.GetLastHealthReport and true or false)
        UI.SetButtonEnabled(page.loginButton,ready and login and not login.IsRecording() and status.canReload or false)
    end
    function module:UpdateAvailabilityMessage()
        local availability=self.addonStatus or {}
        local message=availability.reloadRequired and "BootyProfiler is enabled. Click Reload UI to load it."
            or availability.state=="absent" and "BootyProfiler is not installed. Install it beside BootyLib, then restart the game."
            or availability.installed and not availability.loaded and "BootyProfiler is not loaded. Click Enable to load it. This will reload the UI."
            or self.providerFailure or "BootyProfiler is unavailable."
        page.message:SetText(message..(self.notice and "\n"..self.notice or ""));page.message:Show()
    end
    function module:ToggleAddon()
        if options.standalone then return false end
        local status=self.addonStatus
        if status and status.reloadRequired then
            local ok,failure=bridge.ReloadUI()
            if not ok then self.notice="UI reload failed: "..tostring(failure);self:Refresh() end
            return
        end
        if not status or not (status.loaded and status.canDisable or not status.loaded and status.canEnable) then return end
        local enable=not status.loaded
        if not self.addonDialog then self.addonDialog=UI.Window.CreateProjectConfirmation(nil,"BootyProfiler","Reload now","performance");self.addonDialog:SetWidth(400) end
        self.addonDialog.title:SetText(enable and "Enable BootyProfiler" or "Disable BootyProfiler")
        UI.SetHeadingIcon(self.addonDialog.title,enable and "enable" or "disable")
        self.addonDialog:Open(enable and "Enable BootyProfiler and reload the UI to load it?" or "Do you want to disable BootyProfiler Addon? This will reload your UI - please export any recordings you want to keep.",function()
                if not enable and module.monitor then module.monitor:Close() end
            local changed,failure=bridge.SetAddonEnabled(enable)
            module.addonStatus=bridge.GetAddonStatus()
            if not changed then module.notice="BootyProfiler change failed: "..tostring(failure);module:Refresh();return end
            local reloaded,reason=bridge.ReloadUI()
            if not reloaded then module.notice="UI reload failed: "..tostring(reason);module:Refresh() end
        end)
    end
    function module:SetLoginPage(direction) self.loginPage=math.max(1,self.loginPage+direction);self:Refresh() end
    function module:ReleasePresentation()
        if page.advancedMenu then page.advancedMenu:Hide() end
        if self.loginDialog then self.loginDialog:Hide() end
        if self.addonDialog then self.addonDialog:Hide() end
        self:CancelFamilyJob();self.familyModel=nil
        self.snapshots={};self.snapshotSession=nil;self.snapshotRecording=nil
        self.sectionState={};self.detailsExpanded={};self.expandedFamily=nil;self.familyPages={};self.familyPage=1
        self.healthReport,self.healthRecording=nil,nil
        self.loginReport,self.loginEventCount,self.loginKind=nil,nil,nil
        self:ClearTableViews();self.tableSorts={};self.tableFilters={}
        self.captureConflict=false
        for _,entries in ipairs({self.sessionEntries,self.callbackEntries,self.callbackDetails,self.memoryEntries,self.historyEntries or emptyEntries,self.otherFrameGaps or emptyEntries}) do
            for index=table.getn(entries),1,-1 do table.remove(entries,index) end
        end
        for _,item in ipairs(self.items) do item.operation=nil end
    end
    function module:Start()
        if self:HasCaptureConflict() then return false end
        if not self.provider or not Performance.Profiles.IsTab(self.tab) then return false end
        if self.tab=="Action Bars" and not self:HasActionBarsCapture() then return false end
        if self.addonStatus and self.addonStatus.reloadRequired and self.addonStatus.pendingEnabled==false then return false end
        if not self.provider.GetState().enabled then self.provider.Enable(true) end
        local selectedSource="Booty"
        if self.tab=="Action Bars" then selectedSource="Action Bars" elseif options.standalone then selectedSource=false end
        local ok,message=self.provider.Start({callbacks=self.tab=="All Addons",memory=self.tab~="Action Bars" and self.measureMemory or false,source=selectedSource})
        if ok then self.familyPages={};self.familyPage=1;self.expandedFamily=nil end
        self.notice=message;self:Refresh();return ok
    end
    function module:Stop() if self:HasCaptureConflict() then return false end if self.provider then local ok=self.provider.Stop();self:Refresh();return ok end end
    function module:Reset() if self:HasForeignProfileSession() then return false end if self.provider then self:ClearTableViews();self.provider.Reset();self.familyPages={};self.familyPage=1;self.expandedFamily=nil;self.notice=nil;page.canvas.layoutViewport:SetVerticalScroll(0);self:Refresh() end end
    function module:Export()
        if self:HasForeignProfileSession() then return false end
        local result,message=self.provider.Export()
        self.notice=result and "Report exported; reload or logout writes it to disk." or message
        self:Refresh();return result
    end
    function module:RefreshAddons()
        if self.captureConflict then return false end
        if self.addonStatus and self.addonStatus.reloadRequired and self.addonStatus.pendingEnabled==false then return false end
        if not self.provider.GetState().enabled then self.provider.Enable(true) end
        local ok,message=self.provider.ReadAddonMemory()
        self.addonEntries=self.provider.GetState().addonEntries
        if ok then self:InvalidateTables() end
        self.notice=ok and "Native addon memory refreshed." or message
        self:Refresh();return ok
    end
    function module:ToggleMonitor()
        local backend=self.provider and self.provider.LiveMonitor
        if not backend or not Performance.CreateLiveMonitor then return false end
        if self.addonStatus and self.addonStatus.reloadRequired and self.addonStatus.pendingEnabled==false then return false end
        if not self.monitor then
            self.monitor=Performance.CreateLiveMonitor(backend,options)
        end
        if self.monitor:IsShown() then self.monitor:Close() else return self.monitor:Open() end
        return true
    end
    -- Explicit menu requests read current addon state, without showing the page
    -- or subscribing hidden result views to live refresh notifications.
    function module:GetQuickState()
        local status=bridge and bridge.GetAddonStatus(true) or {}
        self.addonStatus=status
        local provider=bridge and bridge.Resolve()
        local state=provider and provider.GetState() or {}
        local ready=provider~=nil and not (status.reloadRequired and status.pendingEnabled==false)
        local conflict=self:HasCaptureConflict()
        local foreignSession=self:HasForeignProfileSession()
        return {
            installed=status.installed and true or false,loaded=status.loaded and true or false,ready=ready,
            toggleLabel=status.reloadRequired and "Reload UI" or status.loaded and "Disable" or "Enable",
            toggleEnabled=status.reloadRequired and status.canReload or status.loaded and status.canDisable or not status.loaded and status.canEnable or false,
            recording=state.recording and true or false,startStopLabel=state.recording and "Stop" or "Start",startStopEnabled=ready and not conflict,
            resetEnabled=ready and state.session~=nil and not foreignSession,exportEnabled=ready and state.session~=nil and not state.recording and not foreignSession,
            memory=self.measureMemory and true or false,memoryEnabled=ready and not state.recording and self.tab~="Action Bars",
            liveEnabled=ready and provider.LiveMonitor~=nil and Performance.CreateLiveMonitor~=nil,
            healthEnabled=ready and provider.GetLastHealthReport~=nil,
        }
    end
    function module:ExecuteQuickAction(action)
        local quick=self:GetQuickState()
        if action=="addon" then if quick.toggleEnabled then self:ToggleAddon();return true end;return false end
        if not quick.ready then return false end
        local provider,failure=bridge.Connect()
        if not provider then self.notice=failure;return false end
        self.provider=provider
        if action=="live" then return quick.liveEnabled and self:ToggleMonitor() or false end
        if action=="health" then return quick.healthEnabled and self:SelectTab("Health Check") or false end
        if action=="startStop" then
            if not quick.startStopEnabled then return false end
            if provider.GetState().recording then self:Stop();return true end
            local profile=self.lastProfile
            if not profile then
                local session=provider.GetState().session
                profile=session and (session.sourceName=="Action Bars" and "Action Bars" or session.callbacksRequested and "All Addons" or "MOS") or "All Addons"
            end
            if options.standalone and profile~="Action Bars" then profile="All Addons" end
            if not self:SelectTab(profile) then return false end
            return self:Start()
        end
        if action=="reset" then if quick.resetEnabled then self:Reset();return true end;return false end
        if action=="export" then return quick.exportEnabled and self:Export() or false end
        if action=="memory" then if quick.memoryEnabled then self:ToggleMemoryCapture();return true end;return false end
        return false
    end
    function module:Show()
        local provider,failure
        if bridge then provider,failure=bridge.Connect() else failure="BootyProfiler integration is unavailable." end
        if self.provider and self.provider~=provider then
            self.provider.SetListener(nil)
            if self.provider.LoginMemory then self.provider.LoginMemory.SetListener(nil) end
            if self.monitor then self.monitor:Close();self.monitor=nil end
        end
        self.provider=provider
        self.providerFailure=failure
        self.addonStatus=bridge and bridge.GetAddonStatus(true) or nil
        self:EnsureUI();page.tabs:Show();self:UpdateAddonControl()
        if provider then
            page.message:Hide()
        else
            self:UpdateAvailabilityMessage()
            page.controls:Hide();page.status:Hide()
            self.itemCount=0;for _,row in ipairs(self.rows) do row:Hide() end
        end
        self.showRefreshPerformed=false;page:Show();Subscribe()
        if provider then if not self.showRefreshPerformed then self:Refresh() end else self:Layout() end
    end
    function module:Hide() self:ReleasePresentation();if self.loginDialog then self.loginDialog:Hide() end;if self.addonDialog then self.addonDialog:Hide() end;page:Hide();Subscribe() end
    function module:OnResize() if page:IsVisible() then self:Layout() end end
    page:SetScript("OnShow",function() Subscribe();if module.provider then module.showRefreshPerformed=true;module:Refresh() end end)
    page:SetScript("OnHide",function() module:ReleasePresentation();Subscribe() end)
    module:Layout();return module
end
