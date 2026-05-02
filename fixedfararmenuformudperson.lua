-- ─── Cleanup ─────────────────────────────────────────────────────────────────
do
    if _G.__SA_Unhook then pcall(_G.__SA_Unhook); _G.__SA_Unhook = nil end
        local lp = game:GetService("Players").LocalPlayer
    local pg = lp:FindFirstChild("PlayerGui")
    if pg then
        for _, n in ipairs({"ESP_GUI","ESP_ARROW_GUI","ESP_FOV_GUI"}) do
            local g = pg:FindFirstChild(n); if g then g:Destroy() end
        end
    end
    local f = workspace:FindFirstChild("_ESP_Objects"); if f then f:Destroy() end
    task.wait(0.05)
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Lighting         = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

-- ─── Config ──────────────────────────────────────────────────────────────────
local CFG = {
    ENABLED              = true,
    TEAM_FILTER          = false,
    RADIUS               = 1200,
    REFRESH_RATE         = 0.041,
    SHOW_NAME            = false,
    SHOW_DIST            = true,
    SHOW_HEALTH          = true,
    LABEL_HIDE_DIST      = 120,
    ARROWS_ENABLED       = true,
    ARROW_RADIUS         = 67,
    ARROW_MARGIN         = 67,
    SILENT_AIM_ENABLED   = true,
    SA_BURST_LOCK        = true,
    SA_EXCLUDE           = {},
    AIM_BONE             = "Head",
    BONE_SWITCH_DIST     = 21,  -- past this distance switch to Torso priority
    BULLET_SPEED_EST     = 700,
    AIM_FOV              = 67,
    AIM_RADIUS           = 67,
    LOCK_TIME            = false,
    KEY_ESP              = Enum.KeyCode.K,
    KEY_PANEL            = Enum.KeyCode.P,
    KEY_PANIC            = Enum.KeyCode.End,
    COL_ENEMY            = Color3.fromRGB(255, 30, 180),
    COL_ON               = Color3.fromRGB(72, 199, 116),
    COL_SLIDER           = Color3.fromRGB(85, 165, 255),
    COL_PANEL_BG         = Color3.fromRGB(5, 5, 8),
    COL_ROW_BG           = Color3.fromRGB(10, 10, 15),
    COL_TITLE_BG         = Color3.fromRGB(4, 4, 6),
    EXCLUDED_NAMES       = { ["nil"] = true },
}
-- ─── State ───────────────────────────────────────────────────────────────────
local LocalPlayer  = Players.LocalPlayer
local Camera       = workspace.CurrentCamera
local ESPFolder    = Instance.new("Folder")
ESPFolder.Name     = "_ESP_Objects"; ESPFolder.Parent = workspace

local ESPObjects    = setmetatable({}, {__mode = "k"})
local wiredPlayers  = {}
local _panicActive  = false
local activeMainTab = "esp"

local _rayParams = RaycastParams.new()
_rayParams.FilterType  = Enum.RaycastFilterType.Exclude
_rayParams.IgnoreWater = true

-- ─── Frustum check ───────────────────────────────────────────────────────────
local function inFrustum(worldPos, margin)
    local sp, onScreen = Camera:WorldToViewportPoint(worldPos)
    if sp.Z <= 0 then return false end
    if onScreen then return true end
    if margin and margin > 0 then
        local vp = Camera.ViewportSize
        return sp.X >= -margin and sp.X <= vp.X+margin
           and sp.Y >= -margin and sp.Y <= vp.Y+margin
    end
    return false
end

-- ─── Core helpers ─────────────────────────────────────────────────────────────
local function isExcluded(p) return p == LocalPlayer or CFG.EXCLUDED_NAMES[p.Name] end
local function getRootPart(p)
    local c = p.Character; if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChildWhichIsA("BasePart")
end
local function getDist(part)
    local my = getRootPart(LocalPlayer); if not my then return math.huge end
    return (part.Position - my.Position).Magnitude
end
local function getColor() return CFG.COL_ENEMY end
local function isTeammate(p) return p.Team ~= nil and p.Team == LocalPlayer.Team end
local function isVisible(part, char)
    local myChar = LocalPlayer.Character
    local clean  = {ESPFolder}
    if myChar then table.insert(clean, myChar) end
    if char   then table.insert(clean, char)   end
    table.insert(clean, Camera)
    _rayParams.FilterDescendantsInstances = clean
    local origin = Camera.CFrame.Position
    local dir    = part.Position - origin
    return workspace:Raycast(origin, dir * 0.99, _rayParams) == nil
end

-- ─── Velocity & Acceleration Tracking ───────────────────────────────────────
local _tgtPrevPos  = setmetatable({}, {__mode="k"})
local _tgtPrevVel  = setmetatable({}, {__mode="k"})
local _tgtPrevTick = setmetatable({}, {__mode="k"})

local function estimateVelocity(part)
    local now = tick()
    local pos = part.Position
    local vel = Vector3.zero
    local acc = Vector3.zero

    if _tgtPrevPos[part] and _tgtPrevTick[part] then
        local dt = now - _tgtPrevTick[part]
        if dt > 0.001 and dt < 0.5 then
            vel = (pos - _tgtPrevPos[part]) / dt
            if _tgtPrevVel[part] then
                acc = (vel - _tgtPrevVel[part]) / dt
                local accMag = acc.Magnitude
                if accMag > 200 then acc = acc * (200 / accMag) end
            end
        end
    end
    _tgtPrevPos[part]  = pos
    _tgtPrevVel[part]  = vel
    _tgtPrevTick[part] = now
    return vel, acc
end

local function predictedAimPos(pos, vel, acc, bulletOrigin)
    local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local myVel  = myRoot and myRoot.AssemblyLinearVelocity or Vector3.zero
    local spd    = math.max(CFG.BULLET_SPEED_EST, 1)
    local travelT = (pos - bulletOrigin).Magnitude / spd
    local predicted = pos
    for _ = 1, 3 do
        local relVel = vel - myVel
        predicted = pos + relVel * travelT + acc * (0.5 * travelT * travelT)
        local newDist = (predicted - bulletOrigin).Magnitude
        travelT = newDist / spd
    end
    local maxLead = (pos - bulletOrigin).Magnitude * 0.6
    local lead = (predicted - pos).Magnitude
    if lead > maxLead then
        predicted = pos + (predicted - pos) * (maxLead / lead)
    end
    return predicted
end

-- ─── Silent Aim ──────────────────────────────────────────────────────────────

local SA_LIMBS = {"Head","Torso","Left Arm","Right Arm","Left Leg","Right Leg"}

local _saRP = RaycastParams.new()
_saRP.FilterType  = Enum.RaycastFilterType.Exclude
_saRP.IgnoreWater = true

local function saLOS(part, targetChar)
    local myChar = LocalPlayer.Character
    local filter = {ESPFolder, Camera}
    if myChar    then table.insert(filter, myChar)    end
    if targetChar then table.insert(filter, targetChar) end
    _saRP.FilterDescendantsInstances = filter
    local origin = Camera.CFrame.Position
    local dir    = part.Position - origin
    return workspace:Raycast(origin, dir * 0.99, _saRP) == nil
end

local function bestVisiblePart(char, requireLOS)
    local root = char:FindFirstChild("HumanoidRootPart")
    local dist = root and getDist(root) or 0

    -- Switch to Torso priority at range — bigger target, easier to hit
    local pref, fall
    if dist >= CFG.BONE_SWITCH_DIST then
        pref = "Torso"; fall = CFG.AIM_BONE == "Torso" and "Head" or CFG.AIM_BONE
    else
        pref = CFG.AIM_BONE
        fall = pref == "Head" and "Torso" or "Head"
    end

    local pp = char:FindFirstChild(pref)
    if pp and saLOS(pp, char) then return pp, true end
    local fp = char:FindFirstChild(fall)
    if fp and saLOS(fp, char) then return fp, true end
    for _, pn in ipairs(SA_LIMBS) do
        if pn ~= pref and pn ~= fall then
            local lp2 = char:FindFirstChild(pn)
            if lp2 and saLOS(lp2, char) then return lp2, true end
        end
    end
    if requireLOS then return nil, false end
    return char:FindFirstChild(pref) or char:FindFirstChild(fall), false
