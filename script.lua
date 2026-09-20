local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local LP = Players.LocalPlayer

local WINTER_CF = CFrame.new(-4170.39307, 1028.96558, -4252.91553)
local VOID_CF   = CFrame.new(-4249.06836, 2029.65088, -4252.03369)
local VOID_NEAR = VOID_CF * CFrame.new(0, 0, 10)

local cachedCostText, cachedCostNum = "-", nil
local cachedCoinsText, cachedCoinsNum = "-", nil
local coinLabelRef = nil
local totalRebirths, sessionRebirths = "-", 0

local Status, CoinLbl, CostLbl, TotalLbl, SessionLbl, EtaLbl, AvgLbl, StatusDot

local sampleCoins, sampleTime = nil, nil
local coinRate = 0
local cycleStart = tick()
local lastRebirthAt = tick()
local totalCycleTime = 0

local ACCENT = Color3.fromRGB(80, 220, 140)
local ACCENT2 = Color3.fromRGB(70, 160, 255)
local BG = Color3.fromRGB(14, 16, 22)
local CARD = Color3.fromRGB(22, 26, 34)
local MUTED = Color3.fromRGB(150, 158, 172)
local WHITE = Color3.fromRGB(240, 242, 246)

local function setStatus(t)
    if Status then Status.Text = t end
end

local function formatTime(sec)
    if not sec or sec ~= sec or sec < 0 then return "-" end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%dh %dm", h, m)
    elseif m > 0 then
        return string.format("%dm %ds", m, s)
    else
        return string.format("%ds", s)
    end
end

local function getHRP()
    local char = LP.Character or LP.CharacterAdded:Wait()
    return char:WaitForChild("HumanoidRootPart")
end

local function smoothTP(cf, steps)
    steps = steps or 22
    local hrp = getHRP()
    local start = hrp.CFrame
    for i = 1, steps do
        hrp.CFrame = start:Lerp(cf, i / steps)
        task.wait(0.03)
    end
    hrp.CFrame = cf
end

local function antiAFK()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end

local function getNetwork()
    return require(game.ReplicatedStorage.Library.Client.Network)
end

local function getBoardContent()
    return workspace._THINGS.Minigames.ServerOwned.RNGEvent.Interact.Boards.IncrementalBoard.Main.SurfaceGui.Bottom.Content
end

local function fireBtn(btn)
    if not btn then return end
    for _, ev in ipairs({btn.MouseButton1Click, btn.Activated, btn.MouseButton1Down}) do
        pcall(function()
            for _, conn in pairs(getconnections(ev)) do
                pcall(function() conn:Fire() end)
            end
        end)
        pcall(function() firesignal(ev) end)
    end
end

local function parseAmount(str)
    if not str then return nil end
    str = tostring(str):gsub(",", ""):gsub("%s+", "")
    local num, suf = str:match("([%d%.]+)([A-Za-z]*)")
    num = tonumber(num)
    if not num then return nil end
    suf = string.lower(suf or "")
    local mul = {k=1e3,m=1e6,b=1e9,t=1e12,qd=1e15,qn=1e18,qi=1e18,sx=1e21}
    if mul[suf] then num = num * mul[suf] end
    return num
end

local function getUpgradeLevel(name)
    local cur, maxLvl = 0, 1
    pcall(function()
        local lbl = getBoardContent()[name].Main.Lvl
        local a, b = lbl.Text:match("(%d+)/(%d+)")
        cur = tonumber(a) or 0
        maxLvl = tonumber(b) or 1
    end)
    return cur, maxLvl
end

local function allUpgradesMaxed()
    for _, name in ipairs({"BreakablesIncremental","PixelCoinsMultiplier","LuckMultiplier"}) do
        local cur, maxLvl = getUpgradeLevel(name)
        if cur < maxLvl then return false end
    end
    return true
end

local function upgradesReset()
    local b = getUpgradeLevel("BreakablesIncremental")
    local p = getUpgradeLevel("PixelCoinsMultiplier")
    local l = getUpgradeLevel("LuckMultiplier")
    return b < 20 and p < 50 and l < 20
end

local function buyOne(name)
    local content
    pcall(function() content = getBoardContent() end)
    if not content then return end
    local frame = content:FindFirstChild(name)
    if not frame then return end
    local buyMaxBtn = frame:FindFirstChild("Buttons") and frame.Buttons:FindFirstChild("BuyMax") and frame.Buttons.BuyMax:FindFirstChild("Button")
    local title = buyMaxBtn and buyMaxBtn:FindFirstChild("Title")
    local n = 0
    if title and title.Text then n = tonumber(title.Text:match("%((%d+)%)")) or 0 end
    if n > 0 and buyMaxBtn then fireBtn(buyMaxBtn) return end
    local buyBtn = frame:FindFirstChild("Buttons") and frame.Buttons:FindFirstChild("Buy") and frame.Buttons.Buy:FindFirstChild("Button")
    if buyBtn then fireBtn(buyBtn) end
