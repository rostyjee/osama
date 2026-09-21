local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

repeat task.wait() until game:IsLoaded()
repeat task.wait() until Players.LocalPlayer
local LP = Players.LocalPlayer
repeat task.wait() until LP:FindFirstChild("PlayerGui")

local Currency, Network
pcall(function()
    Currency = require(ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client"):WaitForChild("Currency"))
end)
pcall(function()
    Network = require(ReplicatedStorage.Library.Client.Network)
end)

repeat task.wait() until LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
task.wait(0.6)

local WINTER_CF = CFrame.new(-4170.39307, 1028.96558, -4252.91553)
local VOID_CF   = CFrame.new(-4249.06836, 2029.65088, -4252.03369)
local VOID_NEAR = VOID_CF * CFrame.new(0, 0, 10)

local cachedCostText, cachedCostNum = "-", nil
local cachedCoinsText, cachedCoinsNum = "-", nil
local costFresh = false
local totalRebirths, sessionRebirths = "-", 0
local statusText = "Idle"
local etaText, avgText = "-", "-"
local Status, CoinLbl, CostLbl, TotalLbl, SessionLbl, EtaLbl, AvgLbl, StatusDot

local sampleCoins, sampleTime, coinRate = nil, nil, 0
local cycleStart, lastRebirthAt, totalCycleTime = tick(), tick(), 0
local idledConn, afkThread, cycleThread
local autoRollOn, afkEnabled, eventEntered, running = false, false, false, false
local boardContent, rngChannel
local lastB, lastBM, lastP, lastPM, lastL, lastLM = 0, 1, 0, 1, 0, 1
local upgradesMaxed = false

local GOLD = Color3.fromRGB(232, 195, 106)
local ACCENT = Color3.fromRGB(80, 220, 140)
local ACCENT2 = Color3.fromRGB(90, 170, 255)
local ACCENT3 = Color3.fromRGB(255, 186, 72)
local BG = Color3.fromRGB(12, 13, 17)
local CARD = Color3.fromRGB(18, 20, 26)
local ROW = Color3.fromRGB(20, 22, 29)
local LINE = Color3.fromRGB(36, 40, 50)
local MUTED = Color3.fromRGB(128, 134, 148)
local WHITE = Color3.fromRGB(240, 242, 246)

local function setStatus(t)
    statusText = t or ""
end

local function formatTime(sec)
    if not sec or sec ~= sec or sec < 0 then return "-" end
    sec = sec // 1
    local h = sec // 3600
    local m = (sec % 3600) // 60
    local s = sec % 60
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

local function formatCoins(n)
    if type(n) ~= "number" or n ~= n then return "-" end
    local a = math.abs(n)
    if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if a >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if a >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if a >= 1e3 then return string.format("%.2fK", n / 1e3) end
    return tostring(n // 1)
end

local function updateCoins()
    if not Currency then return end
    local n = Currency.Get("PixelCoins")
    if type(n) == "number" then
        cachedCoinsNum = n
        cachedCoinsText = formatCoins(n)
    end
end

pcall(updateCoins)

local function getHRP()
    local char = LP.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function waitHRP(timeout)
    local t = tick()
    local hrp = getHRP()
    while not hrp and tick() - t < (timeout or 20) do
        task.wait(0.1)
        hrp = getHRP()
    end
    return hrp
end

local function smoothTP(cf, steps)
    steps = steps or 18
    local hrp = waitHRP(8)
    if not hrp then return end
    local start = hrp.CFrame
    for i = 1, steps do
        if not hrp.Parent then return end
        hrp.CFrame = start:Lerp(cf, i / steps)
        task.wait(0.03)
    end
    if hrp.Parent then hrp.CFrame = cf end
end

local function antiAFK()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum:Move(Vector3.new(0.12, 0, 0), true)
        task.wait(0.12)
        hum:Move(Vector3.zero, true)
    end
end

local function startAntiAFK()
    if idledConn then pcall(function() idledConn:Disconnect() end) end
    idledConn = LP.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
    if afkThread then pcall(function() task.cancel(afkThread) end) end
    afkThread = task.spawn(function()
        while afkEnabled do
            pcall(antiAFK)
            task.wait(25)
        end
    end)
end

local function stopAntiAFK()
    if idledConn then pcall(function() idledConn:Disconnect() end) idledConn = nil end
    if afkThread then pcall(function() task.cancel(afkThread) end) afkThread = nil end
end

local function invokeNet(name)
    if not Network then return end
    local done = false
    task.spawn(function()
        pcall(Network.InvokeServer, name)
        done = true
    end)
    local t = tick()
    while not done and tick() - t < 6 do task.wait(0.1) end
end

local function getRngChannel()
    if rngChannel then return rngChannel end
    if not Network or not Network.Channel then return end
    local ok, ch = pcall(Network.Channel, "RNG")
    if ok then rngChannel = ch end
    return rngChannel
end

local function rngFire(a, b)
    local ch = getRngChannel()
    if ch then pcall(function() ch:FireServer(a, b) end) end
end

local function getBoardContent()
    if boardContent and boardContent.Parent then return boardContent end
    local ok, content = pcall(function()
        return workspace._THINGS.Minigames.ServerOwned.RNGEvent.Interact.Boards.IncrementalBoard.Main.SurfaceGui.Bottom.Content
    end)
    if ok and content then boardContent = content end
    return boardContent
end

local function waitBoard(timeout)
    boardContent = nil
    local t = tick()
    while tick() - t < (timeout or 8) do
        if getBoardContent() and boardContent:FindFirstChild("BreakablesIncremental") then
            return true
        end
        task.wait(0.25)
    end
    return false
end

local function fireBtn(btn)
    if not btn then return end
    pcall(function()
        for _, conn in pairs(getconnections(btn.Activated)) do
            if conn.Fire then conn:Fire() elseif conn.Function then conn.Function() end
        end
    end)
    pcall(function() firesignal(btn.Activated) end)
end

local function getMainGui()
    return LP.PlayerGui:FindFirstChild("Main")
end

local function pressHide()
    local main = getMainGui()
    if main then
        pcall(function() fireBtn(main.Rolling.Action.Hide.Button) end)
    end
end

local function pressAutoBtn()
    local main = getMainGui()
    if main then
        pcall(function() fireBtn(main.Rolling.Action.Auto.Button) end)
    end
end

local function stopAutoRoll()
    rngFire("SetAutoRolling", false)
end

local function enableAutoRoll()
    if not autoRollOn then return end
    rngFire("SetAutoRolling", true)
    pressAutoBtn()
    task.wait(0.4)
    pressHide()
end

local function parseAmount(str)
    if not str then return nil end
    str = str:gsub(",", ""):gsub("%s+", "")
    local num, suf = str:match("([%d%.]+)([A-Za-z]*)")
    num = tonumber(num)
    if not num then return nil end
    suf = string.lower(suf or "")
    if suf == "k" then return num * 1e3 end
    if suf == "m" then return num * 1e6 end
    if suf == "b" then return num * 1e9 end
    if suf == "t" then return num * 1e12 end
    return num
end

local function readLvl(name)
    local cur, maxLvl = 0, 1
    local content = getBoardContent()
    if not content then return cur, maxLvl end
    local frame = content:FindFirstChild(name)
    local lbl = frame and frame:FindFirstChild("Main") and frame.Main:FindFirstChild("Lvl")
    if lbl then
        local a, b = lbl.Text:match("(%d+)/(%d+)")
        cur = tonumber(a) or 0
        maxLvl = tonumber(b) or 1
    end
    return cur, maxLvl
end

local function refreshUpgradeCache()
    lastB, lastBM = readLvl("BreakablesIncremental")
    lastP, lastPM = readLvl("PixelCoinsMultiplier")
    lastL, lastLM = readLvl("LuckMultiplier")
    upgradesMaxed = lastBM > 1 and lastPM > 1 and lastLM > 1
        and lastB >= lastBM and lastP >= lastPM and lastL >= lastLM
end

local function upgradesReset()
    refreshUpgradeCache()
    return lastB < 20 and lastP < 50 and lastL < 20
end

local function buyOne(name)
    local content = getBoardContent()
    if not content then return end
    local frame = content:FindFirstChild(name)
    if not frame then return end
    local buttons = frame:FindFirstChild("Buttons")
    if not buttons then return end
    local buyMax = buttons:FindFirstChild("BuyMax")
    local maxBtn = buyMax and buyMax:FindFirstChild("Button")
    local title = maxBtn and maxBtn:FindFirstChild("Title")
    local n = title and tonumber(title.Text:match("%((%d+)%)")) or 0
    if n > 0 and maxBtn then
        fireBtn(maxBtn)
        return
    end
    local buy = buttons:FindFirstChild("Buy")
    fireBtn(buy and buy:FindFirstChild("Button"))
end

local function buyAllOnce()
    if lastB < lastBM then buyOne("BreakablesIncremental") end
    if lastP < lastPM then buyOne("PixelCoinsMultiplier") end
    if lastB >= lastBM and lastP >= lastPM and lastL < lastLM then
        buyOne("LuckMultiplier")
    end
end

local function rebirthGuiOpen()
    local gui = LP.PlayerGui:FindFirstChild("RNGRebirth")
    if gui and gui.Enabled ~= false then return gui end
end

local function updateRebirthCost()
    local gui = rebirthGuiOpen()
    if not gui then return end
    local frame = gui:FindFirstChild("Frame")
    if not frame then return end
    for _, obj in ipairs(frame:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local raw = obj.Text:match("Rebirth!%s*%((.-)%)")
            if raw then
                local num = parseAmount(raw)
                if num then
                    cachedCostText, cachedCostNum, costFresh = raw, num, true
                end
            elseif obj.Visible and obj.Text:match("^%d+$") then
                local n = tonumber(obj.Text)
                if n and n < 100000 then totalRebirths = n end
            end
        end
    end
end

local function updateRate()
    if not cachedCoinsNum then return end
    local now = tick()
    if not sampleCoins then
        sampleCoins, sampleTime = cachedCoinsNum, now
        return
    end
    local dt = now - sampleTime
    if dt < 8 then return end
    local instant = (cachedCoinsNum - sampleCoins) / dt
    if instant > 0 then
        coinRate = (coinRate == 0) and instant or (coinRate * 0.7 + instant * 0.3)
    end
    sampleCoins, sampleTime = cachedCoinsNum, now
end

local function refreshEtaAvg()
    if not upgradesMaxed or not costFresh or not cachedCostNum or not cachedCoinsNum then
        etaText = "-"
    elseif cachedCoinsNum >= cachedCostNum then
        etaText = "Ready"
    elseif coinRate > 0 then
        etaText = formatTime((cachedCostNum - cachedCoinsNum) / coinRate)
    else
        etaText = "-"
    end
    avgText = (sessionRebirths <= 0)
        and formatTime(tick() - cycleStart)
        or formatTime(totalCycleTime / sessionRebirths)
end

local function canAfford()
    updateCoins()
    return costFresh and cachedCostNum and cachedCoinsNum and cachedCoinsNum >= cachedCostNum
end

local function waitRebirthGui(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local gui = rebirthGuiOpen()
        if gui then
            updateRebirthCost()
            return gui
        end
        task.wait(0.2)
    end
    return rebirthGuiOpen()
end

local function pressRebirth(gui)
    gui = gui or rebirthGuiOpen()
    if not gui then return end
    pcall(function() fireBtn(gui.Frame.Content.Rebirth.Button) end)
end

local function enterVoidSlow()
    smoothTP(VOID_NEAR, 16)
    task.wait(0.7)
    smoothTP(VOID_CF, 22)
    task.wait(1)
    local hrp = getHRP()
    if hrp then hrp.CFrame = VOID_CF end
end

local function goWinter()
    setStatus("Going Winter")
    invokeNet("RNGWinter")
    task.wait(2)
    smoothTP(WINTER_CF)
    waitBoard(8)
    task.wait(0.4)
end

local function goVoidOpenGui()
    invokeNet("RNGVoid")
    task.wait(2.5)
    enterVoidSlow()
    return waitRebirthGui(8)
end

local function onRebirthSuccess()
    local now = tick()
    totalCycleTime += now - lastRebirthAt
    lastRebirthAt = now
    sessionRebirths += 1
    if type(totalRebirths) == "number" then totalRebirths += 1 end
    cachedCostText, cachedCostNum, costFresh = "-", nil, false
    sampleCoins, sampleTime, coinRate = nil, nil, 0
    boardContent = nil
    upgradesMaxed = false
    task.wait(1)
    if autoRollOn then enableAutoRoll() end
end

local function visitVoid()
    setStatus("Traveling to Void")
    local gui = goVoidOpenGui()
    if not gui then
        setStatus("Rebirth menu missing")
        goWinter()
        return "no_gui"
    end
    task.wait(1)
    updateRebirthCost()
    updateCoins()
    if not canAfford() then
        setStatus("Not enough coins")
        goWinter()
        return "farm"
    end
    local beforeCoins = cachedCoinsNum
    setStatus("Attempting rebirth")
    for _ = 1, 4 do
        pressRebirth(rebirthGuiOpen() or gui)
        local t = tick()
        while tick() - t < 2.2 do
            if upgradesReset() then
                onRebirthSuccess()
                setStatus("Rebirth complete")
                return "success"
            end
            updateCoins()
            if beforeCoins and cachedCoinsNum and cachedCoinsNum < beforeCoins * 0.2 then
                onRebirthSuccess()
                setStatus("Rebirth complete")
                return "success"
            end
            task.wait(0.2)
        end
    end
    setStatus("Rebirth click failed, retry")
    goWinter()
    return "farm"
end

local function farmWinter()
    waitBoard(6)
    refreshUpgradeCache()
    local started = tick()
    while running do
        updateCoins()
        updateRate()
        refreshUpgradeCache()
        if not upgradesMaxed then
            if lastB < lastBM or lastP < lastPM then
                setStatus(string.format("Coins + Break  %d/%d  %d/%d", lastB, lastBM, lastP, lastPM))
            else
                setStatus(string.format("Luck  %d/%d", lastL, lastLM))
            end
            buyAllOnce()
        else
            if canAfford() then return "need_void" end
            if not costFresh and tick() - started > 12 then return "need_void" end
            setStatus("Maxed  •  farming " .. cachedCostText)
        end
        task.wait(0.45)
    end
    return "stop"
end

local function doFullCycle()
    if not eventEntered then
        setStatus("Entering event")
        invokeNet("RNGEvent")
        task.wait(2)
        eventEntered = true
    end
    goWinter()
    if autoRollOn then enableAutoRoll() end
    while running do
        local result = farmWinter()
        if result == "stop" or not running then return end
        if result == "need_void" then
            local r = visitVoid()
            if r == "success" then
                setStatus("Restarting farm")
                goWinter()
                if autoRollOn then enableAutoRoll() end
            end
        end
    end
end

local function getHost()
    local pg = LP.PlayerGui
    return pg:FindFirstChild("Main") or pg
end

local host = getHost()
pcall(function()
    local old = host:FindFirstChild("OsamaHub")
    if old then old:Destroy() end
end)

local function corner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = p
end

local function stroke(p, col, tr)
    local s = Instance.new("UIStroke")
    s.Color = col or LINE
    s.Transparency = tr or 0.4
    s.Thickness = 1
    s.Parent = p
end

local function txt(parent, props)
    local x = Instance.new("TextLabel")
    x.BackgroundTransparency = 1
    x.Font = Enum.Font.GothamMedium
    x.TextColor3 = WHITE
    x.TextSize = 12
    x.TextXAlignment = Enum.TextXAlignment.Left
    for k, v in pairs(props) do x[k] = v end
    x.Parent = parent
    return x
end

local Panel = Instance.new("Frame")
Panel.Name = "OsamaHub"
Panel.Size = UDim2.new(0, 252, 0, 392)
Panel.Position = UDim2.new(0, 16, 0.28, 0)
Panel.BackgroundColor3 = BG
Panel.BorderSizePixel = 0
Panel.ZIndex = 50
Panel.Parent = host
corner(Panel, 14)
stroke(Panel, Color3.fromRGB(48, 52, 64), 0.35)

local header = Instance.new("Frame")
header.Size = UDim2.new(1, -20, 0, 40)
header.Position = UDim2.new(0, 10, 0, 10)
header.BackgroundTransparency = 1
header.Parent = Panel

local badge = Instance.new("Frame")
badge.Size = UDim2.new(0, 26, 0, 26)
badge.Position = UDim2.new(0, 2, 0.5, -13)
badge.BackgroundColor3 = Color3.fromRGB(26, 22, 14)
badge.BorderSizePixel = 0
badge.Parent = header
corner(badge, 7)
stroke(badge, GOLD, 0.45)
txt(badge, {Size = UDim2.new(1, 0, 1, 0), Text = "O", Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = GOLD, TextXAlignment = Enum.TextXAlignment.Center})
txt(header, {Size = UDim2.new(1, -50, 0, 16), Position = UDim2.new(0, 36, 0, 4), Text = "OSAMA HUB", Font = Enum.Font.GothamBold, TextSize = 14})
txt(header, {Size = UDim2.new(1, -50, 0, 14), Position = UDim2.new(0, 36, 0, 20), Text = "RNG  •  Clicker Simulator", Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = MUTED})

StatusDot = Instance.new("Frame")
StatusDot.Size = UDim2.new(0, 7, 0, 7)
StatusDot.Position = UDim2.new(1, -8, 0, 8)
StatusDot.BackgroundColor3 = Color3.fromRGB(70, 76, 90)
StatusDot.BorderSizePixel = 0
StatusDot.Parent = header
corner(StatusDot, 8)

local line = Instance.new("Frame")
line.Size = UDim2.new(1, -20, 0, 1)
line.Position = UDim2.new(0, 10, 0, 54)
line.BackgroundColor3 = LINE
line.BorderSizePixel = 0
line.Parent = Panel

local function makeToggle(text, sub, y)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 40)
    btn.Position = UDim2.new(0, 10, 0, y)
    btn.BackgroundColor3 = ROW
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.Parent = Panel
    corner(btn, 10)
    txt(btn, {Size = UDim2.new(1, -56, 0, 15), Position = UDim2.new(0, 12, 0, 5), Text = text, Font = Enum.Font.GothamBold, TextSize = 12})
    txt(btn, {Size = UDim2.new(1, -56, 0, 13), Position = UDim2.new(0, 12, 0, 21), Text = sub, Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = MUTED})
    local pill = Instance.new("Frame")
    pill.Size = UDim2.new(0, 32, 0, 18)
    pill.Position = UDim2.new(1, -42, 0.5, -9)
    pill.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
    pill.Parent = btn
    corner(pill, 9)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, 2, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(210, 214, 224)
    knob.Parent = pill
    corner(knob, 8)
    return btn, pill, knob
end

local CycleBtn, CyclePill, CycleKnob = makeToggle("Full Cycle", "Winter farm + Void rebirth", 64)
local RollBtn, RollPill, RollKnob = makeToggle("Auto Roll", "Enable + hide dice UI", 108)
local AfkBtn, AfkPill, AfkKnob = makeToggle("Anti-AFK", "Stay in server", 152)

local function setToggle(pill, knob, on, onColor)
    pcall(function()
        TweenService:Create(pill, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
            BackgroundColor3 = on and onColor or Color3.fromRGB(34, 38, 48)
        }):Play()
        TweenService:Create(knob, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
            Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7),
            BackgroundColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(210, 214, 224)
        }):Play()
    end)