end

local function findSilentTarget()
    local vp   = Camera.ViewportSize
    local cx   = vp.X * 0.5
    local cy   = vp.Y * 0.5
    local fov2 = CFG.AIM_FOV * CFG.AIM_FOV
    local bestP, bestPart, bestDist = nil, nil, math.huge

    for _, p in ipairs(Players:GetPlayers()) do
        if isExcluded(p) then continue end
        if CFG.SA_EXCLUDE[p.Name] then continue end
        local char = p.Character; if not char then continue end
        local hum  = char:FindFirstChildWhichIsA("Humanoid")
        if not hum or hum.Health <= 0 then continue end
        if hum:GetState() == Enum.HumanoidStateType.Dead then continue end
        local root = char:FindFirstChild("HumanoidRootPart"); if not root then continue end

        local inFOV = false
        local sp = Camera:WorldToViewportPoint(root.Position)
        if sp.Z > 0 then
            local dx, dy = sp.X-cx, sp.Y-cy
            if dx*dx+dy*dy < fov2 then inFOV = true end
        end
        if not inFOV then
            for _, pn in ipairs(SA_LIMBS) do
                local lp2 = char:FindFirstChild(pn); if not lp2 then continue end
                local lsp = Camera:WorldToViewportPoint(lp2.Position)
                if lsp.Z > 0 then
                    local ldx, ldy = lsp.X-cx, lsp.Y-cy
                    if ldx*ldx+ldy*ldy < fov2 then inFOV = true; break end
                end
            end
        end
        if not inFOV then continue end

        local part, hasLOS = bestVisiblePart(char, false)
        if not part or not hasLOS then continue end

        local d = getDist(root)
        if d < bestDist then
            bestP, bestPart, bestDist = p, part, d
        end
    end

    return bestP, bestPart
end

-- Burst lock state
local _burstTarget = nil
local _burstPlayer = nil
local _burstActive = false
local _mouseHeld   = false

local function getBurstTarget()
    if not _burstActive then return nil, nil end
    if not _burstTarget or not _burstTarget.Parent then
        _burstActive = false; return nil, nil
    end
    local char = _burstPlayer and _burstPlayer.Character
    if not char then _burstActive = false; return nil, nil end
    local hum = char:FindFirstChildWhichIsA("Humanoid")
    if not hum or hum.Health <= 0 then _burstActive = false; return nil, nil end
    if hum:GetState() == Enum.HumanoidStateType.Dead then _burstActive = false; return nil, nil end
    return _burstPlayer, _burstTarget
end

UserInputService.InputBegan:Connect(function(inp)
    if inp.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    _mouseHeld    = true
    if not CFG.SILENT_AIM_ENABLED then return end
    local p, part = findSilentTarget()
    if p and part and CFG.SA_BURST_LOCK then
        _burstTarget = part; _burstPlayer = p; _burstActive = true
    end
end)

UserInputService.InputEnded:Connect(function(inp)
    if inp.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    _mouseHeld    = false
    _burstActive  = false
    _burstTarget  = nil
    _burstPlayer  = nil
end)

local _muzzle        = nil
local _muzzleNatural = nil
local _prevTarget    = nil

local function getMuzzle()
    if _muzzle and _muzzle.Parent then return _muzzle end
    _muzzle = nil
    for _, obj in ipairs(Camera:GetDescendants()) do
        if obj.Name == "Muzzle" and obj:IsA("Attachment") then
            _muzzle = obj; break
        end
    end
    return _muzzle
end

RunService:BindToRenderStep("SA_Muzzle", Enum.RenderPriority.Last.Value + 1, function()
    local muzzle = getMuzzle()
    if not muzzle then
        _muzzleNatural = nil
        _prevTarget    = nil
        return
    end

    local naturalCF = muzzle.CFrame

    if not CFG.SILENT_AIM_ENABLED then
        if _muzzleNatural then
            pcall(function() muzzle.CFrame = _muzzleNatural end)
            _muzzleNatural = nil
        end
        _prevTarget = nil
        return
    end

    local tp, tpart = getBurstTarget()
    if not tp then tp, tpart = findSilentTarget() end

    if not tp or not tpart then
        if _muzzleNatural then
            pcall(function() muzzle.CFrame = _muzzleNatural end)
            _muzzleNatural = nil
        end
        _prevTarget = nil
        return
    end

    if not _muzzleNatural then
        _muzzleNatural = naturalCF
    end
    _prevTarget = tpart

    pcall(function()
        local origin = Camera.CFrame.Position
        local vel, acc = estimateVelocity(tpart)
        local ledPos = predictedAimPos(tpart.Position, vel, acc, origin)
        local dir    = (ledPos - origin)
        if dir.Magnitude < 0.001 then return end
        dir = dir.Unit
        local upRef  = math.abs(dir.Y) > 0.99 and Vector3.new(1,0,0) or Vector3.new(0,1,0)
        local aimWorld = CFrame.lookAt(muzzle.WorldPosition, muzzle.WorldPosition + dir, upRef)
        muzzle.CFrame  = muzzle.Parent.CFrame:Inverse() * aimWorld
    end)
end)

_G.__SA_Unhook = function()
    pcall(function() RunService:UnbindFromRenderStep("SA_Muzzle") end)
end

-- ─── ESP objects ────────────────────────────────────────────────────────────
local function createESP(p)
    if isExcluded(p) or ESPObjects[p] then return end
    local obj = {}

    local hl = Instance.new("Highlight")
    hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
    hl.OutlineColor=CFG.COL_ENEMY; hl.FillColor=CFG.COL_ENEMY
    hl.OutlineTransparency=0; hl.FillTransparency=1
    hl.Enabled=false; hl.Parent=ESPFolder; obj.hl=hl

    local bb = Instance.new("BillboardGui")
    bb.Size=UDim2.new(0,120,0,24); bb.StudsOffset=Vector3.new(0,3,0)
    bb.AlwaysOnTop=true; bb.ResetOnSpawn=false; bb.Enabled=false; bb.Parent=ESPFolder; obj.bb=bb
    local nameL = Instance.new("TextLabel",bb)
    nameL.Size=UDim2.new(1,0,0,14); nameL.BackgroundTransparency=1
    nameL.Font=Enum.Font.GothamBold; nameL.TextSize=10; nameL.TextXAlignment=Enum.TextXAlignment.Center
    nameL.TextStrokeTransparency=0.3; nameL.TextStrokeColor3=Color3.new(0,0,0); nameL.Text=p.Name; obj.nameL=nameL
    local distL = Instance.new("TextLabel",bb)
    distL.Size=UDim2.new(1,0,0,10); distL.Position=UDim2.new(0,0,0,14)
    distL.BackgroundTransparency=1; distL.Font=Enum.Font.Gotham; distL.TextSize=8
    distL.TextXAlignment=Enum.TextXAlignment.Center; distL.TextColor3=Color3.fromRGB(190,190,190)
    distL.TextStrokeTransparency=0.45; distL.TextStrokeColor3=Color3.new(0,0,0); obj.distL=distL

    local hbb = Instance.new("BillboardGui")
    hbb.Size=UDim2.new(0,4,0,46); hbb.StudsOffset=Vector3.new(1.4,0,0)
    hbb.AlwaysOnTop=true; hbb.ResetOnSpawn=false; hbb.Enabled=false; hbb.Parent=ESPFolder; obj.hbb=hbb
    local hBG = Instance.new("Frame",hbb)
    hBG.Size=UDim2.new(1,0,1,0); hBG.BackgroundColor3=Color3.fromRGB(14,14,20)
    hBG.BorderSizePixel=0; Instance.new("UICorner",hBG).CornerRadius=UDim.new(1,0); obj.hBG=hBG
    local hBar = Instance.new("Frame",hBG)
    hBar.AnchorPoint=Vector2.new(0,1); hBar.Size=UDim2.new(1,0,1,0)
    hBar.Position=UDim2.new(0,0,1,0); hBar.BorderSizePixel=0
    Instance.new("UICorner",hBar).CornerRadius=UDim.new(1,0); obj.hBar=hBar
    ESPObjects[p] = obj
