-- Typed presentation sorting and verified source filtering. Captures and
-- exported records remain untouched; callers retain and reuse the view lists.
local P=BootyProfiler
local Results={}
P.Services.ProfilerResults=Results
local fields={
    operations={"name","count","time","average","maxTime","memory"},
    slow={"name","at","elapsed","heapChange","event"},
    memory={"name","memory"},memoryActivity={"name","calls","heapRise","heapDelta","heapPeak"},
    callbackMemory={"name","calls","heapRise","heapDelta","heapPeak","failures"},
    callbacks={"name","calls","selfTime","time","peak","failures"},
    callbackDetails={"name","calls","selfTime","time","peak","failures"},
    callbackSlow={"name","at","elapsed","selfTime","event","failed"},
    loginMemory={"stage","at","heap","delta","windowElapsed"},
    heapDrops={"sampleAt","heapDrop","windowDuration","maxFrameGap","slowFrames"},
    frameGaps={"sampleAt","elapsed"},
}
local stages={BASELINE="Profiler loaded",VARIABLES_LOADED="Saved variables ready",PLAYER_LOGIN="Player login",PLAYER_ENTERING_WORLD="Entered world",SETTLE_SAMPLE="After entering world"}
local function Number(value)
    return type(value)=="number" and value==value and value>-1e300 and value<1e300 and value or nil
end
function Results.Value(schema,column,entry)
    local field=fields[schema] and fields[schema][column]
    if not field then return nil end
    if field=="average" then return (entry.count or 0)>0 and Number(entry.time) and Number(entry.time/entry.count) or (entry.count or 0)==0 and 0 or nil end
    if field=="stage" then return entry.event=="ADDON_LOADED" and entry.addon and "Loaded: "..entry.addon or stages[entry.event] or entry.event end
    if field=="failed" then return entry.failed and 1 or 0 end
    if (schema=="callbacks" or schema=="callbackDetails") and (field=="selfTime" or field=="time" or field=="peak") and entry.timedCalls==0 then return nil end
    if (schema=="memoryActivity" or schema=="callbackMemory") and (field=="heapRise" or field=="heapDelta" or field=="heapPeak") and (entry.heapSamples or 0)==0 then return nil end
    local value=entry[field]
    if field=="name" and value=="Roster refresh" and (schema=="operations" or schema=="slow") then value="Guild refresh" end
    if field=="sampleAt" and value==nil then value=entry.at end
    if type(value)=="number" then return Number(value) end
    return type(value)=="string" and value~="" and value or nil
end
function Results.NaturalLess(left,right)
    left,right=string.lower(tostring(left or "")),string.lower(tostring(right or ""))
    local a,b=1,1
    while a<=string.len(left) and b<=string.len(right) do
        local x,y=string.sub(left,a,a),string.sub(right,b,b)
        if string.find(x,"%d") and string.find(y,"%d") then
            local _,ax,ar=string.find(left,"(%d+)",a)
            local _,by,br=string.find(right,"(%d+)",b)
            local av,bv=string.gsub(ar,"^0+",""),string.gsub(br,"^0+","")
            if string.len(av)~=string.len(bv) then return string.len(av)<string.len(bv) end
            if av~=bv then return av<bv end
            a,b=ax+1,by+1
        else
            if x~=y then return x<y end
            a,b=a+1,b+1
        end
    end
    return string.len(left)-a<string.len(right)-b
end
function Results.IsBaseGame(entry,schema)
    local source=type(entry.source)=="string" and string.lower(string.gsub(entry.source,"\\","/")) or ""
    if string.sub(source,1,1)=="@" and (string.find(source,"[/@]interface/framexml/") or string.find(source,"[/@]interface/sharedxml/")) then return true end
    local owner=entry.owner
    if schema=="callbacks" or schema=="memoryActivity" then owner=owner or entry.name end
    if schema=="loginMemory" and entry.event=="ADDON_LOADED" then owner=entry.addon end
    return type(owner)=="string" and string.find(string.lower(owner),"^blizzard_")~=nil or false
end
function Results.CanFilterAddons(schema)
    return fields[schema]~=nil and schema~="heapDrops" and schema~="frameGaps"
end
function Results.IsAddonResult(entry,schema)
    if not Results.CanFilterAddons(schema) then return true end
    if schema=="operations" or schema=="slow" then return true end
    if schema=="loginMemory" then
        -- Keep the login milestones so the loading sequence remains readable.
        return entry.event~="ADDON_LOADED" or type(entry.addon)=="string" and entry.addon~="" and not Results.IsBaseGame(entry,schema)
    end
    local owner=entry.owner
    if owner==nil and (schema=="callbacks" or schema=="memoryActivity") then owner=entry.name end
    if type(owner)=="string" and owner~="" and string.lower(owner)~="unknown owner" and string.lower(owner)~="unknown" then
        return not Results.IsBaseGame(entry,schema)
    end
    local source=type(entry.source)=="string" and string.lower(string.gsub(entry.source,"\\","/")) or ""
    -- The file marker is essential: a chunk label or frame name proves no owner.
    local _,_,folder=string.find(source,"^@.*interface/addons/([^/]+)/")
    return folder~=nil and not string.find(folder,"^blizzard_") and true or false
end
function Results.Create()
    local view={rows={},order={}}
    view.compare=function(left,right)
        local a,b=Results.Value(view.schema,view.column,left),Results.Value(view.schema,view.column,right)
        if a==nil or b==nil then if a~=b then return a~=nil end
        elseif a~=b then
            local less
            if type(a)=="number" and type(b)=="number" then less=a<b
            else
                less=Results.NaturalLess(a,b)
                if not less and not Results.NaturalLess(b,a) then return view.order[left]<view.order[right] end
            end
            return view.descending and not less or not view.descending and less
        end
        return view.order[left]<view.order[right]
    end
    return view
end
function Results.Bind(view,source,schema,column,descending,onlyAddons,revision)
    if view.source==source and view.revision==revision and view.schema==schema and view.column==column and view.descending==descending and view.onlyAddons==onlyAddons then return view.rows end
    view.source,view.revision,view.schema,view.column,view.descending,view.onlyAddons=source,revision,schema,column,descending,onlyAddons
    for key in pairs(view.order) do view.order[key]=nil end
    local count=0
    for index,entry in ipairs(source) do
        if not onlyAddons or Results.IsAddonResult(entry,schema) then
            count=count+1
            if count<=table.getn(view.rows) then view.rows[count]=entry else table.insert(view.rows,entry) end
            view.order[entry]=index
        end
    end
    for index=table.getn(view.rows),count+1,-1 do table.remove(view.rows,index) end
    if column then table.sort(view.rows,view.compare) end
    return view.rows
end