end

local stats = Instance.new("Frame")
stats.Size = UDim2.new(1, -20, 0, 168)
stats.Position = UDim2.new(0, 10, 0, 200)
stats.BackgroundColor3 = CARD
stats.Parent = Panel
corner(stats, 12)

Status = txt(stats, {
    Size = UDim2.new(1, -16, 0, 14),
    Position = UDim2.new(0, 10, 0, 8),
    Text = "Idle",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = GOLD,
})

local sep = Instance.new("Frame")
sep.Size = UDim2.new(1, -20, 0, 1)
sep.Position = UDim2.new(0, 10, 0, 28)
sep.BackgroundColor3 = LINE
sep.BorderSizePixel = 0
sep.Parent = stats

local function row(y, key)
    txt(stats, {Size = UDim2.new(0.5, 0, 0, 16), Position = UDim2.new(0, 10, 0, y), Text = key, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = MUTED})
    return txt(stats, {Size = UDim2.new(0.46, 0, 0, 16), Position = UDim2.new(0.50, 0, 0, y), Text = "-", Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Right})
end

CoinLbl = row(36, "PIXEL COINS")
CostLbl = row(56, "REBIRTH COST")
EtaLbl = row(76, "ETA")
AvgLbl = row(96, "AVG CYCLE")
TotalLbl = row(116, "TOTAL")
SessionLbl = row(136, "SESSION")