end

local function buyAllOnce()
    buyOne("BreakablesIncremental"); task.wait(0.12)
    buyOne("PixelCoinsMultiplier"); task.wait(0.12)
    buyOne("LuckMultiplier")
end

local function updateRebirthCost()
    local gui = LP.PlayerGui:FindFirstChild("RNGRebirth")
    if not gui then return end
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local t = obj.Text or ""
            local raw = t:match("Rebirth!%s*%((.-)%)")
                or t:match("%+%s*([%d%.]+%s*[KMBTQqi]+)%s*Pixel")
                or t:match("%(([%d%.]+%s*[KMBTQqi]+)%)")
            if raw then
                local num = parseAmount(raw)
                if num then
                    cachedCostText = raw
                    cachedCostNum = num
                end
            end
            if t:match("^%d+$") and obj.Visible then
                local n = tonumber(t)
                if n and n >= 0 and n < 100000 then
                    totalRebirths = n
                end
            end
        end
    end
end

local function findCoinLabel()
    if coinLabelRef and coinLabelRef.Parent then return coinLabelRef end
    pcall(function()
        for _, obj in ipairs(LP.PlayerGui:GetDescendants()) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                local path = obj:GetFullName():lower()
                local txt = obj.Text or ""
                if txt:find("%d") and (path:find("pixel") or txt:lower():find("pixel")) and not txt:lower():find("rebirth") then
                    coinLabelRef = obj
                    return
                end
            end
        end
    end)
    return coinLabelRef
end

local function updateCoins()
    local lbl = findCoinLabel()
    if lbl and lbl.Text ~= "" then
        local raw = lbl.Text:match("([%d%.]+%s*[KMBTQqi]+)") or lbl.Text:match("([%d%,%.]+)")
        if raw then
            cachedCoinsText = raw
            cachedCoinsNum = parseAmount(raw)
        end
    end
end

local function updateRate()
    if not cachedCoinsNum then return end
    local now = tick()
    if sampleCoins and sampleTime and now - sampleTime >= 8 then
        local gained = cachedCoinsNum - sampleCoins
        local dt = now - sampleTime
        if dt > 0 then
            local instant = gained / dt
            if instant > 0 then
                coinRate = (coinRate == 0) and instant or (coinRate * 0.7 + instant * 0.3)
            end
        end
        sampleCoins = cachedCoinsNum
        sampleTime = now
    elseif not sampleCoins then
        sampleCoins = cachedCoinsNum
        sampleTime = now
    end
end

local function getEtaText()
    if cachedCostNum and cachedCoinsNum and cachedCoinsNum >= cachedCostNum then
        return "Ready"
    end
    if not cachedCostNum or not cachedCoinsNum or coinRate <= 0 then
        return "-"
    end
    local left = cachedCostNum - cachedCoinsNum
    if left <= 0 then return "Ready" end
    return formatTime(left / coinRate)
end

local function getAvgText()
    if sessionRebirths <= 0 then
        return formatTime(tick() - cycleStart) .. " current"
    end
    return formatTime(totalCycleTime / sessionRebirths)
end

local function canAfford()
    updateCoins()
    return cachedCostNum ~= nil and cachedCoinsNum ~= nil and cachedCoinsNum >= cachedCostNum
end

