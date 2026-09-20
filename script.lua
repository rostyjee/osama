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

local Currency
pcall(function()
    Currency = require(ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client"):WaitForChild("Currency"))
end)
local Network
pcall(function()
    Network = require(ReplicatedStorage.Library.Client.Network)
end)

repeat task.wait() until LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
task.wait(0.8)

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
local sampleCoins, sampleTime = nil, nil
local coinRate = 0
local cycleStart = tick()
local lastRebirthAt = tick()
local totalCycleTime = 0
local idledConn
local autoRollOn = false
local afkEnabled = false
local afkThread
local eventEntered = false
local running = false

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

local function setStatus(t) statusText = tostring(t or "") end

local function formatTime(sec)
    if not sec or sec ~= sec or sec < 0 then return "-" end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm %ds", m, s) end
    return string.format("%ds", s)
end

local function formatCoins(n)
    if type(n) ~= "number" or n ~= n then return "-" end
    local abs = math.abs(n)
    if abs >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if abs >= 1e9 then return string.format("%.2fB", n / 1e9) end
    if abs >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if abs >= 1e3 then return string.format("%.2fK", n / 1e3) end
    return tostring(math.floor(n + 0.5))
end

local function updateCoins()
    if not Currency or type(Currency.Get) ~= "function" then return end
    local n = Currency.Get("PixelCoins")
    if type(n) == "number" then
        cachedCoinsNum = n
        cachedCoinsText = formatCoins(n)
    end
end

pcall(updateCoins)
print("[osamahub] PixelCoins", cachedCoinsText, cachedCoinsNum)

local function getHRP()
    local char = LP.Character
    local t = tick()
    while (not char or not char:FindFirstChild("HumanoidRootPart")) and tick() - t < 20 do
        char = LP.Character
        task.wait(0.1)
    end
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function smoothTP(cf, steps)
    steps = steps or 22
    local hrp = getHRP()
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
    pcall(function()
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if hum then
            hum:Move(Vector3.new(0.15, 0, 0), true)
            task.wait(0.15)
            hum:Move(Vector3.zero, true)
        end
        if hrp then
            local cf = hrp.CFrame
            hrp.CFrame = cf * CFrame.new(0, 0, 0.05)
            task.wait(0.05)
            if hrp.Parent then hrp.CFrame = cf end
        end
    end)
end

local function startAntiAFK()
    if idledConn then pcall(function() idledConn:Disconnect() end) idledConn = nil end
    pcall(function()
        idledConn = LP.Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end)
    end)
    if afkThread then pcall(function() task.cancel(afkThread) end) end
    afkThread = task.spawn(function()
        while afkEnabled do
            pcall(antiAFK)
            task.wait(20)
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
        pcall(function() Network.InvokeServer(name) end)
        done = true
    end)
    local t = tick()
    while not done and tick() - t < 6 do task.wait(0.1) end
end

local function getRngChannel()
    if not Network or not Network.Channel then return nil end
    local ok, ch = pcall(function() return Network.Channel("RNG") end)
    if ok then return ch end
end

local function rngFire(a, b)
    local ch = getRngChannel()
    pcall(function() if ch then ch:FireServer(a, b) end end)
    pcall(function() if Network and Network.FireServer then Network.FireServer("RNG", a, b) end end)
end

local function getBoardContent()
    local ok, content = pcall(function()
        return workspace._THINGS.Minigames.ServerOwned.RNGEvent.Interact.Boards.IncrementalBoard.Main.SurfaceGui.Bottom.Content
    end)
    if ok then return content end
end