end

local function removeESP(p)
    local o = ESPObjects[p]; if not o then return end
    if o.hl  then o.hl:Destroy()  end
    if o.bb  then o.bb:Destroy()  end
    if o.hbb then o.hbb:Destroy() end
    ESPObjects[p] = nil
end

local function updateESP(p)
    local o = ESPObjects[p]; if not o then return end
    local char = p.Character
    local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
    local root = char and getRootPart(p)
    local d    = root and getDist(root) or math.huge
    local show = CFG.ENABLED and root and hum and hum.Health > 0
        and (not CFG.TEAM_FILTER or not isTeammate(p)) and d <= CFG.RADIUS

    if show and root and not inFrustum(root.Position, 120) then
        o.hl.Enabled=false; o.bb.Enabled=false; if o.hbb then o.hbb.Enabled=false end; return
    end

    local hl = o.hl
    if show and char then
        local saExcluded = CFG.SA_EXCLUDE and CFG.SA_EXCLUDE[p.Name]
        local col = saExcluded and Color3.fromRGB(0,255,80) or CFG.COL_ENEMY
        hl.Adornee=nil
        hl.OutlineColor=col; hl.FillColor=col
        hl.FillTransparency=1; hl.OutlineTransparency=0
        hl.Adornee=char; hl.Enabled=true
    else
        hl.Enabled=false; hl.Adornee=nil
    end

    local bb = o.bb; local labelsVisible = show and d <= CFG.LABEL_HIDE_DIST
    if show and root then
        bb.Adornee=root; bb.Enabled=true
        o.nameL.TextColor3=getColor(); o.nameL.Visible=CFG.SHOW_NAME and labelsVisible
        o.distL.Text=CFG.SHOW_DIST and string.format("%.0f st",d) or ""; o.distL.Visible=CFG.SHOW_DIST and labelsVisible
        if hum and CFG.SHOW_HEALTH and labelsVisible then
            local pct=math.clamp(hum.Health/hum.MaxHealth,0,1)
            o.hBar.Size=UDim2.new(1,0,pct,0)
            o.hBar.BackgroundColor3=Color3.fromHSV(pct*0.33,1,1)
            o.hBG.Visible=true
            o.hbb.Adornee=root; o.hbb.Enabled=true
        else
            o.hBG.Visible=false
            if o.hbb then o.hbb.Enabled=false end
        end
    else
        bb.Enabled=false
        if o.hbb then o.hbb.Enabled=false end
    end
end

-- ─── Player wiring ───────────────────────────────────────────────────────────
local function wirePlayer(p)
    if wiredPlayers[p] then return end; wiredPlayers[p]=true
    p.CharacterAdded:Connect(function(char)
        if ESPObjects[p] then removeESP(p) end
        char:WaitForChild("HumanoidRootPart", 10)
        char:WaitForChild("Humanoid", 10)
        char:WaitForChild("Torso", 5)
        char:WaitForChild("Head", 5)
        task.wait(0.2)
        createESP(p)
    end)
end
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.25)
    for p in pairs(ESPObjects) do removeESP(p) end
    task.wait(0.05)
    for _, p in ipairs(Players:GetPlayers()) do
        if not isExcluded(p) and p.Character then createESP(p) end
    end
end)
local function refreshPlayers()
    for _, p in ipairs(Players:GetPlayers()) do
        if not isExcluded(p) then
            if not ESPObjects[p] then createESP(p) end; wirePlayer(p)
        end
    end
    for p in pairs(ESPObjects) do
        if not p:IsDescendantOf(Players) then removeESP(p); wiredPlayers[p]=nil end
    end
end
Players.PlayerAdded:Connect(function(p)
    if isExcluded(p) then return end; wirePlayer(p)
    if p.Character then createESP(p)
    else p.CharacterAdded:Wait(); task.wait(0.15); if not ESPObjects[p] then createESP(p) end end
end)
Players.PlayerRemoving:Connect(function(p) removeESP(p); wiredPlayers[p]=nil end)

-- ─── GUI ─────────────────────────────────────────────────────────────────────

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local function corner(p,r) Instance.new("UICorner",p).CornerRadius=UDim.new(0,r or 8) end
local function uiStroke(p,col,thick,trans)
    local s=Instance.new("UIStroke",p); s.Color=col; s.Thickness=thick or 1; s.Transparency=trans or 0
end

-- ─── Main Panel ──────────────────────────────────────────────────────────────
local screenGui = Instance.new("ScreenGui")
screenGui.Name="ESP_GUI"; screenGui.ResetOnSpawn=false
screenGui.IgnoreGuiInset=true; screenGui.Parent=PlayerGui

local PW=272; local PANEL_H=490

local panel = Instance.new("Frame",screenGui)
panel.Name="Panel"; panel.Size=UDim2.new(0,PW,0,PANEL_H)
local _savedPos = _G.__FARAR_PanelPos
local savedY = _savedPos and _savedPos.y
panel.Position = savedY and UDim2.new(0,_savedPos.x,0,savedY)
    or UDim2.new(0,14,0.5,-PANEL_H/2)
panel.BackgroundColor3=CFG.COL_PANEL_BG; panel.BorderSizePixel=0
panel.Visible=false; panel.ClipsDescendants=true
corner(panel,14)

local panelStroke=Instance.new("UIStroke",panel)
panelStroke.Color=Color3.fromRGB(255,30,180); panelStroke.Thickness=1.5; panelStroke.Transparency=0.3

local titleBar=Instance.new("Frame",panel)
titleBar.Size=UDim2.new(1,0,0,46); titleBar.BackgroundColor3=CFG.COL_TITLE_BG
titleBar.BorderSizePixel=0; corner(titleBar,14)
local tbFix=Instance.new("Frame",titleBar); tbFix.Size=UDim2.new(1,0,0.5,0)
tbFix.Position=UDim2.new(0,0,0.5,0); tbFix.BackgroundColor3=CFG.COL_TITLE_BG; tbFix.BorderSizePixel=0

local titleTxt=Instance.new("TextLabel",titleBar)
titleTxt.Size=UDim2.new(1,-60,1,0); titleTxt.Position=UDim2.new(0,14,0,0)
titleTxt.BackgroundTransparency=1; titleTxt.Text="hummus pudding (with peanut butter)"
titleTxt.Font=Enum.Font.GothamBold; titleTxt.TextSize=9
titleTxt.TextScaled=false; titleTxt.TextTruncate=Enum.TextTruncate.None
titleTxt.TextColor3=Color3.fromRGB(255,30,180); titleTxt.TextXAlignment=Enum.TextXAlignment.Left
titleTxt.TextStrokeColor3=Color3.fromRGB(60,0,30); titleTxt.TextStrokeTransparency=0.4

local titleLine=Instance.new("Frame",panel)
titleLine.Size=UDim2.new(1,-28,0,1); titleLine.Position=UDim2.new(0,14,0,46)
titleLine.BackgroundColor3=Color3.fromRGB(255,30,180); titleLine.BorderSizePixel=0
titleLine.BackgroundTransparency=0.55

local tabBar=Instance.new("Frame",panel); tabBar.Size=UDim2.new(1,-14,0,28)
tabBar.Position=UDim2.new(0,7,0,50); tabBar.BackgroundColor3=Color3.fromRGB(4,4,6)
tabBar.BorderSizePixel=0; corner(tabBar,8)
local function makeTabBtn(txt,xScale)
    local b=Instance.new("TextButton",tabBar); b.Size=UDim2.new(0.5,-3,1,-6)
    b.Position=UDim2.new(xScale,xScale==0 and 3 or -3,0,3)
    b.BackgroundColor3=CFG.COL_ROW_BG; b.Text=txt; b.TextColor3=Color3.fromRGB(80,70,90)
    b.TextSize=11; b.Font=Enum.Font.GothamBold; b.BorderSizePixel=0; corner(b,6); return b