local function waitRebirthGui(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local gui = LP.PlayerGui:FindFirstChild("RNGRebirth")
        if gui then
            updateRebirthCost()
            return gui
        end
        task.wait(0.15)
    end
    return LP.PlayerGui:FindFirstChild("RNGRebirth")
end

local function pressRebirth(gui)
    if not gui then return end
    local btn
    pcall(function() btn = gui.Frame.Content.Rebirth.Button end)
    if not btn then
        for _, obj in ipairs(gui:GetDescendants()) do
            if obj:IsA("ImageButton") or obj:IsA("TextButton") or obj:IsA("GuiButton") then
                local title = obj:FindFirstChild("Title", true)
                local txt = (title and title.Text) or obj.Name
                if tostring(txt):lower():find("rebirth") then
                    btn = obj
                    break
                end
            end
        end
    end
    if btn then fireBtn(btn) end
    pcall(function()
        local rem = game.ReplicatedStorage.Remotes:GetChildren()[129]
        if rem then rem:InvokeServer() end
    end)
end

local function enterVoidSlow()
    smoothTP(VOID_NEAR, 20); task.wait(0.8)
    smoothTP(VOID_CF, 28); task.wait(1.2)
    pcall(function() getHRP().CFrame = VOID_CF end)
end

local function goWinter()
    pcall(function() getNetwork().InvokeServer("RNGWinter") end)
    task.wait(2.2)
    smoothTP(WINTER_CF)
    task.wait(1)
end

local function goVoidOpenGui()
    pcall(function() getNetwork().InvokeServer("RNGVoid") end)
    task.wait(2.8)
    enterVoidSlow()
    return waitRebirthGui(8)
end

local function onRebirthSuccess()
    local now = tick()
    totalCycleTime += (now - lastRebirthAt)
    lastRebirthAt = now
    sessionRebirths += 1
    if typeof(totalRebirths) == "number" then totalRebirths += 1 end
    cachedCostText, cachedCostNum = "-", nil
    sampleCoins, sampleTime, coinRate = nil, nil, 0
end

local function visitVoid()
    setStatus("Traveling to Void")
    local gui = goVoidOpenGui()
    if not gui then
        setStatus("Rebirth menu missing")
        goWinter()
        return "no_gui"
    end
    task.wait(1.2)
    updateRebirthCost()
    updateCoins()
    if canAfford() or cachedCostNum == nil then
        setStatus("Attempting rebirth")
        pressRebirth(LP.PlayerGui:FindFirstChild("RNGRebirth") or gui)
        task.wait(3)
        if upgradesReset() then
            onRebirthSuccess()
            setStatus("Rebirth complete")
            return "success"
        end
    end
    setStatus("Not enough coins")
    goWinter()
    return "farm"
end

local function farmWinter()
    local started = tick()
    while true do
        updateCoins()
        updateRate()
        if not allUpgradesMaxed() then
            local b,bm = getUpgradeLevel("BreakablesIncremental")
            local p,pm = getUpgradeLevel("PixelCoinsMultiplier")
            local l,lm = getUpgradeLevel("LuckMultiplier")
            setStatus(string.format("Upgrades  %d/%d  %d/%d  %d/%d", b,bm,p,pm,l,lm))
            buyAllOnce()
        else
            if cachedCostNum == nil or canAfford() or tick() - started > 90 then
                return "need_void"
            end
            setStatus("All upgrades bought  •  farming to " .. cachedCostText)
        end
        task.wait(0.4)
    end
end

local function doFullCycle()
    setStatus("Entering event")
    pcall(function() getNetwork().InvokeServer("RNGEvent") end)
    task.wait(2.2)
    goWinter()
    while true do
        if farmWinter() == "need_void" then
            if visitVoid() == "success" then
                return true
            end
        end
    end
end

-- ===== UI =====
local old = game.CoreGui:FindFirstChild("DiceAutoGui")
if old then old:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DiceAutoGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = game.CoreGui

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 268, 0, 372)
Main.Position = UDim2.new(0, -280, 0.30, 0)
Main.BackgroundColor3 = BG
Main.BorderSizePixel = 0
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 16)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(48, 56, 72)
stroke.Transparency = 0.15
stroke.Thickness = 1
stroke.Parent = Main

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.new(1, 0, 0, 3)
accentBar.BackgroundColor3 = ACCENT
accentBar.BorderSizePixel = 0
accentBar.Parent = Main
Instance.new("UICorner", accentBar).CornerRadius = UDim.new(0, 16)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, -24, 0, 46)
header.Position = UDim2.new(0, 12, 0, 12)
header.BackgroundTransparency = 1
header.Parent = Main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -28, 0, 22)
title.BackgroundTransparency = 1
title.Text = "RNG CONTROL"
title.TextColor3 = WHITE
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.Size = UDim2.new(1, -28, 0, 16)
subtitle.Position = UDim2.new(0, 0, 0, 22)
subtitle.BackgroundTransparency = 1
subtitle.Text = "Rebirth automation"
subtitle.TextColor3 = MUTED
subtitle.Font = Enum.Font.Gotham
subtitle.TextSize = 12
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

StatusDot = Instance.new("Frame")
StatusDot.Size = UDim2.new(0, 8, 0, 8)
StatusDot.Position = UDim2.new(1, -10, 0, 8)
StatusDot.BackgroundColor3 = Color3.fromRGB(90, 96, 110)
StatusDot.BorderSizePixel = 0
StatusDot.Parent = header
Instance.new("UICorner", StatusDot).CornerRadius = UDim.new(1, 0)

local function makeToggle(text, y)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -24, 0, 40)
    btn.Position = UDim2.new(0, 12, 0, y)
    btn.BackgroundColor3 = CARD
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.Parent = Main
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -58, 1, 0)
    label.Position = UDim2.new(0, 14, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = WHITE
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 14
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = btn

    local pill = Instance.new("Frame")
    pill.Name = "Pill"
    pill.Size = UDim2.new(0, 34, 0, 18)
    pill.Position = UDim2.new(1, -46, 0.5, -9)
    pill.BackgroundColor3 = Color3.fromRGB(42, 48, 60)
    pill.Parent = btn
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)

    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, 2, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(200, 205, 215)
    knob.Parent = pill
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    return btn, label, pill, knob
end