txt(Panel, {
    Size = UDim2.new(1, 0, 0, 12),
    Position = UDim2.new(0, 0, 1, -18),
    Text = "Right Shift  •  osamahub",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = Color3.fromRGB(80, 86, 98),
    TextXAlignment = Enum.TextXAlignment.Center,
})

local open = true
local tw = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
UserInputService.InputBegan:Connect(function(input, gp)
    if gp or input.KeyCode ~= Enum.KeyCode.RightShift then return end
    open = not open
    TweenService:Create(Panel, tw, {
        Position = open and UDim2.new(0, 16, 0.28, 0) or UDim2.new(0, -270, 0.28, 0)
    }):Play()
end)

local acc = 0
RunService.Heartbeat:Connect(function(dt)
    acc += dt
    if acc < 0.4 then return end
    acc = 0
    pcall(updateCoins)
    if LP.PlayerGui:FindFirstChild("RNGRebirth") then
        pcall(updateRebirthCost)
    end
    pcall(updateRate)
    pcall(refreshEtaAvg)
    if Status then Status.Text = statusText end
    if CoinLbl then CoinLbl.Text = cachedCoinsText end
    if CostLbl then CostLbl.Text = cachedCostText end
    if EtaLbl then EtaLbl.Text = etaText end
    if AvgLbl then AvgLbl.Text = avgText end
    if TotalLbl then TotalLbl.Text = tostring(totalRebirths) end
    if SessionLbl then SessionLbl.Text = tostring(sessionRebirths) end
end)