end
local tabESPBtn=makeTabBtn("ESP",0); local tabToolsBtn=makeTabBtn("Tools",0.5)

local hintRow=Instance.new("Frame",panel); hintRow.Size=UDim2.new(1,0,0,14)
hintRow.Position=UDim2.new(0,0,0,81); hintRow.BackgroundTransparency=1
local hintTxt=Instance.new("TextLabel",hintRow); hintTxt.Size=UDim2.new(1,0,1,0)
hintTxt.BackgroundTransparency=1; hintTxt.Font=Enum.Font.Gotham; hintTxt.TextSize=8
hintTxt.TextColor3=Color3.fromRGB(100,50,80); hintTxt.TextXAlignment=Enum.TextXAlignment.Center
local function refreshHint()
    hintTxt.Text=string.format("[%s] ESP  [%s] Panel  [End] Panic",
        CFG.KEY_ESP.Name,CFG.KEY_PANEL.Name)
end; refreshHint()

local statusBar=Instance.new("Frame",panel); statusBar.Size=UDim2.new(1,-14,0,22)
statusBar.Position=UDim2.new(0,7,1,-28); statusBar.BackgroundColor3=Color3.fromRGB(4,4,6)
statusBar.BorderSizePixel=0; corner(statusBar,6)
uiStroke(statusBar,Color3.fromRGB(255,30,180),1,0.75)
local statusTxt=Instance.new("TextLabel",statusBar); statusTxt.Size=UDim2.new(1,-10,1,0)
statusTxt.Position=UDim2.new(0,10,0,0); statusTxt.BackgroundTransparency=1
statusTxt.Font=Enum.Font.Gotham; statusTxt.TextSize=8; statusTxt.TextXAlignment=Enum.TextXAlignment.Left
statusTxt.TextColor3=Color3.fromRGB(200,160,190)

local ESP_SCROLL_TOP=97; local ESP_SCROLL_H=PANEL_H-ESP_SCROLL_TOP-34
local espScroll=Instance.new("ScrollingFrame",panel)
espScroll.Size=UDim2.new(1,-8,0,ESP_SCROLL_H); espScroll.Position=UDim2.new(0,4,0,ESP_SCROLL_TOP)
espScroll.BackgroundTransparency=1; espScroll.BorderSizePixel=0
espScroll.ScrollBarThickness=2; espScroll.ScrollBarImageColor3=Color3.fromRGB(255,30,180)
espScroll.CanvasSize=UDim2.new(0,0,0,0); espScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
espScroll.ScrollingDirection=Enum.ScrollingDirection.Y
local list=Instance.new("Frame",espScroll); list.Size=UDim2.new(1,0,0,0)
list.AutomaticSize=Enum.AutomaticSize.Y; list.BackgroundTransparency=1
local listLayout=Instance.new("UIListLayout",list)
listLayout.Padding=UDim.new(0,3); listLayout.SortOrder=Enum.SortOrder.LayoutOrder
local listPad=Instance.new("UIPadding",list)
listPad.PaddingLeft=UDim.new(0,6); listPad.PaddingRight=UDim.new(0,6)
listPad.PaddingTop=UDim.new(0,4); listPad.PaddingBottom=UDim.new(0,6)

-- ─── Tools tab ───────────────────────────────────────────────────────────────
local toolsContent=Instance.new("Frame",panel)
toolsContent.Size=UDim2.new(1,0,0,PANEL_H-74); toolsContent.Position=UDim2.new(0,0,0,74)
toolsContent.BackgroundTransparency=1; toolsContent.Visible=false

local tSearch=Instance.new("TextBox",toolsContent)
tSearch.Size=UDim2.new(1,-14,0,24); tSearch.Position=UDim2.new(0,7,0,4)
tSearch.BackgroundColor3=CFG.COL_ROW_BG; tSearch.BorderSizePixel=0
tSearch.PlaceholderText="Search tools..."; tSearch.Text=""
tSearch.TextColor3=Color3.fromRGB(200,200,220); tSearch.PlaceholderColor3=Color3.fromRGB(70,70,100)
tSearch.TextSize=10; tSearch.Font=Enum.Font.Gotham; tSearch.ClearTextOnFocus=false; corner(tSearch,6)
local spPad=Instance.new("UIPadding",tSearch); spPad.PaddingLeft=UDim.new(0,8)

local TTOP=32
local availBtn=Instance.new("TextButton",toolsContent)
availBtn.Size=UDim2.new(0.5,-8,0,22); availBtn.Position=UDim2.new(0,7,0,TTOP)
availBtn.BackgroundColor3=Color3.fromRGB(40,10,30); availBtn.BorderSizePixel=0
availBtn.Text="Available"; availBtn.TextColor3=Color3.fromRGB(255,30,180)
availBtn.TextSize=10; availBtn.Font=Enum.Font.GothamBold; corner(availBtn,6)
uiStroke(availBtn,Color3.fromRGB(255,30,180),1,0.5)

local invBtn=Instance.new("TextButton",toolsContent)
invBtn.Size=UDim2.new(0.5,-8,0,22); invBtn.Position=UDim2.new(0.5,1,0,TTOP)
invBtn.BackgroundColor3=CFG.COL_ROW_BG; invBtn.BorderSizePixel=0
invBtn.Text="Inventory"; invBtn.TextColor3=Color3.fromRGB(80,70,90)
invBtn.TextSize=10; invBtn.Font=Enum.Font.GothamBold; corner(invBtn,6)

local TS_TOP=58; local TS_H=PANEL_H-74-TS_TOP-36
local toolScroll=Instance.new("ScrollingFrame",toolsContent)
toolScroll.Size=UDim2.new(1,-14,0,TS_H); toolScroll.Position=UDim2.new(0,7,0,TS_TOP)
toolScroll.BackgroundTransparency=1; toolScroll.BorderSizePixel=0
toolScroll.ScrollBarThickness=2; toolScroll.ScrollBarImageColor3=Color3.fromRGB(255,30,180)
toolScroll.CanvasSize=UDim2.new(0,0,0,0); toolScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
toolScroll.ScrollingDirection=Enum.ScrollingDirection.Y
local tsLayout=Instance.new("UIListLayout",toolScroll)
tsLayout.Padding=UDim.new(0,3); tsLayout.SortOrder=Enum.SortOrder.LayoutOrder

local takeAllB=Instance.new("TextButton",toolsContent)
takeAllB.Size=UDim2.new(1,-14,0,26); takeAllB.Position=UDim2.new(0,7,0,TS_TOP+TS_H+4)
takeAllB.BackgroundColor3=Color3.fromRGB(35,90,55); takeAllB.BorderSizePixel=0
takeAllB.Text="Take ALL"; takeAllB.TextColor3=Color3.fromRGB(220,220,235)
takeAllB.TextSize=10; takeAllB.Font=Enum.Font.GothamBold; corner(takeAllB,6)

local claimed={}
local function isTool(o) return o:IsA("Tool") or o:IsA("HopperBin") end
local function isOwnedByPlayer(obj)
    for _,p in ipairs(Players:GetPlayers()) do
        local bp=p:FindFirstChildOfClass("Backpack")
        if (bp and obj:IsDescendantOf(bp)) or (p.Character and obj:IsDescendantOf(p.Character)) then return true end
    end; return false
end
local function claimTool(t) claimed[t]=true end
local function unclaimTool(t) claimed[t]=nil end