local CycleBtn, _, CyclePill, CycleKnob = makeToggle("Full Cycle", 66)
local AfkBtn, _, AfkPill, AfkKnob = makeToggle("Anti-AFK", 112)

local function setToggle(pill, knob, on, onColor)
    TweenService:Create(pill, TweenInfo.new(0.18), {
        BackgroundColor3 = on and onColor or Color3.fromRGB(42, 48, 60)
    }):Play()
    TweenService:Create(knob, TweenInfo.new(0.18), {
        Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
        BackgroundColor3 = on and Color3.new(1,1,1) or Color3.fromRGB(200,205,215)
    }):Play()
end

local stats = Instance.new("Frame")
stats.Size = UDim2.new(1, -24, 0, 188)
stats.Position = UDim2.new(0, 12, 0, 162)
stats.BackgroundColor3 = CARD
stats.Parent = Main
Instance.new("UICorner", stats).CornerRadius = UDim.new(0, 12)

local function row(parent, y, key)
    local k = Instance.new("TextLabel")
    k.Size = UDim2.new(0.46, 0, 0, 18)
    k.Position = UDim2.new(0, 12, 0, y)
    k.BackgroundTransparency = 1
    k.Text = key
    k.TextColor3 = MUTED
    k.Font = Enum.Font.Gotham
    k.TextSize = 12
    k.TextXAlignment = Enum.TextXAlignment.Left
    k.Parent = parent

    local v = Instance.new("TextLabel")
    v.Size = UDim2.new(0.48, 0, 0, 18)
    v.Position = UDim2.new(0.48, 0, 0, y)
    v.BackgroundTransparency = 1
    v.Text = "-"
    v.TextColor3 = WHITE
    v.Font = Enum.Font.GothamMedium
    v.TextSize = 12
    v.TextXAlignment = Enum.TextXAlignment.Right
    v.Parent = parent
    return v
end

Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -20, 0, 18)
Status.Position = UDim2.new(0, 10, 0, 8)
Status.BackgroundTransparency = 1
Status.Text = "Idle"
Status.TextColor3 = ACCENT
Status.Font = Enum.Font.GothamMedium
Status.TextSize = 12
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = stats

CoinLbl = row(stats, 32, "Pixel Coins")
CostLbl = row(stats, 52, "Rebirth Cost")
EtaLbl = row(stats, 72, "ETA")
AvgLbl = row(stats, 92, "Avg Cycle")
TotalLbl = row(stats, 112, "Rebirths Total")
SessionLbl = row(stats, 132, "Session")

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -20, 0, 16)
hint.Position = UDim2.new(0, 10, 1, -22)
hint.BackgroundTransparency = 1
hint.Text = "Right Shift to hide"
hint.TextColor3 = Color3.fromRGB(90, 98, 112)
hint.Font = Enum.Font.Gotham
hint.TextSize = 11
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Parent = stats

local open = false
local tw = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local function toggleGui()
    open = not open
    TweenService:Create(Main, tw, {
        Position = open and UDim2.new(0, 18, 0.30, 0) or UDim2.new(0, -280, 0.30, 0)
    }):Play()
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then toggleGui() end
end)

task.spawn(function()
    while ScreenGui.Parent do
        updateCoins()
        updateRebirthCost()
        updateRate()
        CoinLbl.Text = tostring(cachedCoinsText)
        CostLbl.Text = tostring(cachedCostText)
        EtaLbl.Text = getEtaText()
        AvgLbl.Text = getAvgText()
        TotalLbl.Text = tostring(totalRebirths)
        SessionLbl.Text = tostring(sessionRebirths)
        task.wait(0.4)
    end
end)

local running, afkEnabled = false, false
local cycleThread, afkThread

CycleBtn.MouseButton1Click:Connect(function()
    running = not running
    setToggle(CyclePill, CycleKnob, running, ACCENT)
    StatusDot.BackgroundColor3 = running and ACCENT or Color3.fromRGB(90,96,110)
    if running then
        cycleStart = tick()
        lastRebirthAt = tick()
        cycleThread = task.spawn(function()
            while running do
                pcall(doFullCycle)
                task.wait(2)
            end
            setStatus("Stopped")
        end)
    else
        if cycleThread then task.cancel(cycleThread) end
        setStatus("Stopped")
    end
end)

AfkBtn.MouseButton1Click:Connect(function()
    afkEnabled = not afkEnabled
    setToggle(AfkPill, AfkKnob, afkEnabled, ACCENT2)
    if afkEnabled then
        afkThread = task.spawn(function()
            while afkEnabled do
                antiAFK()
                task.wait(25)
            end
        end)
    else
        if afkThread then task.cancel(afkThread) end
    end
end)

task.delay(0.55, toggleGui)
print("[RNG] ETA + average cycle loaded")
