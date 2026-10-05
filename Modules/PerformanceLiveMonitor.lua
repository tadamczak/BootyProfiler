local P = BootyProfiler
local UI = BootyLib.UI.Components
P.Modules.Performance = P.Modules.Performance or {}

local function Memory(value)
    return type(value)=="number" and string.format("%.2f MB",value/1024) or "-"
end
local function Pair(current,threshold) return Memory(current).." / "..Memory(threshold) end
local healthColors={{0.72,0.72,0.72},{0.45,0.85,0.45},{1,0.78,0.25},{1,0.35,0.25}}
local function HealthHint() return this.monitorFrame.healthHint or "Checking recent FPS, latency and memory readings." end

function P.Modules.Performance.CreateLiveMonitor(backend,options)
    options=options or {}
    local frame=UI.CreateContainer(nil,UIParent)
    local defaultWidth,defaultHeight=360,360*572/1024
    local width,height=defaultWidth,defaultHeight
    if options.loadMonitorSize then
        local storedWidth,storedHeight=options.loadMonitorSize()
        if type(storedWidth)=="number" and storedWidth==storedWidth and storedWidth>0 and storedWidth<1e300
            and type(storedHeight)=="number" and storedHeight==storedHeight and storedHeight>0 and storedHeight<1e300 then
            width=math.max(300,math.min(720,storedWidth));height=math.max(148,math.min(460,storedHeight))
        end
    end
    frame.chosenWidth,frame.chosenHeight=width,height
    frame:SetPoint("CENTER",UIParent,"CENTER",280,100);frame:SetWidth(width);frame:SetHeight(height)
    frame:SetFrameStrata("FULLSCREEN_DIALOG");frame:SetMovable(true);frame:SetResizable(true);frame:EnableMouse(true);frame:RegisterForDrag("LeftButton")
    if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
    frame.title=UI.CreateHeading(frame,"Live Monitor",3,"gold","monitor");frame.title:SetPoint("TOPLEFT",frame,"TOPLEFT",6,-5)
    local font,_,flags=frame.title:GetFont();frame.title:SetFont(font,13,flags)
    frame.close=UI.CreateWindowButton(frame,nil,"close");frame.close:SetPoint("TOPRIGHT",frame,"TOPRIGHT",-4,-4)
    frame.close:SetScript("OnClick",function() frame:Close() end)
    frame.minimize=UI.CreateWindowButton(frame,nil,"minimize")
    frame.minimize:SetPoint("RIGHT",frame.close,"LEFT",-4,0)
    frame.art=UI.CreatePerformanceBackground(frame,0.22)
    frame.content=UI.CreateContainer(nil,frame);frame.content:SetAllPoints(frame)
    frame.values={};frame.labels={}
    frame.rowHits={}
    local names={"FPS","Memory / GC","Rate","Cleanup","Health"}
    local keys={"fps","memory","rate","cleanup","health"}
    local hints={"Current FPS sampled once per second; brief pauses can fall between readings.",
        "Current memory used by addons and UI / the memory level that triggers cleanup. This is not total game RAM.",
        "Net shared memory change per second. Cleanup can make it negative; this is not the amount of new memory allocated.",
        "Last observed memory decrease and its age. This is not GC duration.",HealthHint}
    for index,key in ipairs(keys) do
        local label=UI.CreateLabel(frame.content,nil,"OVERLAY","GameFontHighlightSmall")
        label:SetText(names[index]);label:SetTextColor(unpack(UI.Theme.colors.goldText))
        local labelFont,_,labelFlags=label:GetFont();label:SetFont(labelFont,12,labelFlags);label:SetJustifyV("MIDDLE")
        local value=UI.CreateLabel(frame.content,nil,"OVERLAY","GameFontHighlightSmall")
        local valueFont,_,valueFlags=value:GetFont();value:SetFont(valueFont,13,valueFlags);value:SetJustifyH("LEFT");value:SetJustifyV("MIDDLE")
        frame.labels[key]=label;frame.values[key]=value;frame[key]=value
        local hit=UI.CreateControl(nil,frame.content);hit.monitorFrame=frame;frame.rowHits[key]=hit
        UI.AttachTooltip(hit,names[index],hints[index])
    end
    local function ResizeBounds()
        local screenWidth=UIParent.GetWidth and UIParent:GetWidth() or 1024
        local screenHeight=UIParent.GetHeight and UIParent:GetHeight() or 768
        local maximumWidth=math.max(1,math.min(720,screenWidth-24))
        local maximumHeight=math.max(1,math.min(460,screenHeight-24))
        frame.minimumWidth,frame.minimumHeight=math.min(300,maximumWidth),math.min(148,maximumHeight)
        frame.maximumWidth,frame.maximumHeight=maximumWidth,maximumHeight
        frame:SetMinResize(frame.minimumWidth,frame.minimized and UI.Window.MinimizedHeight or frame.minimumHeight)
        frame:SetMaxResize(maximumWidth,frame.minimized and UI.Window.MinimizedHeight or maximumHeight)
        return frame.minimumWidth,frame.minimumHeight,maximumWidth,maximumHeight
    end
    function frame:Layout()
        if self.layoutRunning then return end
        self.layoutRunning=true
        local minWidth,minHeight,maxWidth,maxHeight=ResizeBounds()
        local width=math.max(minWidth,math.min(maxWidth,self:GetWidth()))
        local height=self.minimized and UI.Window.MinimizedHeight or math.max(minHeight,math.min(maxHeight,self:GetHeight()))
        if self:GetWidth()~=width then self:SetWidth(width) end
        if self:GetHeight()~=height then self:SetHeight(height) end
        UI.LayoutPerformanceBackground(self.art,self,width,height)
        self.title:ClearAllPoints();self.title:SetPoint("TOPLEFT",self,"TOPLEFT",8,self.minimized and -4 or -7)
        UI.FitButtonLabel(self.title,math.max(1,width-72));self.title:SetJustifyH("LEFT")
        if self.minimized then self.title:SetHeight(22) end
        self.close:ClearAllPoints();self.close:SetPoint("TOPRIGHT",self,"TOPRIGHT",-6,self.minimized and -4 or -6)
        if self.minimized then
            self.content:Hide();self.resizeGrip:Hide();self.projectDivider:Hide()
        else
            self.content:Show();self.resizeGrip:Show();self.projectDivider:Show()
            local spacing=math.max(1,(height-64)/4)
            local labelWidth=math.max(1,math.min(84,width-116))
            local valueLeft=math.min(104,math.max(12,width-12))
            local valueWidth=math.max(1,width-valueLeft-12)
            for index,key in ipairs(keys) do
                local label,value,hit=self.labels[key],self.values[key],self.rowHits[key]
                local top=-34-(index-1)*spacing
                label:ClearAllPoints();label:SetPoint("TOPLEFT",self.content,"TOPLEFT",12,top)
                UI.FitButtonLabel(label,labelWidth);label:SetJustifyH("LEFT")
                value:ClearAllPoints();value:SetPoint("TOPLEFT",self.content,"TOPLEFT",valueLeft,top)
                UI.FitButtonLabel(value,valueWidth);value:SetJustifyH("LEFT")
                hit:ClearAllPoints();hit:SetPoint("TOPLEFT",self.content,"TOPLEFT",12,top+2)
                hit:SetWidth(math.max(1,width-24));hit:SetHeight(math.max(1,math.min(24,spacing)))
            end
        end
        self.layoutRunning=false
    end
    local function RememberPosition()
        local left=frame.GetLeft and frame:GetLeft()
        local bottom=frame.GetBottom and frame:GetBottom()
        if type(left)=="number" and type(bottom)=="number" then
            frame.lastPositionLeft,frame.lastPositionBottom=left,bottom
            return left,bottom
        end
    end
    local function SetHeightKeepingTop(height)
        local left,bottom=RememberPosition()
        if left==nil then left,bottom=frame.lastPositionLeft,frame.lastPositionBottom end
        local oldHeight=frame:GetHeight()
        ResizeBounds();frame:SetHeight(height);frame:Layout()
        if type(left)=="number" and type(bottom)=="number" then
            local restoredBottom=bottom+oldHeight-frame:GetHeight()
            frame:ClearAllPoints();frame:SetPoint("BOTTOMLEFT",UIParent,"BOTTOMLEFT",left,restoredBottom)
            frame.lastPositionLeft,frame.lastPositionBottom=left,restoredBottom
        end
    end
    function frame:Refresh()
        if not self:IsVisible() or self.minimized then return end
        local state=backend.GetState()
        self.fps:SetText(type(state.fps)=="number" and tostring(math.floor(state.fps+0.5)) or "-")
        self.rate:SetText(type(state.rate)=="number" and string.format("%+.1f KB/s",state.rate) or "-")
        self.memory:SetText(Pair(state.heap,state.gcThreshold))
        local age=type(state.lastCleanupAge)=="number" and tostring(math.floor(state.lastCleanupAge)).."s ago" or "age unavailable"
        self.cleanup:SetText(state.lastCleanup and Memory(state.lastCleanup).." ("..age..")" or "-")
        local health=state.health
        self.health:SetText(health and health.status or "Checking")
        self.healthHint=health and health.reason or "Checking recent FPS, latency and memory readings."
        self.health:SetTextColor(unpack(healthColors[(health and health.severity or 0)+1] or healthColors[1]))
        local available=math.max(1,self:GetWidth()-116)
        for _,value in pairs(self.values) do UI.FitButtonLabel(value,available);value:SetJustifyH("LEFT") end
    end
    local function Updated() frame:Refresh() end
    local function Shown()
        if not frame:IsVisible() or frame.minimized then return false end
        RememberPosition()
        backend.SetListener(Updated)
        local ok=backend.SetVisible(true)
        if not ok then frame:Hide() end
        frame:Refresh();return ok
    end
    function frame:Open()
        if self.minimized then
            self.minimized=false;SetHeightKeepingTop(self.expandedHeight or defaultHeight)
            UI.SetWindowButtonAction(self.minimize,"minimize")
        else self:Layout() end
        self:Show();return Shown()
    end
    function frame:Close() RememberPosition();backend.SetVisible(false);self:Hide() end
    function frame:ToggleMinimize()
        local oldHeight=self:GetHeight()
        if self.minimized then
            self.minimized=false;SetHeightKeepingTop(self.expandedHeight or defaultHeight)
            UI.SetWindowButtonAction(self.minimize,"minimize")
        else
            self.expandedHeight=oldHeight;self.minimized=true
            backend.SetVisible(false);SetHeightKeepingTop(UI.Window.MinimizedHeight)
            UI.SetWindowButtonAction(self.minimize,"maximize")
        end
        if not self.minimized then Shown() end
    end
    frame.minimize:SetScript("OnClick",function() frame:ToggleMinimize() end)
    frame:SetScript("OnShow",Shown)
    frame:SetScript("OnHide",function() backend.SetVisible(false) end)
    UI.Window.StyleProjectDialog(frame)
    if UI.WindowStack then
        UI.WindowStack.SetOwner(frame,function() return P.host and P.host.window end)
    end
    frame:SetScript("OnDragStop",function() frame:StopMovingOrSizing();RememberPosition() end)
    frame.resizeGrip=UI.CreateResizeGrip(frame)
    UI.AttachTooltip(frame.resizeGrip,"Resize Live Monitor","Drag to change the window size.")
    frame.resizeGrip:SetScript("OnMouseDown",function() if not frame.minimized then frame:StartSizing("BOTTOMRIGHT") end end)
    frame.resizeGrip:SetScript("OnMouseUp",function()
        frame:StopMovingOrSizing();frame:Layout()
        if not frame.minimized and frame:IsVisible() then
            frame.chosenWidth,frame.chosenHeight=frame:GetWidth(),frame:GetHeight()
            if options.saveMonitorSize then options.saveMonitorSize(frame.chosenWidth,frame.chosenHeight) end
        end
    end)
    frame.resizeGrip:SetScript("OnHide",function() frame:StopMovingOrSizing() end)
    frame:SetScript("OnSizeChanged",function() frame:Layout() end)
    frame:Layout()
    frame:Hide()
    return frame
end