local function makeToolRow(parent, name, sub, btnTxt, btnCol, onClick)
    local row=Instance.new("Frame",parent); row.Size=UDim2.new(1,0,0,30)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; corner(row,6)
    local nl=Instance.new("TextLabel",row); nl.Size=UDim2.new(1,-70,0,16); nl.Position=UDim2.new(0,8,0,2)
    nl.BackgroundTransparency=1; nl.Font=Enum.Font.GothamBold; nl.TextSize=10
    nl.TextColor3=Color3.fromRGB(210,210,240); nl.TextXAlignment=Enum.TextXAlignment.Left
    nl.TextTruncate=Enum.TextTruncate.AtEnd; nl.Text=name
    local sl=Instance.new("TextLabel",row); sl.Size=UDim2.new(1,-70,0,10); sl.Position=UDim2.new(0,8,0,18)
    sl.BackgroundTransparency=1; sl.Font=Enum.Font.Gotham; sl.TextSize=8
    sl.TextColor3=Color3.fromRGB(90,90,120); sl.TextXAlignment=Enum.TextXAlignment.Left; sl.Text=sub
    local btn=Instance.new("TextButton",row); btn.Size=UDim2.new(0,52,0,20); btn.Position=UDim2.new(1,-58,0.5,-10)
    btn.BackgroundColor3=btnCol; btn.Text=btnTxt; btn.TextColor3=Color3.fromRGB(230,230,245)
    btn.TextSize=9; btn.Font=Enum.Font.GothamBold; btn.BorderSizePixel=0; corner(btn,5)
    btn.MouseButton1Click:Connect(function() onClick(); row:Destroy() end)
end

local function makeSectionHeader(txt)
    local h=Instance.new("Frame",toolScroll); h.Size=UDim2.new(1,0,0,20)
    h.BackgroundColor3=Color3.fromRGB(40,10,30); h.BorderSizePixel=0; corner(h,5)
    local l=Instance.new("TextLabel",h); l.Size=UDim2.new(1,-8,1,0); l.Position=UDim2.new(0,8,0,0)
    l.BackgroundTransparency=1; l.Text=txt; l.Font=Enum.Font.GothamBold; l.TextSize=9
    l.TextColor3=Color3.fromRGB(255,30,180); l.TextXAlignment=Enum.TextXAlignment.Left
end

local function makeEmpty(txt)
    local l=Instance.new("TextLabel",toolScroll); l.Size=UDim2.new(1,0,0,30)
    l.BackgroundTransparency=1; l.Font=Enum.Font.Gotham; l.TextSize=10
    l.TextColor3=Color3.fromRGB(80,60,80); l.Text=txt; l.TextXAlignment=Enum.TextXAlignment.Center
end

local _showMyTools=false

local TOOL_SVCS = {
    {name="Workspace",      svc=workspace},
    {name="ReplicatedStorage", svc=game:GetService("ReplicatedStorage")},
    {name="ReplicatedFirst",svc=game:GetService("ReplicatedFirst")},
    {name="Lighting",       svc=Lighting},
    {name="StarterPack",    svc=game:GetService("StarterPack")},
    {name="StarterGui",     svc=game:GetService("StarterGui")},
}