local function waitBoard(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local c = getBoardContent()
        if c and c:FindFirstChild("BreakablesIncremental") then return true end
        task.wait(0.2)
    end
    return false
end

local function fireBtn(btn)
    if not btn then return end
    pcall(function()
        for _, ev in ipairs({btn.Activated, btn.MouseButton1Click, btn.MouseButton1Down}) do
            pcall(function()
                for _, conn in pairs(getconnections(ev)) do
                    pcall(function()
                        if conn.Fire then conn:Fire() end
                        if conn.Function then conn.Function() end
                    end)
                end
            end)
            pcall(function() firesignal(ev) end)
        end
    end)
end

local function getMainGui()
    local ok, guiMod = pcall(function() return require(ReplicatedStorage.Library.Client.GUI) end)
    if ok and guiMod and guiMod.Main then
        local ok2, main = pcall(function() return guiMod.Main() end)
        if ok2 then return main end
    end
    return LP.PlayerGui:FindFirstChild("Main")
end

local function pressHide()
    pcall(function()
        local main = getMainGui()
        if main then fireBtn(main.Rolling.Action.Hide.Button) end
    end)
end

local function pressAutoBtn()
    pcall(function()
        local main = getMainGui()
        if main then fireBtn(main.Rolling.Action.Auto.Button) end
    end)
end

local function stopAutoRoll() rngFire("SetAutoRolling", false) end
local function enableAutoRoll()
    if not autoRollOn then return end
    rngFire("SetAutoRolling", true)
    pressAutoBtn()
    task.wait(0.45)
    pressHide()
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
        local content = getBoardContent()
        if not content then return end
        local a, b = content[name].Main.Lvl.Text:match("(%d+)/(%d+)")
        cur = tonumber(a) or 0
        maxLvl = tonumber(b) or 1
    end)
    return cur, maxLvl
end

local function allUpgradesMaxed()
    for _, name in ipairs({"BreakablesIncremental","PixelCoinsMultiplier","LuckMultiplier"}) do
        local cur, maxLvl = getUpgradeLevel(name)
        if maxLvl <= 1 or cur < maxLvl then return false end
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
    local content = getBoardContent()
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
    local b, bm = getUpgradeLevel("BreakablesIncremental")
    local p, pm = getUpgradeLevel("PixelCoinsMultiplier")
    local l, lm = getUpgradeLevel("LuckMultiplier")
    if b < bm or p < pm then
        if b < bm then buyOne("BreakablesIncremental") end
        if p < pm then buyOne("PixelCoinsMultiplier") end
        return
    end
    if l < lm then buyOne("LuckMultiplier") end
end

local function rebirthGuiOpen()
    local gui = LP.PlayerGui:FindFirstChild("RNGRebirth")
    if not gui or gui.Enabled == false then return nil end
    return gui
end

local function updateRebirthCost()
    local gui = rebirthGuiOpen()
    if not gui then return end
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            local t = obj.Text or ""
            local raw = t:match("Rebirth!%s*%((.-)%)")
            if raw then
                local num = parseAmount(raw)
                if num then
                    cachedCostText = raw
                    cachedCostNum = num
                    costFresh = true
                end
            end
            if t:match("^%d+$") and obj.Visible then
                local n = tonumber(t)
                if n and n >= 0 and n < 100000 then totalRebirths = n end
            end
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
        sampleCoins, sampleTime = cachedCoinsNum, now
    elseif not sampleCoins then
        sampleCoins, sampleTime = cachedCoinsNum, now
    end
end

local function refreshEtaAvg()
    local maxed = false
    pcall(function() maxed = allUpgradesMaxed() end)
    if not maxed or not costFresh or not cachedCostNum or not cachedCoinsNum then
        etaText = "-"
    elseif cachedCoinsNum >= cachedCostNum then
        etaText = "Ready"
    elseif coinRate > 0 then
        etaText = formatTime((cachedCostNum - cachedCoinsNum) / coinRate)
    else
        etaText = "-"
    end
    if sessionRebirths <= 0 then
        avgText = formatTime(tick() - cycleStart)
    else
        avgText = formatTime(totalCycleTime / sessionRebirths)
    end
end

local function canAfford()
    updateCoins()
    return costFresh and cachedCostNum ~= nil and cachedCoinsNum ~= nil and cachedCoinsNum >= cachedCostNum
end