CycleBtn.MouseButton1Click:Connect(function()
    running = not running
    setToggle(CyclePill, CycleKnob, running, ACCENT)
    StatusDot.BackgroundColor3 = running and ACCENT or Color3.fromRGB(70, 76, 90)
    if running then
        cycleStart, lastRebirthAt, eventEntered = tick(), tick(), false
        setStatus("Starting")
        cycleThread = task.spawn(function()
            while running do
                local ok, err = pcall(doFullCycle)
                if not running then break end
                if not ok then
                    setStatus("Retry")
                    print("[osamahub] cycle", err)
                    task.wait(2)
                else
                    task.wait(1)
                end
            end
            setStatus("Stopped")
        end)
    else
        if cycleThread then pcall(task.cancel, cycleThread) end
        setStatus("Stopped")
    end
end)

RollBtn.MouseButton1Click:Connect(function()
    autoRollOn = not autoRollOn
    setToggle(RollPill, RollKnob, autoRollOn, ACCENT3)
    if autoRollOn then enableAutoRoll() else stopAutoRoll() end
end)

AfkBtn.MouseButton1Click:Connect(function()
    afkEnabled = not afkEnabled
    setToggle(AfkPill, AfkKnob, afkEnabled, ACCENT2)
    if afkEnabled then startAntiAFK() else stopAntiAFK() end
end)

afkEnabled = true
setToggle(AfkPill, AfkKnob, true, ACCENT2)
startAntiAFK()
print("[osamahub] ready")