local function buildTools()
    for _,c in ipairs(toolScroll:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
    local q=tSearch.Text:lower()
    if _showMyTools then
        takeAllB.Visible=false
        local tools={}
        local bp=LocalPlayer:FindFirstChildOfClass("Backpack")
        if bp then for _,o in ipairs(bp:GetChildren()) do if isTool(o) then table.insert(tools,{o,"Backpack"}) end end end
        if LocalPlayer.Character then
            for _,o in ipairs(LocalPlayer.Character:GetChildren()) do if isTool(o) then table.insert(tools,{o,"Equipped"}) end end
        end
        if #tools==0 then makeEmpty("inventory empty") return end
        for _,e in ipairs(tools) do
            local t,lbl=e[1],e[2]
            if q=="" or t.Name:lower():find(q,1,true) then
                makeToolRow(toolScroll,t.Name,lbl,"Drop",Color3.fromRGB(120,30,30),function()
                    if t and t.Parent then t.Parent=nil end; unclaimTool(t)
                end)
            end
        end
    else
        takeAllB.Visible=true
        local found={}
        for _,e in ipairs(TOOL_SVCS) do
            local ok,desc=pcall(function() return e.svc:GetDescendants() end); if not ok then continue end
            for _,o in ipairs(desc) do
                if isTool(o) and not isOwnedByPlayer(o) and not claimed[o] then
                    if q=="" or o.Name:lower():find(q,1,true) then
                        table.insert(found,{tool=o,src=e.name})
                    end
                end
            end
        end
        if #found==0 then makeEmpty("no tools found") return end
        makeSectionHeader("Available ("..#found..")")
        for _,e in ipairs(found) do
            local t=e.tool; local src=e.src
            makeToolRow(toolScroll,t.Name,src,"Take",CFG.COL_ENEMY,function()
                if t and t.Parent then t.Parent=LocalPlayer.Backpack end; claimTool(t)
            end)
        end
    end
end

local function setToolTab(mine)
    _showMyTools=mine
    availBtn.BackgroundColor3=mine and CFG.COL_ROW_BG or Color3.fromRGB(40,10,30)
    availBtn.TextColor3=mine and Color3.fromRGB(80,70,90) or Color3.fromRGB(255,30,180)
    invBtn.BackgroundColor3=mine and Color3.fromRGB(40,10,30) or CFG.COL_ROW_BG
    invBtn.TextColor3=mine and Color3.fromRGB(255,30,180) or Color3.fromRGB(80,70,90)
    buildTools()
end
availBtn.MouseButton1Click:Connect(function() setToolTab(false) end)
invBtn.MouseButton1Click:Connect(function() setToolTab(true) end)
tSearch:GetPropertyChangedSignal("Text"):Connect(function() buildTools() end)
takeAllB.MouseButton1Click:Connect(function()
    for _,p in ipairs(Players:GetPlayers()) do
        if p==LocalPlayer then continue end
        local function take(c) if not c then return end
            local ok,desc=pcall(function() return c:GetDescendants() end); if not ok then return end
            for _,o in ipairs(desc) do if isTool(o) and not claimed[o] then
                o.Parent=LocalPlayer.Backpack; claimTool(o); task.wait()
            end end
        end
        take(p:FindFirstChildOfClass("Backpack")); take(p.Character)
    end; buildTools()
end)

local _toolsWasOpen = false

local function setMainTab(tab)
    activeMainTab=tab; local onESP=tab=="esp"
    local pink=Color3.fromRGB(255,30,180); local dim=Color3.fromRGB(80,70,90)
    tabESPBtn.BackgroundColor3   = onESP and Color3.fromRGB(40,10,30) or CFG.COL_ROW_BG
    tabESPBtn.TextColor3         = onESP and pink or dim
    tabToolsBtn.BackgroundColor3 = onESP and CFG.COL_ROW_BG or Color3.fromRGB(40,10,30)
    tabToolsBtn.TextColor3       = onESP and dim or pink
    espScroll.Visible=onESP; hintRow.Visible=onESP; statusBar.Visible=onESP
    toolsContent.Visible=not onESP
    if not onESP then buildTools() end
end
tabESPBtn.MouseButton1Click:Connect(function() setMainTab("esp") end)
tabToolsBtn.MouseButton1Click:Connect(function() setMainTab("tools") end)

-- ─── Row builders ─────────────────────────────────────────────────────────────
local rowOrder=0
local function nextOrder() rowOrder=rowOrder+1; return rowOrder end
local function makeSep(txt)
    local f=Instance.new("Frame",list); f.Size=UDim2.new(1,0,0,26); f.BackgroundTransparency=1; f.LayoutOrder=nextOrder()
    local tick=Instance.new("Frame",f); tick.Size=UDim2.new(0,2,0,10); tick.Position=UDim2.new(0,0,0.5,-5)
    tick.BackgroundColor3=Color3.fromRGB(255,30,180); tick.BorderSizePixel=0; corner(tick,2)
    local t=Instance.new("TextLabel",f); t.Size=UDim2.new(1,-8,1,0); t.Position=UDim2.new(0,7,0,0)
    t.BackgroundTransparency=1; t.Text=txt:upper(); t.Font=Enum.Font.GothamBold; t.TextSize=9
    t.TextColor3=Color3.fromRGB(255,30,180); t.TextXAlignment=Enum.TextXAlignment.Left
    t.TextStrokeColor3=Color3.fromRGB(60,0,30); t.TextStrokeTransparency=0.5
    local line=Instance.new("Frame",f); line.BackgroundColor3=Color3.fromRGB(40,10,30)
    line.BorderSizePixel=0; line.AnchorPoint=Vector2.new(0,0.5); line.Position=UDim2.new(0,0,0.9,0); line.Size=UDim2.new(1,0,0,1)
end
local ROW_H=26
local function makeToggle(label,default,onChange)
    local row=Instance.new("Frame",list); row.Size=UDim2.new(1,0,0,ROW_H)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; row.LayoutOrder=nextOrder(); corner(row,7)
    local sbar=Instance.new("Frame",row); sbar.Size=UDim2.new(0,2,0.7,0); sbar.Position=UDim2.new(0,0,0.15,0)
    sbar.BackgroundColor3=default and Color3.fromRGB(255,30,180) or Color3.fromRGB(30,10,25); sbar.BorderSizePixel=0; corner(sbar,2)
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(1,-52,1,0); lbl.Position=UDim2.new(0,10,0,0)
    lbl.BackgroundTransparency=1; lbl.Text=label; lbl.Font=Enum.Font.Gotham; lbl.TextSize=11
    lbl.TextColor3=Color3.fromRGB(210,200,215); lbl.TextXAlignment=Enum.TextXAlignment.Left
    local TW,TH=32,16
    local track=Instance.new("Frame",row); track.Size=UDim2.new(0,TW,0,TH); track.Position=UDim2.new(1,-(TW+9),0.5,-TH/2)
    track.BackgroundColor3=default and Color3.fromRGB(255,30,180) or Color3.fromRGB(18,8,16); track.BorderSizePixel=0; corner(track,10)
    local TS=TH-4
    local thumb=Instance.new("Frame",track); thumb.Size=UDim2.new(0,TS,0,TS)
    thumb.Position=default and UDim2.new(1,-(TS+2),0.5,-TS/2) or UDim2.new(0,2,0.5,-TS/2)
    thumb.BackgroundColor3=Color3.fromRGB(240,230,240); thumb.BorderSizePixel=0; corner(thumb,10)
    local state=default; local ti=TweenInfo.new(0.13,Enum.EasingStyle.Quad)
    local btn=Instance.new("TextButton",row); btn.Size=UDim2.new(1,0,1,0); btn.BackgroundTransparency=1; btn.Text=""; btn.ZIndex=2
    btn.MouseButton1Click:Connect(function()
        state=not state
        local onC=Color3.fromRGB(255,30,180); local offC=Color3.fromRGB(18,8,16)
        TweenService:Create(track,ti,{BackgroundColor3=state and onC or offC}):Play()
        TweenService:Create(thumb,ti,{Position=state and UDim2.new(1,-(TS+2),0.5,-TS/2) or UDim2.new(0,2,0.5,-TS/2)}):Play()
        TweenService:Create(sbar,ti,{BackgroundColor3=state and Color3.fromRGB(255,30,180) or Color3.fromRGB(30,10,25)}):Play()
        onChange(state)
    end)
end
local function makeSlider(label,mn,mx,default,suffix,onChange)
    local row=Instance.new("Frame",list); row.Size=UDim2.new(1,0,0,40)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; row.LayoutOrder=nextOrder(); corner(row,7)
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(0.6,0,0,18); lbl.Position=UDim2.new(0,10,0,3)
    lbl.BackgroundTransparency=1; lbl.Text=label; lbl.Font=Enum.Font.Gotham; lbl.TextSize=11
    lbl.TextColor3=Color3.fromRGB(210,200,215); lbl.TextXAlignment=Enum.TextXAlignment.Left
    local valL=Instance.new("TextLabel",row); valL.Size=UDim2.new(0.36,0,0,18); valL.Position=UDim2.new(0.62,0,0,3)
    valL.BackgroundTransparency=1; valL.Text=tostring(default)..suffix; valL.Font=Enum.Font.GothamBold
    valL.TextSize=10; valL.TextColor3=Color3.fromRGB(255,30,180); valL.TextXAlignment=Enum.TextXAlignment.Right
    local track=Instance.new("Frame",row); track.Size=UDim2.new(1,-20,0,4); track.Position=UDim2.new(0,10,1,-12)
    track.BackgroundColor3=Color3.fromRGB(30,10,25); track.BorderSizePixel=0; corner(track,4)
    local pct0=(default-mn)/(mx-mn)
    local fill=Instance.new("Frame",track); fill.Size=UDim2.new(pct0,0,1,0)
    fill.BackgroundColor3=Color3.fromRGB(255,30,180); fill.BorderSizePixel=0; corner(fill,4)
    local dot=Instance.new("Frame",track); dot.Size=UDim2.new(0,11,0,11); dot.AnchorPoint=Vector2.new(0.5,0.5)
    dot.Position=UDim2.new(pct0,0,0.5,0); dot.BackgroundColor3=Color3.fromRGB(255,200,235)
    dot.BorderSizePixel=0; dot.ZIndex=2; corner(dot,11)
    local dragging=false
    local btn=Instance.new("TextButton",row); btn.Size=UDim2.new(1,0,1,0)
    btn.BackgroundTransparency=1; btn.Text=""; btn.ZIndex=3
    local function applyX(x)
        local rel=math.clamp(x-track.AbsolutePosition.X,0,track.AbsoluteSize.X)
        local t=rel/track.AbsoluteSize.X; local val=math.floor(mn+t*(mx-mn))
        fill.Size=UDim2.new(t,0,1,0); dot.Position=UDim2.new(t,0,0.5,0)
        valL.Text=tostring(val)..suffix; onChange(val)
    end
    btn.MouseButton1Down:Connect(function() dragging=true end)
    btn.MouseButton1Up:Connect(function(x) dragging=false; applyX(x) end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp.UserInputType==Enum.UserInputType.MouseMovement then applyX(inp.Position.X) end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if dragging and inp.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
    end)
end
local function makeCycle(label,options,default,onChange)
    local row=Instance.new("Frame",list); row.Size=UDim2.new(1,0,0,ROW_H)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; row.LayoutOrder=nextOrder(); corner(row,7)
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(1,-120,1,0); lbl.Position=UDim2.new(0,10,0,0)
    lbl.BackgroundTransparency=1; lbl.Text=label; lbl.Font=Enum.Font.Gotham; lbl.TextSize=11
    lbl.TextColor3=Color3.fromRGB(210,200,215); lbl.TextXAlignment=Enum.TextXAlignment.Left
    local valBtn=Instance.new("TextButton",row); valBtn.Size=UDim2.new(0,108,0,20)
    valBtn.Position=UDim2.new(1,-116,0.5,-10); valBtn.BackgroundColor3=Color3.fromRGB(40,10,30)
    valBtn.BorderSizePixel=0; valBtn.Text=default; valBtn.TextColor3=Color3.fromRGB(255,30,180)
    valBtn.TextSize=10; valBtn.Font=Enum.Font.GothamBold; valBtn.ZIndex=3; corner(valBtn,6)
    uiStroke(valBtn,Color3.fromRGB(255,30,180),1,0.6)
    local idx=1; for i,v in ipairs(options) do if v==default then idx=i; break end end
    valBtn.MouseButton1Click:Connect(function() idx=idx%#options+1; valBtn.Text=options[idx]; onChange(options[idx]) end)
end
local function makeStepper(label,options,default,onChange)
    local row=Instance.new("Frame",list); row.Size=UDim2.new(1,0,0,ROW_H)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; row.LayoutOrder=nextOrder(); corner(row,7)
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(0.45,0,1,0); lbl.Position=UDim2.new(0,10,0,0)
    lbl.BackgroundTransparency=1; lbl.Text=label; lbl.Font=Enum.Font.Gotham; lbl.TextSize=11
    lbl.TextColor3=Color3.fromRGB(210,200,215); lbl.TextXAlignment=Enum.TextXAlignment.Left
    local idx=1; for i,v in ipairs(options) do if tostring(v)==tostring(default) then idx=i; break end end
    local function mkArrow(t,xo)
        local b=Instance.new("TextButton",row); b.Size=UDim2.new(0,22,0,22); b.Position=UDim2.new(1,xo,0.5,-11)
        b.BackgroundColor3=Color3.fromRGB(40,10,30); b.Text=t; b.TextColor3=Color3.fromRGB(255,30,180)
        b.TextSize=13; b.Font=Enum.Font.GothamBold; b.BorderSizePixel=0; corner(b,6)
        uiStroke(b,Color3.fromRGB(255,30,180),1,0.6); return b
    end
    local prev=mkArrow("<",-102); local nxt=mkArrow(">", -26)
    local valLbl=Instance.new("TextLabel",row); valLbl.Size=UDim2.new(0,58,0,22); valLbl.Position=UDim2.new(1,-98,0.5,-11)
    valLbl.BackgroundColor3=Color3.fromRGB(20,5,15); valLbl.BorderSizePixel=0; valLbl.Font=Enum.Font.GothamBold
    valLbl.TextSize=10; valLbl.TextColor3=Color3.fromRGB(255,30,180); valLbl.TextXAlignment=Enum.TextXAlignment.Center
    valLbl.Text=tostring(options[idx]); corner(valLbl,6)
    prev.MouseButton1Click:Connect(function() idx=((idx-2)%#options)+1; valLbl.Text=tostring(options[idx]); onChange(options[idx]) end)
    nxt.MouseButton1Click:Connect(function() idx=idx%#options+1; valLbl.Text=tostring(options[idx]); onChange(options[idx]) end)
end
local rebindData=nil
local function makeKeybind(label,cfgKey)
    local row=Instance.new("Frame",list); row.Size=UDim2.new(1,0,0,ROW_H)
    row.BackgroundColor3=CFG.COL_ROW_BG; row.BorderSizePixel=0; row.LayoutOrder=nextOrder(); corner(row,7)
    local lbl=Instance.new("TextLabel",row); lbl.Size=UDim2.new(1,-88,1,0); lbl.Position=UDim2.new(0,10,0,0)
    lbl.BackgroundTransparency=1; lbl.Text=label; lbl.Font=Enum.Font.Gotham; lbl.TextSize=11
    lbl.TextColor3=Color3.fromRGB(210,200,215); lbl.TextXAlignment=Enum.TextXAlignment.Left
    local keyBtn=Instance.new("TextButton",row); keyBtn.Size=UDim2.new(0,76,0,20)
    keyBtn.Position=UDim2.new(1,-82,0.5,-10); keyBtn.BackgroundColor3=Color3.fromRGB(20,5,15)
    keyBtn.BorderSizePixel=0; keyBtn.Text="["..CFG[cfgKey].Name.."]"
    keyBtn.TextColor3=Color3.fromRGB(255,30,180); keyBtn.TextSize=10
    keyBtn.Font=Enum.Font.GothamBold; corner(keyBtn,6)
    uiStroke(keyBtn,Color3.fromRGB(255,30,180),1,0.55)
    keyBtn.MouseButton1Click:Connect(function()
        if rebindData then
            rebindData.button.Text="["..CFG[rebindData.cfgKey].Name.."]"
            rebindData.button.TextColor3=Color3.fromRGB(255,30,180)
            rebindData.button.BackgroundColor3=Color3.fromRGB(20,5,15)
        end
        rebindData={cfgKey=cfgKey,button=keyBtn}
        keyBtn.Text="press key"; keyBtn.TextColor3=Color3.fromRGB(255,255,255)
        keyBtn.BackgroundColor3=Color3.fromRGB(80,10,50)
    end)
    return keyBtn
end

-- ─── Build rows ───────────────────────────────────────────────────────────────
makeSep("VISIBILITY")
makeToggle("ESP",         CFG.ENABLED,     function(v) CFG.ENABLED    =v end)
makeToggle("Team Filter", CFG.TEAM_FILTER, function(v) CFG.TEAM_FILTER=v end)

makeSep("LABELS")
makeToggle("Name",       CFG.SHOW_NAME,      function(v) CFG.SHOW_NAME  =v end)
makeToggle("Distance",   CFG.SHOW_DIST,      function(v) CFG.SHOW_DIST  =v end)
makeToggle("Health Bar", CFG.SHOW_HEALTH,    function(v) CFG.SHOW_HEALTH=v end)
makeToggle("Arrows",     CFG.ARROWS_ENABLED, function(v) CFG.ARROWS_ENABLED=v end)

makeSep("SILENT AIM")
makeToggle("Enabled",      CFG.SILENT_AIM_ENABLED, function(v) CFG.SILENT_AIM_ENABLED=v end)
makeToggle("Burst Lock",   CFG.SA_BURST_LOCK,       function(v) CFG.SA_BURST_LOCK     =v end)
makeCycle("Priority Bone", {"Head","Torso"}, CFG.AIM_BONE, function(v) CFG.AIM_BONE=v end)
makeSlider("FOV Circle",   5, 500, CFG.AIM_FOV, " px", function(v) CFG.AIM_FOV=v; CFG.AIM_RADIUS=v end)
makeSlider("Bone Switch", 50, 600, CFG.BONE_SWITCH_DIST, " st", function(v) CFG.BONE_SWITCH_DIST=v end)
makeSlider("Bullet Speed", 100, 1000, CFG.BULLET_SPEED_EST, " st/s", function(v) CFG.BULLET_SPEED_EST=v end)

makeSep("WORLD")
makeToggle("Lock Time 12:00", CFG.LOCK_TIME, function(v) CFG.LOCK_TIME=v end)

makeSep("RANGE")
makeSlider("ESP Radius",   10, 9999, CFG.RADIUS,         " st", function(v) CFG.RADIUS        =v end)
makeSlider("Label Hide",   10,  800, CFG.LABEL_HIDE_DIST," st", function(v) CFG.LABEL_HIDE_DIST=v end)
makeSlider("Arrow Radius", 10, 2000, CFG.ARROW_RADIUS,   " st", function(v) CFG.ARROW_RADIUS  =v end)

makeSep("KEYBINDS")
makeKeybind("Toggle ESP", "KEY_ESP")
makeKeybind("Panel",      "KEY_PANEL")

-- ─── FOV Ring ────────────────────────────────────────────────────────────────
local fovGui = Instance.new("ScreenGui")
fovGui.Name="ESP_FOV_GUI"; fovGui.ResetOnSpawn=false
fovGui.IgnoreGuiInset=true; fovGui.DisplayOrder=9; fovGui.Parent=PlayerGui
local fovRing = Instance.new("Frame", fovGui)
fovRing.AnchorPoint=Vector2.new(0.5,0.5); fovRing.BackgroundTransparency=1
fovRing.BorderSizePixel=0; fovRing.Active=false
Instance.new("UICorner", fovRing).CornerRadius = UDim.new(1,0)
local fovStroke = Instance.new("UIStroke", fovRing)
fovStroke.Color=Color3.fromRGB(255,30,180); fovStroke.Thickness=1; fovStroke.Transparency=0.5
local function updateFOVRing()
    local vp = Camera.ViewportSize; local r = CFG.AIM_RADIUS
    fovRing.Position = UDim2.new(0,vp.X/2,0,vp.Y/2)
    fovRing.Size = UDim2.new(0,r*2,0,r*2)
end
updateFOVRing()

-- ─── Arrow GUI ───────────────────────────────────────────────────────────────
local arrowGui=Instance.new("ScreenGui")
arrowGui.Name="ESP_ARROW_GUI"; arrowGui.ResetOnSpawn=false
arrowGui.IgnoreGuiInset=true; arrowGui.DisplayOrder=5; arrowGui.Parent=PlayerGui
local POOL_SIZE=24; local arrowPool={}
for i=1,POOL_SIZE do
    local c=Instance.new("Frame",arrowGui); c.AnchorPoint=Vector2.new(0.5,0.5)
    c.Size=UDim2.new(0,96,0,96); c.BackgroundTransparency=1; c.Visible=false; c.Active=false
    local g=Instance.new("TextLabel",c); g.Size=UDim2.new(1,0,1,0); g.BackgroundTransparency=1
    g.Font=Enum.Font.GothamBold; g.TextSize=72; g.Text=">"
    g.TextXAlignment=Enum.TextXAlignment.Center; g.TextYAlignment=Enum.TextYAlignment.Center
    g.TextStrokeTransparency=0.3; g.TextStrokeColor3=Color3.new(0,0,0)
    local d=Instance.new("TextLabel",arrowGui); d.Size=UDim2.new(0,80,0,18)
    d.AnchorPoint=Vector2.new(0.5,0.5); d.BackgroundTransparency=1; d.Font=Enum.Font.GothamBold
    d.TextSize=15; d.TextColor3=Color3.fromRGB(210,210,210); d.TextStrokeTransparency=0.3
    d.TextStrokeColor3=Color3.new(0,0,0); d.Visible=false; d.Active=false
    arrowPool[i]={frame=c,glyph=g,dist=d}
end
local function getEdgePos(angle,vp)
    local m=CFG.ARROW_MARGIN; local hw=vp.X*.5-m; local hh=vp.Y*.5-m
    local c,s=math.cos(angle),math.sin(angle)
    local t=math.min(math.abs(c)>1e-6 and hw/math.abs(c) or math.huge,math.abs(s)>1e-6 and hh/math.abs(s) or math.huge)
    return vp.X*.5+c*t,vp.Y*.5+s*t
end
local function updateArrows()
    local vp=Camera.ViewportSize; local cx,cy=vp.X*.5,vp.Y*.5; local idx=0
    for _,p in ipairs(Players:GetPlayers()) do
        if isExcluded(p) then continue end
        if CFG.TEAM_FILTER and isTeammate(p) then continue end
        local char=p.Character; local hum=char and char:FindFirstChildWhichIsA("Humanoid")
        local root=char and getRootPart(p)
        if not root or not hum or hum.Health<=0 then continue end
        local d=getDist(root); if d>CFG.ARROW_RADIUS then continue end
        local sp,onScreen=Camera:WorldToViewportPoint(root.Position)
        if onScreen and sp.Z>0 then continue end
        idx=idx+1; if idx>POOL_SIZE then break end
        local sx,sy=sp.X,sp.Y; if sp.Z<0 then sx=vp.X-sx; sy=vp.Y-sy end
        local angle=math.atan2(sy-cy,sx-cx); local ex,ey=getEdgePos(angle,vp)
        local inX,inY=cx-ex,cy-ey; local len=math.sqrt(inX*inX+inY*inY)
        local nx=len>0 and inX/len or 0; local ny=len>0 and inY/len or 0
        local slot=arrowPool[idx]
        slot.frame.Visible=true; slot.frame.Position=UDim2.new(0,ex,0,ey)
        slot.frame.Rotation=math.deg(angle); slot.glyph.TextColor3=getColor()
        slot.dist.Visible=true; slot.dist.Position=UDim2.new(0,ex+nx*56,0,ey+ny*56)
        slot.dist.Text=string.format("%.0f",d); slot.dist.TextColor3=getColor()
    end
    for i=idx+1,POOL_SIZE do arrowPool[i].frame.Visible=false; arrowPool[i].dist.Visible=false end
end

-- ─── Draggable panel ─────────────────────────────────────────────────────────
do
    local dragging,dragStart,panelStart
    titleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true; dragStart=inp.Position; panelStart=panel.Position
        end
    end)
    titleBar.InputEnded:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if not dragging then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement then
            local d=inp.Position-dragStart
            local newPos=UDim2.new(panelStart.X.Scale,panelStart.X.Offset+d.X,
                panelStart.Y.Scale,panelStart.Y.Offset+d.Y)
            panel.Position=newPos
            _G.__FARAR_PanelPos={x=newPos.X.Offset, y=newPos.Y.Offset}
        end
    end)
end

-- ─── Panic ───────────────────────────────────────────────────────────────────
local function panic()
    _panicActive = not _panicActive
    CFG.ENABLED           = not _panicActive
    CFG.SILENT_AIM_ENABLED= not _panicActive
    panel.Visible         = false
    if _panicActive then
        for p in pairs(ESPObjects) do
            local o = ESPObjects[p]
            if o then
                if o.hl then o.hl.Enabled=false end
                if o.bb then o.bb.Enabled=false end
                if o.hbb then o.hbb.Enabled=false end
            end
        end
        for i=1,POOL_SIZE do arrowPool[i].frame.Visible=false; arrowPool[i].dist.Visible=false end
    end
end

-- ─── Key bindings ────────────────────────────────────────────────────────────
UserInputService.InputBegan:Connect(function(inp, processed)
    if inp.KeyCode == CFG.KEY_PANIC then panic(); return end
    if rebindData then
        local kc=inp.KeyCode
        if kc~=Enum.KeyCode.Unknown then
            if kc==Enum.KeyCode.Escape then
                rebindData.button.Text="["..CFG[rebindData.cfgKey].Name.."]"
                rebindData.button.TextColor3=CFG.COL_SLIDER; rebindData.button.BackgroundColor3=CFG.COL_TITLE_BG
            else
                CFG[rebindData.cfgKey]=kc
                rebindData.button.Text="["..kc.Name.."]"
                rebindData.button.TextColor3=CFG.COL_SLIDER; rebindData.button.BackgroundColor3=CFG.COL_TITLE_BG
                refreshHint()
            end
            rebindData=nil
        end
        return
    end
    if processed then return end
    if inp.KeyCode==CFG.KEY_PANEL then
        panel.Visible=not panel.Visible
        if panel.Visible then setMainTab(activeMainTab) end
    elseif inp.KeyCode==CFG.KEY_ESP then
        if _panicActive then return end
        CFG.ENABLED=not CFG.ENABLED
        fovStroke.Color=CFG.ENABLED and Color3.fromRGB(160,160,255) or Color3.fromRGB(255,80,80)
        task.delay(0.4,function() fovStroke.Color=Color3.fromRGB(160,160,255) end)
    end
end)

-- ─── Heartbeat ───────────────────────────────────────────────────────────────
local acc=0
RunService.Heartbeat:Connect(function(dt)
    if _panicActive then return end
    updateFOVRing()
    local _toolsOpen = panel.Visible and toolsContent.Visible
    if _toolsOpen and not _toolsWasOpen then buildTools() end
    _toolsWasOpen = _toolsOpen
    if CFG.LOCK_TIME and Lighting.ClockTime~=12 then Lighting.ClockTime=12 end
    acc=acc+dt; if acc<CFG.REFRESH_RATE then return end; acc=0
    refreshPlayers()
    local count=0
    for p in pairs(ESPObjects) do updateESP(p); count=count+1 end
    if CFG.ARROWS_ENABLED then updateArrows()
    else for i=1,POOL_SIZE do arrowPool[i].frame.Visible=false; arrowPool[i].dist.Visible=false end end
    if panel.Visible and activeMainTab=="esp" then
        local ex=""
        if CFG.SILENT_AIM_ENABLED then ex=ex.."  sa" end
        if CFG.LOCK_TIME          then ex=ex.."  12:00" end
        local dot2=CFG.ENABLED and "* " or "x "
        statusTxt.Text=string.format("%s%d players  esp %s%s",dot2,count,CFG.ENABLED and "on" or "off",ex)
        statusTxt.TextColor3=CFG.ENABLED and Color3.fromRGB(255,30,180) or Color3.fromRGB(120,40,80)
    end
end)

-- ─── Seed ────────────────────────────────────────────────────────────────────
setMainTab("esp")
for _,p in ipairs(Players:GetPlayers()) do
    if not isExcluded(p) then createESP(p); wirePlayer(p) end
end