local function waitRebirthGui(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local gui = rebirthGuiOpen()
        if gui then updateRebirthCost() return gui end
        task.wait(0.15)
    end
    return rebirthGuiOpen()
end

local function pressRebirth(gui)
    gui = gui or rebirthGuiOpen()
    if not gui then return end
    pcall(function() fireBtn(gui.Frame.Content.Rebirth.Button) end)
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("ImageButton") or obj:IsA("TextButton") or obj:IsA("GuiButton") then
            local title = obj:FindFirstChild("Title", true)
            local txt = string.lower(((title and title.Text) or obj.Text or obj.Name or ""))
            if txt:find("rebirth") then fireBtn(obj) end
        elseif obj:IsA("TextLabel") then
            local txt = string.lower(obj.Text or "")
            if txt:find("rebirth!") and obj.Parent and obj.Parent:IsA("GuiButton") then
                fireBtn(obj.Parent)
            end
        end
    end
end

local function enterVoidSlow()
    smoothTP(VOID_NEAR, 20); task.wait(0.8)
    smoothTP(VOID_CF, 28); task.wait(1.2)
    local hrp = getHRP()
    if hrp then hrp.CFrame = VOID_CF end
end

local function goWinter()
    setStatus("Going Winter")
    invokeNet("RNGWinter")
    task.wait(2.2)
    smoothTP(WINTER_CF)
    waitBoard(8)
    task.wait(0.6)
end

local function goVoidOpenGui()
    invokeNet("RNGVoid")
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
    costFresh = false
    sampleCoins, sampleTime, coinRate = nil, nil, 0
    task.wait(1.2)
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
    task.wait(1.2)
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
        while tick() - t < 2.5 do
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
    local started = tick()
    while running do
        updateCoins()
        updateRate()
        if not allUpgradesMaxed() then
            local b,bm = getUpgradeLevel("BreakablesIncremental")
            local p,pm = getUpgradeLevel("PixelCoinsMultiplier")
            local l,lm = getUpgradeLevel("LuckMultiplier")
            if b < bm or p < pm then
                setStatus(string.format("Coins + Break  %d/%d  %d/%d", b,bm,p,pm))
            else
                setStatus(string.format("Luck  %d/%d", l,lm))
            end
            buyAllOnce()
        else
            if canAfford() then return "need_void" end
            if not costFresh and tick() - started > 12 then return "need_void" end
            setStatus("Maxed  •  farming " .. tostring(cachedCostText))
        end
        task.wait(0.4)
    end
    return "stop"
end

local function doFullCycle()
    if not eventEntered then
        setStatus("Entering event")
        invokeNet("RNGEvent")
        task.wait(2.2)
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
    local main = pg:FindFirstChild("Main")
    if main then return main end
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("LayerCollector") then return g end
    end
    return pg
end

local host = getHost()
pcall(function()
    local old = host:FindFirstChild("OsamaHub")
    if old then old:Destroy() end
end)
pcall(function()
    local old = LP.PlayerGui:FindFirstChild("OsamaHub")
    if old then old:Destroy() end
end)
print("[osamahub] gui host", host:GetFullName())

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
    pill.Name = "Pill"
    pill.Size = UDim2.new(0, 32, 0, 18)
    pill.Position = UDim2.new(1, -42, 0.5, -9)
    pill.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
    pill.Parent = btn
    corner(pill, 9)
    local knob = Instance.new("Frame")
    knob.Name = "Knob"
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
local function toggleGui()
    open = not open
    pcall(function()
        TweenService:Create(Panel, tw, {
            Position = open and UDim2.new(0, 16, 0.28, 0) or UDim2.new(0, -270, 0.28, 0)
        }):Play()
    end)
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then toggleGui() end
end)

local lastUi = 0
RunService.Heartbeat:Connect(function()
    if tick() - lastUi < 0.25 then return end
    lastUi = tick()
    pcall(updateCoins)
    pcall(updateRebirthCost)
    pcall(updateRate)
    pcall(refreshEtaAvg)
    pcall(function()
        if Status then Status.Text = statusText end
        if CoinLbl then CoinLbl.Text = tostring(cachedCoinsText) end
        if CostLbl then CostLbl.Text = tostring(cachedCostText) end
        if EtaLbl then EtaLbl.Text = etaText end
        if AvgLbl then AvgLbl.Text = avgText end
        if TotalLbl then TotalLbl.Text = tostring(totalRebirths) end
        if SessionLbl then SessionLbl.Text = tostring(sessionRebirths) end
    end)
end)

local cycleThread
CycleBtn.MouseButton1Click:Connect(function()
    running = not running
    setToggle(CyclePill, CycleKnob, running, ACCENT)
    pcall(function()
        StatusDot.BackgroundColor3 = running and ACCENT or Color3.fromRGB(70, 76, 90)
    end)
    if running then
        cycleStart = tick()
        lastRebirthAt = tick()
        eventEntered = false
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
        if cycleThread then pcall(function() task.cancel(cycleThread) end) end
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
