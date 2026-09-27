local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

repeat task.wait() until game:IsLoaded()
repeat task.wait() until Players.LocalPlayer
local LP = Players.LocalPlayer
local F = {}
print("[osamahub] boot")
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
local VOID_CF = CFrame.new(-4249.06836, 2029.65088, -4252.03369)
local VOID_NEAR = VOID_CF * CFrame.new(0, 0, 10)
local MERCHANT_CF = CFrame.new(-4246.11279, 28.84262, -4205.35498)
local MERCHANT_NEAR = MERCHANT_CF * CFrame.new(0, 0, 14)

local cachedCostText, cachedCostNum = "-", nil
local cachedCoinsText, cachedCoinsNum = "-", nil
local costFresh = false
local totalRebirths, sessionRebirths = "-", 0
local statusText = "Idle"
local etaText, avgText = "-", "-"
local merchantText = "-"
local Status, CoinLbl, CostLbl, TotalLbl, SessionLbl, EtaLbl, AvgLbl, MercLbl, StatusDot
local SidePanel, SideMerc, SideCost, SideEta, SideStock, SideCoins
local sampleCoins, sampleTime = nil, nil
local coinRate = 0
local cycleStart = tick()
local lastRebirthAt = tick()
local totalCycleTime = 0
local idledConn
local autoRollOn = false
local rollThread
local afkEnabled = false
local merchantOn = false
local comboOn = false
local raidOn = false
local raidThread = nil
local hatchAfterRaid = true
local merchantBusy = false
local restockAt = nil
local lastMerchantVisit = 0
local merchantOffers = {}
local merchantKind = "DicesMerchant"
local afkThread
local eventEntered = false
local running = false

local GOLD = Color3.fromRGB(232, 195, 106)
local ACCENT = Color3.fromRGB(80, 220, 140)
local ACCENT2 = Color3.fromRGB(90, 170, 255)
local ACCENT3 = Color3.fromRGB(255, 186, 72)
local ACCENT4 = Color3.fromRGB(186, 120, 255)
local BG = Color3.fromRGB(12, 13, 17)
local CARD = Color3.fromRGB(18, 20, 26)
local ROW = Color3.fromRGB(20, 22, 29)
local LINE = Color3.fromRGB(36, 40, 50)
local MUTED = Color3.fromRGB(128, 134, 148)
local WHITE = Color3.fromRGB(240, 242, 246)

function F.setStatus(t)
    statusText = tostring(t or "")
end

function F.formatTime(sec)
    if not sec or sec ~= sec or sec < 0 then
        return "-"
    end
    sec = math.floor(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then
        return string.format("%dh %dm", h, m)
    end
    if m > 0 then
        return string.format("%dm %ds", m, s)
    end
    return string.format("%ds", s)
end

function F.formatCoins(n)
    if type(n) ~= "number" or n ~= n then
        return "-"
    end
    local absn = math.abs(n)
    if absn >= 1e12 then
        return string.format("%.2fT", n / 1e12)
    end
    if absn >= 1e9 then
        return string.format("%.2fB", n / 1e9)
    end
    if absn >= 1e6 then
        return string.format("%.2fM", n / 1e6)
    end
    if absn >= 1e3 then
        return string.format("%.2fK", n / 1e3)
    end
    return tostring(math.floor(n + 0.5))
end

function F.updateCoins()
    if not Currency or type(Currency.Get) ~= "function" then
        return
    end
    local n = Currency.Get("PixelCoins")
    if type(n) == "number" then
        cachedCoinsNum = n
        cachedCoinsText = F.formatCoins(n)
    end
end

pcall(F.updateCoins)

function F.applyMerchantPacket(pack)
    if type(pack) ~= "table" or not pack.Offers then
        return
    end
    if pack.State and type(pack.State.RemainingSeconds) == "number" then
        restockAt = tick() + math.max(pack.State.RemainingSeconds, 1)
    end
    if pack.State and type(pack.State.Kind) == "string" then
        merchantKind = pack.State.Kind
    end
    merchantOffers = {}
    for i = 1, 3 do
        local o = pack.Offers[i]
        if type(o) == "table" then
            merchantOffers[i] = {
                key = o.OfferKey,
                stock = tonumber(o.Stock) or 0,
                price = tonumber(o.PriceGems) or 0,
                item = o.ItemId,
                unlocked = o.Unlocked ~= false
            }
        end
    end
end

pcall(function()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then
        return
    end
    for _, ev in ipairs(remotes:GetChildren()) do
        pcall(function()
            ev.OnClientEvent:Connect(function(a, b, c)
                local pack = (type(a) == "table" and a.Offers and a)
                    or (type(b) == "table" and b.Offers and b)
                    or (type(c) == "table" and c.Offers and c)
                if pack then
                    F.applyMerchantPacket(pack)
                end
            end)
        end)
    end
end)

function F.getHRP()
    local char = LP.Character
    local t = tick()
    while (not char or not char:FindFirstChild("HumanoidRootPart")) and tick() - t < 20 do
        char = LP.Character
        task.wait(0.1)
    end
    return char and char:FindFirstChild("HumanoidRootPart")
end

function F.smoothTP(cf, steps)
    steps = steps or 22
    local hrp = F.getHRP()
    if not hrp then
        return
    end
    local start = hrp.CFrame
    for i = 1, steps do
        if not hrp.Parent then
            return
        end
        hrp.CFrame = start:Lerp(cf, i / steps)
        task.wait(0.03)
    end
    if hrp.Parent then
        hrp.CFrame = cf
    end
end

function F.tapIdleKey()
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game)
        task.wait(0.05)
        vim:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game)
    end)
end

function F.antiAFK()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
    pcall(F.tapIdleKey)
    pcall(function()
        local char = LP.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum and not merchantBusy then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
            task.wait(0.05)
            hum:Move(Vector3.new(0.08, 0, 0), true)
            task.wait(0.08)
            hum:Move(Vector3.zero, true)
        end
    end)
end

function F.bindIdle()
    if idledConn then
        pcall(function()
            idledConn:Disconnect()
        end)
        idledConn = nil
    end
    pcall(function()
        idledConn = LP.Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
            pcall(F.tapIdleKey)
        end)
    end)
end

function F.startAntiAFK()
    F.bindIdle()
    pcall(function()
        LP.CharacterAdded:Connect(function()
            if afkEnabled then
                task.wait(1)
                F.bindIdle()
                pcall(F.antiAFK)
            end
        end)
    end)
    if afkThread then
        pcall(function()
            task.cancel(afkThread)
        end)
    end
    afkThread = task.spawn(function()
        while afkEnabled do
            pcall(F.antiAFK)
            task.wait(12)
        end
    end)
end

function F.stopAntiAFK()
    if idledConn then
        pcall(function()
            idledConn:Disconnect()
        end)
        idledConn = nil
    end
    if afkThread then
        pcall(function()
            task.cancel(afkThread)
        end)
        afkThread = nil
    end
end

function F.invokeNet(name)
    if not Network then
        return
    end
    local done = false
    task.spawn(function()
        pcall(function()
            Network.InvokeServer(name)
        end)
        done = true
    end)
    local t = tick()
    while not done and tick() - t < 6 do
        task.wait(0.1)
    end
end

function F.getRngChannel()
    if not Network or not Network.Channel then
        return nil
    end
    local ok, ch = pcall(function()
        return Network.Channel("RNG")
    end)
    if ok then
        return ch
    end
end

function F.rngFire(a, b)
    local ch = F.getRngChannel()
    pcall(function()
        if ch then
            ch:FireServer(a, b)
        end
    end)
    pcall(function()
        if Network and Network.FireServer then
            Network.FireServer("RNG", a, b)
        end
    end)
end

local BOARD_NAMES = {
    BreakablesIncremental = true,
    PixelCoinsMultiplier = true,
    LuckMultiplier = true,
}

function F.findIncrementalBoard()
    local cached
    local ok, inst = pcall(function()
        return workspace._THINGS.Minigames.ServerOwned.RNGEvent.Interact.Boards.IncrementalBoard
    end)
    if ok and inst then
        return inst
    end
    ok, inst = pcall(function()
        return workspace:FindFirstChild("IncrementalBoard", true)
    end)
    if ok and inst then
        return inst
    end
    pcall(function()
        for _, obj in ipairs(workspace:GetDescendants()) do
            if obj.Name == "IncrementalBoard" or (obj.Name == "Content" and obj:FindFirstChild("LuckMultiplier")) then
                cached = obj.Name == "IncrementalBoard" and obj or obj
                break
            end
        end
    end)
    return cached
end

function F.getBoardContent()
    local board = F.findIncrementalBoard()
    if not board then
        return nil
    end
    if board.Name == "Content" then
        return board
    end
    local content
    pcall(function()
        content = board.Main.SurfaceGui.Bottom.Content
    end)
    if content then
        return content
    end
    pcall(function()
        for _, d in ipairs(board:GetDescendants()) do
            if d.Name == "Content" and (d:FindFirstChild("LuckMultiplier") or d:FindFirstChild("BreakablesIncremental") or d:FindFirstChild("PixelCoinsMultiplier")) then
                content = d
                break
            end
        end
    end)
    return content
end

function F.waitBoard(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local c = F.getBoardContent()
        if c then
            return true
        end
        task.wait(0.2)
    end
    return F.getBoardContent() ~= nil
end

function F.fireBtn(btn)
    if not btn then
        return
    end
    pcall(function()
        for _, ev in ipairs({btn.Activated, btn.MouseButton1Click, btn.MouseButton1Down}) do
            pcall(function()
                for _, conn in pairs(getconnections(ev)) do
                    pcall(function()
                        if conn.Fire then
                            conn:Fire()
                        end
                        if conn.Function then
                            conn.Function()
                        end
                    end)
                end
            end)
            pcall(function()
                firesignal(ev)
            end)
        end
    end)
    pcall(function()
        if typeof(btn.Activate) == "function" then
            btn:Activate()
        end
    end)
end

function F.clickGui(obj)
    if not obj then
        return
    end
    F.fireBtn(obj)
    pcall(function()
        local pos = obj.AbsolutePosition
        local size = obj.AbsoluteSize
        if size.X < 2 or size.Y < 2 then
            return
        end
        local cx = pos.X + size.X * 0.5
        local cy = pos.Y + size.Y * 0.5
        local inset = Vector2.new(0, 0)
        pcall(function()
            inset = game:GetService("GuiService"):GetGuiInset()
        end)
        F.clickScreen(cx, cy)
        F.clickScreen(cx + inset.X, cy + inset.Y)
        F.clickScreen(cx, cy + inset.Y)
    end)
end

function F.getMainGui()
    local ok, guiMod = pcall(function()
        return require(ReplicatedStorage.Library.Client.GUI)
    end)
    if ok and guiMod and guiMod.Main then
        local ok2, main = pcall(function()
            return guiMod.Main()
        end)
        if ok2 then
            return main
        end
    end
    return LP.PlayerGui:FindFirstChild("Main")
end

function F.getRollingFrame()
    local main = F.getMainGui()
    if main then
        local r = main:FindFirstChild("Rolling")
        if r then
            return r
        end
    end
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then
        return nil
    end
    local found
    pcall(function()
        found = pg:FindFirstChild("Rolling", true)
    end)
    return found
end

function F.rollGuiReady()
    return F.getRollingFrame() ~= nil
end

function F.collectRollBlob()
    local blob = ""
    local rolling = F.getRollingFrame()
    if not rolling then
        return blob
    end
    pcall(function()
        for _, d in ipairs(rolling:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                blob = blob .. " " .. string.lower(d.Text or "")
            end
        end
    end)
    return blob
end

local lastDiceCf, lastDiceMove = nil, 0

function F.diceMoving()
    local rolling = F.getRollingFrame()
    if not rolling then
        return false
    end
    local moved = false
    pcall(function()
        for _, d in ipairs(rolling:GetDescendants()) do
            if d:IsA("WorldModel") or d:IsA("ViewportFrame") or d:IsA("Model") then
                local part = d:FindFirstChildWhichIsA("BasePart", true)
                if part then
                    local cf = part.CFrame
                    if lastDiceCf and (cf.Position - lastDiceCf.Position).Magnitude > 0.02 then
                        moved = true
                    end
                    lastDiceCf = cf
                    break
                end
            end
        end
    end)
    if moved then
        lastDiceMove = tick()
    end
    return moved or (tick() - lastDiceMove < 1.2)
end

function F.isDiceBusy()
    local blob = F.collectRollBlob()
    if blob:find("rolling", 1, true) or blob:find("hatching", 1, true) or blob:find("revealing", 1, true) then
        return true
    end
    if blob:find("auto on", 1, true) or blob:find("stop auto", 1, true) then
        return true
    end
    if F.diceMoving() then
        return true
    end
    local ch = F.getRngChannel()
    local busy = false
    pcall(function()
        if ch and ch.HasRolling then
            busy = ch.HasRolling == true
        end
    end)
    return busy
end

function F.pressHide()
    local rolling = F.getRollingFrame()
    if not rolling then
        return
    end
    pcall(function()
        F.fireBtn(rolling.Action.Hide.Button)
    end)
    pcall(function()
        for _, d in ipairs(rolling:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("ImageButton") then
                local tx = string.lower((d.Text or d.Name or ""))
                local title = d:FindFirstChild("Title")
                if title then
                    tx = tx .. " " .. string.lower(title.Text or "")
                end
                if tx:find("hide", 1, true) and d:IsA("GuiButton") then
                    F.fireBtn(d)
                elseif tx:find("hide", 1, true) and d.Parent and d.Parent:IsA("GuiButton") then
                    F.fireBtn(d.Parent)
                end
            end
        end
    end)
end

function F.pressAutoBtn()
    local rolling = F.getRollingFrame()
    if not rolling then
        return
    end
    pcall(function()
        F.fireBtn(rolling.Action.Auto.Button)
    end)
    pcall(function()
        for _, d in ipairs(rolling:GetDescendants()) do
            if d:IsA("GuiButton") then
                local tx = string.lower(d.Name or "")
                local title = d:FindFirstChild("Title")
                if title then
                    tx = tx .. " " .. string.lower(title.Text or "")
                end
                if tx:find("auto", 1, true) and not tx:find("hide", 1, true) then
                    F.fireBtn(d)
                end
            end
        end
    end)
end

function F.kickAutoRoll()
    F.rngFire("SetAutoRolling", true)
    if not F.rollGuiReady() then
        return
    end
    if F.isDiceBusy() then
        F.pressHide()
        return
    end
    F.pressAutoBtn()
    task.wait(0.25)
    F.rngFire("SetAutoRolling", true)
    F.pressHide()
end

function F.stopAutoRoll()
    autoRollOn = false
    if rollThread then
        pcall(function()
            task.cancel(rollThread)
        end)
        rollThread = nil
    end
    F.rngFire("SetAutoRolling", false)
end

function F.enableAutoRoll()
    if not autoRollOn then
        return
    end
    F.kickAutoRoll()
end

function F.startRollWatch()
    if rollThread then
        pcall(function()
            task.cancel(rollThread)
        end)
        rollThread = nil
    end
    rollThread = task.spawn(function()
        local idleFor = 0
        while autoRollOn do
            F.rngFire("SetAutoRolling", true)
            if F.isDiceBusy() then
                idleFor = 0
            else
                idleFor = idleFor + 0.7
                if idleFor >= 1.4 then
                    F.kickAutoRoll()
                    idleFor = 0
                end
            end
            task.wait(0.7)
        end
    end)
end

function F.recoverAutoRoll()
    if not autoRollOn then
        return
    end
    F.startRollWatch()
    task.spawn(function()
        local t = tick()
        while autoRollOn and tick() - t < 6 do
            F.rngFire("SetAutoRolling", true)
            if F.isDiceBusy() then
                F.pressHide()
                return
            end
            if F.rollGuiReady() then
                F.kickAutoRoll()
                return
            end
            task.wait(0.3)
        end
    end)
end

function F.parseAmount(str)
    if not str then
        return nil
    end
    str = tostring(str):gsub(",", ""):gsub("%s+", "")
    local num, suf = str:match("([%d%.]+)([A-Za-z]*)")
    num = tonumber(num)
    if not num then
        return nil
    end
    suf = string.lower(suf or "")
    local mul = {k = 1e3, m = 1e6, b = 1e9, t = 1e12, qd = 1e15, qn = 1e18, qi = 1e18, sx = 1e21}
    if mul[suf] then
        num = num * mul[suf]
    end
    return num
end

function F.parseLevelPair(text)
    if not text then
        return nil, nil
    end
    text = tostring(text):gsub(",", ""):gsub("%s+", "")
    local a, b = text:match("(%d+)/(%d+)")
    if a and b then
        return tonumber(a), tonumber(b)
    end
end

function F.findUpgradeFrame(name)
    local content = F.getBoardContent()
    if not content then
        return nil
    end
    local direct = content:FindFirstChild(name)
    if direct then
        return direct
    end
    local needles = {
        BreakablesIncremental = { "breakable", "health" },
        PixelCoinsMultiplier = { "pixel coin", "coins multiplier" },
        LuckMultiplier = { "luck" },
    }
    local keys = needles[name]
    if not keys then
        return nil
    end
    for _, child in ipairs(content:GetChildren()) do
        local blob = string.lower(child.Name)
        pcall(function()
            for _, d in ipairs(child:GetDescendants()) do
                if d:IsA("TextLabel") or d:IsA("TextButton") then
                    blob = blob .. " " .. string.lower(d.Text or "")
                end
            end
        end)
        local ok = true
        for _, key in ipairs(keys) do
            if not blob:find(key, 1, true) then
                ok = false
                break
            end
        end
        if ok then
            return child
        end
    end
end

function F.getUpgradeLevel(name)
    local cur, maxLvl = 0, 1
    pcall(function()
        local frame = F.findUpgradeFrame(name)
        if not frame then
            return
        end
        local bestA, bestB
        local function consider(text)
            local a, b = F.parseLevelPair(text)
            if a and b and b >= 10 then
                if not bestB or b > bestB then
                    bestA, bestB = a, b
                end
            end
        end
        pcall(function()
            consider(frame.Main.Lvl.Text)
        end)
        for _, d in ipairs(frame:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                consider(d.Text)
            end
        end
        if bestA then
            cur, maxLvl = bestA, bestB
        end
    end)
    return cur, maxLvl
end

function F.allUpgradesMaxed()
    local seen = 0
    for _, name in ipairs({"BreakablesIncremental", "PixelCoinsMultiplier", "LuckMultiplier"}) do
        local cur, maxLvl = F.getUpgradeLevel(name)
        if maxLvl <= 1 then
            return false
        end
        seen = seen + 1
        if cur < maxLvl then
            return false
        end
    end
    return seen == 3
end

function F.upgradesReset()
    local b = F.getUpgradeLevel("BreakablesIncremental")
    local p = F.getUpgradeLevel("PixelCoinsMultiplier")
    local l = F.getUpgradeLevel("LuckMultiplier")
    return b < 20 and p < 50 and l < 20
end

function F.buyRemote(name, n)
    if not Network then
        return
    end
    n = n or 50
    pcall(function()
        Network.InvokeServer(name, n)
    end)
    pcall(function()
        Network.InvokeServer(name, 1)
    end)
end

function F.buyOne(name)
    local n = 50
    local frame = F.findUpgradeFrame(name)
    if frame then
        local buyMaxBtn = frame:FindFirstChild("Buttons") and frame.Buttons:FindFirstChild("BuyMax") and frame.Buttons.BuyMax:FindFirstChild("Button")
        local title = buyMaxBtn and buyMaxBtn:FindFirstChild("Title")
        if title and title.Text then
            n = tonumber(title.Text:match("%((%d+)%)")) or n
        end
        if n < 1 then
            n = 1
        end
        F.buyRemote(name, n)
        if buyMaxBtn then
            F.fireBtn(buyMaxBtn)
        end
        local buyBtn = frame:FindFirstChild("Buttons") and frame.Buttons:FindFirstChild("Buy") and frame.Buttons.Buy:FindFirstChild("Button")
        if buyBtn then
            F.fireBtn(buyBtn)
        end
        return
    end
    F.buyRemote(name, n)
end

function F.buyAllOnce()
    local b, bm = F.getUpgradeLevel("BreakablesIncremental")
    local p, pm = F.getUpgradeLevel("PixelCoinsMultiplier")
    local l, lm = F.getUpgradeLevel("LuckMultiplier")
    if b < bm or p < pm then
        if b < bm then
            F.buyOne("BreakablesIncremental")
        end
        if p < pm then
            F.buyOne("PixelCoinsMultiplier")
        end
        return
    end
    if l < lm then
        F.buyOne("LuckMultiplier")
    end
end

function F.rebirthGuiOpen()
    local gui = LP.PlayerGui:FindFirstChild("RNGRebirth")
    if not gui or gui.Enabled == false then
        return nil
    end
    return gui
end

function F.considerRebirthTotal(n)
    n = tonumber(n)
    if not n or n < 0 or n > 1e12 then
        return
    end
    if typeof(totalRebirths) ~= "number" or n > totalRebirths then
        totalRebirths = math.floor(n)
    end
end

function F.readRebirthsFromCurrency()
    if not Currency or not Currency.Get then
        return
    end
    for _, name in ipairs({
        "RngRebirths", "RNGRebirths", "RNG2Rebirths", "Rebirths", "rng rebirths", "RNG rebirths"
    }) do
        local ok, val = pcall(function()
            return Currency.Get(name)
        end)
        if ok and type(val) == "number" and val > 0 then
            F.considerRebirthTotal(val)
        end
    end
end

function F.readRebirthsFromGui(root, allowBareNumber)
    if not root then
        return
    end
    pcall(function()
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                local t = obj.Text or ""
                local raw = t:match("Rebirth!%s*%((.-)%)")
                if raw then
                    local num = F.parseAmount(raw)
                    if num then
                        cachedCostText = raw
                        cachedCostNum = num
                        costFresh = true
                    end
                end
                local low = string.lower(t .. " " .. obj.Name)
                local cleaned = t:gsub(",", "")
                if allowBareNumber and t:match("^[%d,]+$") then
                    local n = tonumber(cleaned)
                    if n and n >= 1 then
                        F.considerRebirthTotal(n)
                    end
                elseif low:find("rebirth", 1, true) then
                    local n = tonumber(cleaned:match("(%d+)"))
                    if n and n >= 1 then
                        F.considerRebirthTotal(n)
                    end
                end
            end
        end
    end)
end

function F.updateRebirthCost()
    F.readRebirthsFromCurrency()
    local gui = F.rebirthGuiOpen() or (LP.PlayerGui and LP.PlayerGui:FindFirstChild("RNGRebirth"))
    if gui then
        F.readRebirthsFromGui(gui, true)
    end
    pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        if not pg then
            return
        end
        for _, name in ipairs({"Main", "Rebirths", "HUD", "RNGRebirth"}) do
            local g = pg:FindFirstChild(name)
            if g then
                F.readRebirthsFromGui(g, name == "RNGRebirth" or name == "Rebirths")
            end
        end
    end)
end

function F.updateRate()
    if not cachedCoinsNum then
        return
    end
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

function F.refreshEtaAvg()
    local maxed = false
    pcall(function()
        maxed = F.allUpgradesMaxed()
    end)
    if not maxed or not costFresh or not cachedCostNum or not cachedCoinsNum then
        etaText = "-"
    elseif cachedCoinsNum >= cachedCostNum then
        etaText = "Ready"
    elseif coinRate > 0 then
        etaText = F.formatTime((cachedCostNum - cachedCoinsNum) / coinRate)
    else
        etaText = "-"
    end
    if sessionRebirths <= 0 then
        avgText = F.formatTime(tick() - cycleStart)
    else
        avgText = F.formatTime(totalCycleTime / sessionRebirths)
    end
    if not merchantOn then
        merchantText = "Off"
    elseif not restockAt then
        merchantText = "..."
    else
        local left = restockAt - tick()
        if left <= 0 then
            merchantText = "Now"
        else
            merchantText = F.formatTime(left)
        end
    end
end

function F.canAfford()
    F.updateCoins()
    return costFresh and cachedCostNum ~= nil and cachedCoinsNum ~= nil and cachedCoinsNum >= cachedCostNum
end

function F.waitRebirthGui(timeout)
    local t = tick()
    while tick() - t < (timeout or 8) do
        local gui = F.rebirthGuiOpen()
        if gui then
            F.updateRebirthCost()
            return gui
        end
        task.wait(0.15)
    end
    return F.rebirthGuiOpen()
end

function F.pressRebirth(gui)
    gui = gui or F.rebirthGuiOpen()
    pcall(function()
        Network.InvokeServer("RNGRebirth")
    end)
    pcall(function()
        Network.InvokeServer("Rebirth")
    end)
    pcall(function()
        Network.InvokeServer("DoRebirth")
    end)
    if not gui then
        return
    end
    pcall(function()
        F.clickGui(gui.Frame.Content.Rebirth.Button)
    end)
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("ImageButton") or obj:IsA("TextButton") or obj:IsA("GuiButton") then
            local title = obj:FindFirstChild("Title", true)
            local tx = string.lower(((title and title.Text) or obj.Text or obj.Name or ""))
            if tx:find("rebirth") then
                F.clickGui(obj)
            end
        elseif obj:IsA("TextLabel") then
            local tx = string.lower(obj.Text or "")
            if tx:find("rebirth!") and obj.Parent and obj.Parent:IsA("GuiButton") then
                F.clickGui(obj.Parent)
            end
        end
    end
end

function F.merchantGui()
    local gui = LP.PlayerGui:FindFirstChild("Merchant")
    if gui and gui.Enabled ~= false then
        return gui
    end
end

function F.parseRestockFromBlob(blob)
    if not blob then
        return nil
    end
    local t = string.lower(tostring(blob))
    local n = tonumber(t:match("restock[%w%s:]*?(%d+)%s*min"))
    if n then
        return n * 60
    end
    n = tonumber(t:match("restock[%w%s:]*?(%d+)%s*sec"))
    if n then
        return n
    end
    n = tonumber(t:match("(%d+)%s*minutes?"))
    if n and t:find("restock") then
        return n * 60
    end
    n = tonumber(t:match("(%d+)%s*seconds?"))
    if n and t:find("restock") then
        return n
    end
end

function F.captureRestock(gui)
    gui = gui or F.merchantGui()
    if not gui then
        return
    end
    local parts = {}
    for _, obj in ipairs(gui:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            table.insert(parts, obj.Text or "")
        end
    end
    local sec = F.parseRestockFromBlob(table.concat(parts, " "))
    if sec then
        restockAt = tick() + math.max(sec, 3)
    end
end

function F.clickScreen(x, y)
    pcall(function()
        if mousemoveabs then
            mousemoveabs(x, y)
        end
    end)
    pcall(function()
        if mouse1click then
            mouse1click()
        end
    end)
    pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.02)
        vim:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
end

function F.fireMerchantBtn(btn)
    F.clickGui(btn)
    local off
    pcall(function()
        local name = btn:GetFullName()
        local slot = tonumber(name:match("Offer_(%d+)"))
        if slot then
            F.buyOfferRemote(slot)
        end
    end)
end

function F.readOfferStock(offer)
    if not offer then
        return 0
    end
    for _, d in ipairs(offer:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local n = tostring(d.Text or ""):match("[xX]%s*(%d+)%s*in%s*Stock")
            if n then
                return tonumber(n) or 0
            end
        end
    end
    return 0
end

function F.readOffers(gui)
    local rows = {}
    if not gui then
        return rows
    end
    local offers
    pcall(function()
        offers = gui.Frame.Frame.Offers
    end)
    if not offers then
        return rows
    end
    for i = 1, 3 do
        local offer = offers:FindFirstChild("Offer_" .. i)
        if offer then
            local btn
            pcall(function()
                btn = offer.Content.Action.Button
            end)
            rows[i] = {
                offer = offer,
                btn = btn,
                stock = F.readOfferStock(offer)
            }
        end
    end
    return rows
end

function F.waitStockDrop(offer, before, timeout)
    local t = tick()
    while tick() - t < (timeout or 0.55) do
        local now = F.readOfferStock(offer)
        if now < before then
            return true, now
        end
        task.wait(0.04)
    end
    return false, F.readOfferStock(offer)
end

function F.slotStock(i)
    if merchantOffers[i] then
        return merchantOffers[i].stock
    end
    return -1
end

function F.totalCachedStock()
    local n = 0
    local any = false
    for i = 1, 3 do
        if merchantOffers[i] then
            n = n + (merchantOffers[i].stock or 0)
            any = true
        end
    end
    if any then
        return n
    end
    return -1
end

function F.buyOfferRemote(i)
    local off = merchantOffers[i]
    local key = off and off.key or ("respect_tier_" .. i)
    local kind = merchantKind or "DicesMerchant"
    if not Network then
        return
    end
    pcall(function()
        Network.InvokeServer(kind, key)
    end)
    pcall(function()
        Network.InvokeServer(kind, i)
    end)
    pcall(function()
        Network.InvokeServer(key)
    end)
    pcall(function()
        if Network.FireServer then
            Network.FireServer(kind, key)
        end
    end)
end

function F.waitCachedStockDrop(i, before, timeout)
    local t = tick()
    while tick() - t < (timeout or 0.7) do
        local now = F.slotStock(i)
        if now >= 0 and now < before then
            return true
        end
        task.wait(0.05)
    end
    return false
end

function F.currentStock(i, rows)
    local s = F.slotStock(i)
    if s >= 0 then
        return s
    end
    if rows and rows[i] then
        return rows[i].stock or 0
    end
    return 0
end

function F.offerBlockedText(offer)
    if not offer then
        return false
    end
    for _, d in ipairs(offer:GetDescendants()) do
        if d:IsA("TextLabel") or d:IsA("TextButton") then
            local t = string.lower(tostring(d.Text or ""))
            if t:find("not enough") or t:find("out of stock") then
                return true
            end
        end
    end
    return false
end

function F.canBuySlot(i, rows)
    F.updateCoins()
    local stock = F.currentStock(i, rows)
    if stock <= 0 then
        return false
    end
    local off = merchantOffers[i]
    if off and off.unlocked == false then
        return false
    end
    if off and off.price and cachedCoinsNum and off.price > cachedCoinsNum then
        return false
    end
    if rows and rows[i] and F.offerBlockedText(rows[i].offer) then
        return false
    end
    return true
end

function F.anyBuyable(rows)
    for i = 1, 3 do
        if F.canBuySlot(i, rows) then
            return true
        end
    end
    return false
end

function F.buyMerchantOffers(gui)
    local started = tick()
    for i = 1, 3 do
        local fails = 0
        while tick() - started < 18 and fails < 4 do
            gui = F.merchantGui() or gui
            local rows = F.readOffers(gui)
            if not F.canBuySlot(i, rows) then
                break
            end
            local before = F.currentStock(i, rows)
            local left = 0
            for s = 1, 3 do
                if F.canBuySlot(s, rows) then
                    left = left + F.currentStock(s, rows)
                end
            end
            F.setStatus("Buying dice " .. tostring(left))
            if rows[i] and rows[i].btn then
                F.fireMerchantBtn(rows[i].btn)
            else
                fails = fails + 1
                task.wait(0.2)
            end
            local dropped = F.waitCachedStockDrop(i, before, 0.55)
            if not dropped and rows[i] and rows[i].offer then
                dropped = F.waitStockDrop(rows[i].offer, before, 0.35)
            end
            if dropped then
                fails = 0
            else
                fails = fails + 1
                task.wait(0.12)
            end
        end
    end
end

function F.waitMerchantGui(timeout)
    local t = tick()
    while tick() - t < (timeout or 7) do
        local gui = F.merchantGui()
        if gui then
            return gui
        end
        task.wait(0.15)
    end
    return F.merchantGui()
end

function F.visitMerchant()
    if not merchantOn then
        return
    end
    merchantBusy = true
    F.setStatus("Going Merchant")
    if not eventEntered then
        F.invokeNet("RNGEvent")
        task.wait(2.2)
        eventEntered = true
    end
    F.smoothTP(MERCHANT_NEAR, 18)
    task.wait(0.6)
    F.smoothTP(MERCHANT_CF, 22)
    task.wait(1.1)
    local gui = F.waitMerchantGui(7)
    if gui then
        F.captureRestock(gui)
        local rows = F.readOffers(gui)
        if F.anyBuyable(rows) then
            F.setStatus("Buying dice")
            F.buyMerchantOffers(gui)
            task.wait(0.25)
        else
            F.setStatus("Merchant empty")
        end
        F.captureRestock(gui)
        if running then
            F.setStatus("Merchant done")
        else
            F.setStatus("Merchant done - turn on Full Cycle")
        end
    else
        F.setStatus("Merchant GUI missing")
        if not restockAt then
            restockAt = tick() + 300
        end
    end
    if not restockAt then
        restockAt = tick() + 300
    end
    lastMerchantVisit = tick()
    merchantBusy = false
end

function F.merchantDue()
    if not merchantOn or merchantBusy then
        return false
    end
    if restockAt and tick() >= (restockAt - 1) then
        return true
    end
    if tick() - lastMerchantVisit < 25 then
        return false
    end
    return F.anyBuyable(F.readOffers(F.merchantGui()))
end

function F.enterVoidSlow()
    F.smoothTP(VOID_NEAR, 20)
    task.wait(0.8)
    F.smoothTP(VOID_CF, 28)
    task.wait(1.2)
    local hrp = F.getHRP()
    if hrp then
        hrp.CFrame = VOID_CF
    end
end

function F.goWinter()
    F.setStatus("Going Winter")
    F.invokeNet("RNGWinter")
    task.wait(2.2)
    F.smoothTP(WINTER_CF)
    F.waitBoard(8)
    task.wait(0.6)
end

function F.goVoidOpenGui()
    F.invokeNet("RNGVoid")
    task.wait(2.8)
    F.enterVoidSlow()
    return F.waitRebirthGui(8)
end

function F.onRebirthSuccess()
    local now = tick()
    totalCycleTime = totalCycleTime + (now - lastRebirthAt)
    lastRebirthAt = now
    sessionRebirths = sessionRebirths + 1
    if typeof(totalRebirths) == "number" then
        totalRebirths = totalRebirths + 1
    end
    cachedCostText, cachedCostNum = "-", nil
    costFresh = false
    sampleCoins, sampleTime, coinRate = nil, nil, 0
    task.wait(1.5)
    if autoRollOn then
        F.startRollWatch()
        F.recoverAutoRoll()
    end
end

function F.visitVoid()
    if F.merchantDue() then
        return "merchant"
    end
    F.setStatus("Traveling to Void")
    local gui = F.goVoidOpenGui()
    if not gui then
        F.setStatus("Rebirth menu missing")
        F.goWinter()
        return "no_gui"
    end
    task.wait(1.2)
    F.updateRebirthCost()
    F.updateCoins()
    if not F.canAfford() then
        F.setStatus("Not enough coins")
        F.goWinter()
        return "farm"
    end
    local beforeCoins = cachedCoinsNum
    F.setStatus("Attempting rebirth")
    for _ = 1, 4 do
        F.pressRebirth(F.rebirthGuiOpen() or gui)
        local t = tick()
        while tick() - t < 2.5 do
            if F.upgradesReset() then
                F.onRebirthSuccess()
                F.setStatus("Rebirth complete")
                return "success"
            end
            F.updateCoins()
            if beforeCoins and cachedCoinsNum and cachedCoinsNum < beforeCoins * 0.2 then
                F.onRebirthSuccess()
                F.setStatus("Rebirth complete")
                return "success"
            end
            task.wait(0.2)
        end
    end
    F.setStatus("Rebirth click failed, retry")
    F.goWinter()
    return "farm"
end

function F.farmWinter()
    local hasBoard = F.waitBoard(6)
    if not hasBoard then
        F.setStatus("Winter board missing - remote buy")
    end
    local started = tick()
    while running do
        if F.merchantDue() then
            return "need_merchant"
        end
        F.updateCoins()
        F.updateRate()
        if not F.allUpgradesMaxed() then
            local b, bm = F.getUpgradeLevel("BreakablesIncremental")
            local p, pm = F.getUpgradeLevel("PixelCoinsMultiplier")
            local l, lm = F.getUpgradeLevel("LuckMultiplier")
            if not hasBoard then
                hasBoard = F.waitBoard(1)
                F.setStatus("Buying upgrades (remote)")
                F.buyRemote("BreakablesIncremental", 50)
                F.buyRemote("PixelCoinsMultiplier", 50)
                if b >= bm and p >= pm then
                    F.buyRemote("LuckMultiplier", 50)
                end
            elseif b < bm or p < pm then
                F.setStatus(string.format("Coins + Break  %d/%d  %d/%d", b, bm, p, pm))
            else
                F.setStatus(string.format("Luck  %d/%d", l, lm))
            end
            F.buyAllOnce()
        else
            if F.merchantDue() then
                return "need_merchant"
            end
            if F.canAfford() then
                return "need_void"
            end
            if not costFresh and tick() - started > 12 then
                return "need_void"
            end
            F.setStatus("Maxed - farming " .. tostring(cachedCostText))
        end
        task.wait(0.4)
    end
    return "stop"
end

local function doRaidCycle()
local function clickLabel(needle)
    needle = string.lower(needle)
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then
        return false
    end
    local hit = false
    pcall(function()
        for _, d in ipairs(pg:GetDescendants()) do
            local tx = ""
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                tx = string.lower(d.Text or "")
            end
            local title = d:FindFirstChild("Title")
            if title and title:IsA("TextLabel") then
                tx = tx .. " " .. string.lower(title.Text or "")
            end
            if tx:find(needle, 1, true) then
                local btn = d
                if not d:IsA("GuiButton") then
                    btn = d.Parent
                end
                if btn and btn:IsA("GuiButton") then
                    F.clickGui(btn)
                    hit = true
                end
            end
        end
    end)
    return hit
end

local function guiHas(text)
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then
        return false
    end
    local found = false
    pcall(function()
        local needle = string.lower(text)
        for _, d in ipairs(pg:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and string.lower(d.Text or ""):find(needle, 1, true) then
                found = true
                break
            end
        end
    end)
    return found
end

local function readRaidLevel()
    local lvl = 0
    pcall(function()
        local pg = LP:FindFirstChild("PlayerGui")
        if not pg then
            return
        end
        for _, d in ipairs(pg:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local t = d.Text or ""
                local n = t:lower():match("raid lvl%s*(%d+)") or t:lower():match("raid level%s*(%d+)")
                if n then
                    lvl = math.max(lvl, tonumber(n) or 0)
                end
            end
        end
    end)
    pcall(function()
        local v = LP:GetAttribute("RaidLevel") or LP:GetAttribute("RaidLvl")
        if type(v) == "number" then
            lvl = math.max(lvl, v)
        end
    end)
    return lvl
end

local function maxRaidDiff(lvl)
    if lvl >= 2500 then
        return 5
    elseif lvl >= 1200 then
        return 4
    elseif lvl >= 500 then
        return 3
    elseif lvl >= 100 then
        return 2
    end
    return 1
end

local function invokeRaid(...)
    local args = {...}
    pcall(function()
        if Network and Network.InvokeServer then
            Network.InvokeServer(table.unpack(args))
        end
    end)
    pcall(function()
        if Network and Network.FireServer then
            Network.FireServer(table.unpack(args))
        end
    end)
end

local function enterRaidHub()
    F.setStatus("Raid hub")
    invokeRaid("RaidEvent")
    pcall(function()
        if Network and Network.Channel then
            local ch = Network.Channel("EventFrontend")
            if ch and ch.InvokeServer then
                ch:InvokeServer("RaidEvent")
            end
        end
    end)
    clickLabel("raid")
    local t = tick()
    while raidOn and tick() - t < 8 do
        if guiHas("create raid") or guiHas("start raid") or guiHas("cake walk") then
            return true
        end
        invokeRaid("RaidEvent")
        task.wait(0.4)
    end
    return guiHas("create raid") or guiHas("start raid")
end

local function startRaidLobby()
    local lvl = readRaidLevel()
    local diff = maxRaidDiff(lvl)
    F.setStatus("Raid diff " .. tostring(diff))
    invokeRaid(1, diff, "Public")
    clickLabel(tostring(diff))
    task.wait(0.25)
    clickLabel("public")
    task.wait(0.2)
    clickLabel("start raid")
    invokeRaid(1)
    task.wait(0.35)
    invokeRaid("RaidLobby")
    local t = tick()
    while raidOn and tick() - t < 12 do
        if guiHas("dps") or guiHas("/ 350") or findRaidGate() then
            return true
        end
        task.wait(0.35)
    end
    return true
end

local function findRaidGate()
    local best, bestHp
    pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            local textObj
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                textObj = d
            end
            if textObj then
                local a, b = tostring(textObj.Text):gsub(",", ""):match("(%d+)%s*/%s*(%d+)")
                a, b = tonumber(a), tonumber(b)
                if a and b and b >= 50 and a > 0 then
                    local part = textObj
                    for _ = 1, 8 do
                        if part and (part:IsA("BasePart") or part:IsA("Model")) then
                            break
                        end
                        part = part.Parent
                    end
                    local world = part
                    if part and part:IsA("Model") then
                        world = part.PrimaryPart or part:FindFirstChildWhichIsA("BasePart", true)
                    end
                    if world and world:IsA("BasePart") then
                        if not bestHp or a < bestHp then
                            best, bestHp = world, a
                        end
                    end
                end
            end
        end
    end)
    return best, bestHp
end

local function hitGate(part)
    if not part then
        return
    end
    pcall(function()
        local cf = part.CFrame * CFrame.new(0, 0, 4)
        F.smoothTP(cf, 10)
    end)
    pcall(function()
        local guid = part:GetAttribute("Id") or part:GetAttribute("UID") or part:GetAttribute("Guid")
        if not guid and part.Parent then
            guid = part.Parent:GetAttribute("Id") or part.Parent.Name
        end
        if guid then
            invokeRaid("1", tostring(guid))
        end
    end)
end

local function clearGates()
    local t = tick()
    local lastHp, stable = nil, 0
    while raidOn and tick() - t < 180 do
        if guiHas("victory") or guiHas("raid result") then
            return true
        end
        local gate, hp = findRaidGate()
        if gate then
            F.setStatus("Gate " .. tostring(hp))
            hitGate(gate)
            if lastHp == hp then
                stable = stable + 1
            else
                stable = 0
                lastHp = hp
            end
            if stable > 8 then
                pcall(function()
                    F.smoothTP(gate.CFrame * CFrame.new(0, 2, 0), 6)
                end)
                stable = 0
            end
        else
            if guiHas("victory") then
                return true
            end
        end
        task.wait(0.35)
    end
    return guiHas("victory") or guiHas("raid result")
end

local function findEmperorGuid()
    local guid
    pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            local n = string.lower(d.Name or "")
            if n:find("emperor", 1, true) then
                guid = d:GetAttribute("Id") or d:GetAttribute("UID") or d:GetAttribute("Guid") or guid
                if typeof(guid) == "string" and #guid >= 8 then
                    return
                end
                for _, ch in ipairs(d:GetChildren()) do
                    if ch:IsA("StringValue") and #ch.Value >= 8 then
                        guid = ch.Value
                        return
                    end
                end
            end
        end
    end)
    return guid
end

local function hatchEmperor()
    if not hatchAfterRaid then
        return
    end
    F.setStatus("Hatch egg")
    local amount = 12
    if guiHas("x12") or guiHas("open x12") then
        amount = 12
        clickLabel("x12")
    elseif guiHas("x6") then
        amount = 6
        clickLabel("x6")
    else
        clickLabel("open x1")
        amount = 1
    end
    local guid = findEmperorGuid()
    if guid then
        invokeRaid("EmperorEgg", amount, guid)
    else
        invokeRaid("EmperorEgg", amount)
    end
    task.wait(1.2)
end

local function leaveRaid()
    F.setStatus("Leave raid")
    clickLabel("spawn")
    invokeRaid("RaidEvent")
    pcall(function()
        for _, d in ipairs(workspace:GetDescendants()) do
            local n = string.lower(d.Name or "")
            if (n:find("portal", 1, true) or n:find("spawn", 1, true)) and d:IsA("BasePart") then
                if (d.Position - F.getHRP().Position).Magnitude < 180 then
                    F.smoothTP(d.CFrame + Vector3.new(0, 3, 0), 8)
                    break
                end
            end
        end
    end)
    task.wait(1)
end

    if not enterRaidHub() then
        enterRaidHub()
    end
    task.wait(0.4)
    startRaidLobby()
    task.wait(0.6)
    clearGates()
    hatchEmperor()
    leaveRaid()
    task.wait(1.2)
end

function F.doFullCycle()
    if not eventEntered then
        F.setStatus("Entering event")
        F.invokeNet("RNGEvent")
        task.wait(2.2)
        eventEntered = true
    end
    if merchantOn then
        F.visitMerchant()
    end
    F.goWinter()
    if autoRollOn then
        F.recoverAutoRoll()
    end
    while running do
        local result = F.farmWinter()
        if result == "stop" or not running then
            return
        end
        if result == "need_merchant" then
            F.visitMerchant()
            F.goWinter()
            if autoRollOn then
                F.recoverAutoRoll()
            end
        elseif result == "need_void" then
            if F.merchantDue() then
                F.visitMerchant()
                F.goWinter()
                if autoRollOn then
                    F.recoverAutoRoll()
                end
            else
                local r = F.visitVoid()
                if r == "merchant" then
                    F.visitMerchant()
                    F.goWinter()
                    if autoRollOn then
                        F.recoverAutoRoll()
                    end
                elseif r == "success" then
                    F.setStatus("Restarting farm")
                    if F.merchantDue() then
                        F.visitMerchant()
                    end
                    F.goWinter()
                    if autoRollOn then
                        F.recoverAutoRoll()
                    end
                end
            end
        end
    end
end

function F.getHost()
    local pg = LP.PlayerGui
    local main = pg:FindFirstChild("Main")
    if main then
        return main
    end
    for _, g in ipairs(pg:GetChildren()) do
        if g:IsA("LayerCollector") then
            return g
        end
    end
    return pg
end

local host = F.getHost()
pcall(function()
    local old = host:FindFirstChild("OsamaHub")
    if old then
        old:Destroy()
    end
    local oldW = host:FindFirstChild("OsamaWarn")
    if oldW then
        oldW:Destroy()
    end
    local oldS = host:FindFirstChild("OsamaMercCard")
    if oldS then
        oldS:Destroy()
    end
end)
pcall(function()
    local old = LP.PlayerGui:FindFirstChild("OsamaHub")
    if old then
        old:Destroy()
    end
end)

function F.corner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = p
end

function F.stroke(p, col, tr)
    local s = Instance.new("UIStroke")
    s.Color = col or LINE
    s.Transparency = tr or 0.4
    s.Thickness = 1
    s.Parent = p
end

function F.txt(parent, props)
    local x = Instance.new("TextLabel")
    x.BackgroundTransparency = 1
    x.Font = Enum.Font.GothamMedium
    x.TextColor3 = WHITE
    x.TextSize = 12
    x.TextXAlignment = Enum.TextXAlignment.Left
    for k, v in pairs(props) do
        x[k] = v
    end
    x.Parent = parent
    return x
end

local Panel = Instance.new("Frame")
Panel.Name = "OsamaHub"
Panel.Size = UDim2.new(0, 236, 0, 444)
Panel.Position = UDim2.new(0, 16, 0.22, 0)
Panel.BackgroundColor3 = BG
Panel.BorderSizePixel = 0
Panel.ZIndex = 50
Panel.Parent = host
F.corner(Panel, 14)
F.stroke(Panel, Color3.fromRGB(48, 52, 64), 0.35)

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
F.corner(badge, 7)
F.stroke(badge, GOLD, 0.45)
F.txt(badge, {
    Size = UDim2.new(1, 0, 1, 0),
    Text = "O",
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = GOLD,
    TextXAlignment = Enum.TextXAlignment.Center
})
F.txt(header, {
    Size = UDim2.new(1, -50, 0, 16),
    Position = UDim2.new(0, 36, 0, 4),
    Text = "OSAMA HUB",
    Font = Enum.Font.GothamBold,
    TextSize = 14
})
F.txt(header, {
    Size = UDim2.new(1, -50, 0, 14),
    Position = UDim2.new(0, 36, 0, 20),
    Text = "RNG - Clicker Simulator",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = MUTED
})

StatusDot = Instance.new("Frame")
StatusDot.Size = UDim2.new(0, 7, 0, 7)
StatusDot.Position = UDim2.new(1, -8, 0, 8)
StatusDot.BackgroundColor3 = Color3.fromRGB(70, 76, 90)
StatusDot.BorderSizePixel = 0
StatusDot.Parent = header
F.corner(StatusDot, 8)

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -20, 0, 1)
divider.Position = UDim2.new(0, 10, 0, 54)
divider.BackgroundColor3 = LINE
divider.BorderSizePixel = 0
divider.Parent = Panel

function F.makeToggle(text, sub, y)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 34)
    btn.Position = UDim2.new(0, 10, 0, y)
    btn.BackgroundColor3 = ROW
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.Parent = Panel
    F.corner(btn, 10)
    F.txt(btn, {
        Size = UDim2.new(1, -56, 0, 15),
        Position = UDim2.new(0, 12, 0, 5),
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 12
    })
    F.txt(btn, {
        Size = UDim2.new(1, -56, 0, 13),
        Position = UDim2.new(0, 12, 0, 21),
        Text = sub,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = MUTED
    })
    local pill = Instance.new("Frame")
    pill.Name = "Pill"
    pill.Size = UDim2.new(0, 32, 0, 18)
    pill.Position = UDim2.new(1, -42, 0.5, -9)
    pill.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
    pill.Parent = btn
    F.corner(pill, 9)
    local knob = Instance.new("Frame")
    knob.Name = "Knob"
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, 2, 0.5, -7)
    knob.BackgroundColor3 = Color3.fromRGB(210, 214, 224)
    knob.Parent = pill
    F.corner(knob, 8)
    return btn, pill, knob
end

local CycleBtn, CyclePill, CycleKnob = F.makeToggle("Auto RNG Rebirth", "Winter + Void", 58)
local MercBtn, MercPill, MercKnob = F.makeToggle("Dice Merchant", "Buy on restock", 96)
local ComboBtn, ComboPill, ComboKnob = F.makeToggle("Dice + Auto RNG", "Merchant then rebirth", 134)
local RollBtn, RollPill, RollKnob = F.makeToggle("Auto Roll", "Keep rolling", 172)
local AfkBtn, AfkPill, AfkKnob = F.makeToggle("Anti-AFK", "No idle kick", 210)
local RaidBtn, RaidPill, RaidKnob = F.makeToggle("Auto Raid", "Max diff + hatch", 248)

function F.setToggle(pill, knob, on, onColor)
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
stats.Size = UDim2.new(1, -20, 0, 148)
stats.Position = UDim2.new(0, 10, 0, 288)
stats.BackgroundColor3 = CARD
stats.Parent = Panel
F.corner(stats, 12)

Status = F.txt(stats, {
    Size = UDim2.new(1, -16, 0, 14),
    Position = UDim2.new(0, 10, 0, 8),
    Text = "Idle",
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextColor3 = GOLD
})

local sep = Instance.new("Frame")
sep.Size = UDim2.new(1, -20, 0, 1)
sep.Position = UDim2.new(0, 10, 0, 28)
sep.BackgroundColor3 = LINE
sep.BorderSizePixel = 0
sep.Parent = stats

function F.row(y, key)
    F.txt(stats, {
        Size = UDim2.new(0.52, 0, 0, 16),
        Position = UDim2.new(0, 10, 0, y),
        Text = key,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = MUTED
    })
    return F.txt(stats, {
        Size = UDim2.new(0.44, 0, 0, 16),
        Position = UDim2.new(0.52, 0, 0, y),
        Text = "-",
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right
    })
end

CoinLbl = F.row(32, "COINS")
CostLbl = F.row(50, "REBIRTH")
EtaLbl = F.row(68, "ETA")
AvgLbl = F.row(86, "AVG")
TotalLbl = F.row(104, "TOTAL")
SessionLbl = F.row(122, "SESSION")

function F.stockLine()
    local bits = {}
    for i = 1, 3 do
        if merchantOffers[i] then
            table.insert(bits, tostring(merchantOffers[i].stock or 0))
        else
            table.insert(bits, "-")
        end
    end
    return table.concat(bits, " / ")
end

SidePanel = Instance.new("Frame")
SidePanel.Name = "OsamaMercCard"
SidePanel.Size = UDim2.new(0, 188, 0, 156)
SidePanel.Position = UDim2.new(0, 260, 0.22, 48)
SidePanel.BackgroundColor3 = BG
SidePanel.BorderSizePixel = 0
SidePanel.Visible = false
SidePanel.ZIndex = 50
SidePanel.Parent = host
F.corner(SidePanel, 14)
F.stroke(SidePanel, Color3.fromRGB(48, 52, 64), 0.35)

F.txt(SidePanel, {
    Size = UDim2.new(1, -16, 0, 16),
    Position = UDim2.new(0, 10, 0, 8),
    Text = "DICE MERCHANT",
    Font = Enum.Font.GothamBold,
    TextSize = 12,
    TextColor3 = ACCENT4
})

function F.sideRow(y, key)
    F.txt(SidePanel, {
        Size = UDim2.new(0.48, 0, 0, 16),
        Position = UDim2.new(0, 10, 0, y),
        Text = key,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = MUTED
    })
    return F.txt(SidePanel, {
        Size = UDim2.new(0.46, 0, 0, 16),
        Position = UDim2.new(0.50, 0, 0, y),
        Text = "-",
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right
    })
end

SideMerc = F.sideRow(32, "RESTOCK")
SideStock = F.sideRow(54, "STOCK")
SideCoins = F.sideRow(76, "COINS")
SideCost = F.sideRow(98, "REBIRTH")
SideEta = F.sideRow(120, "ETA")

function F.setSideVisible(on)
    if not SidePanel then
        return
    end
    SidePanel.Visible = on and true or false
end

F.txt(Panel, {
    Size = UDim2.new(1, 0, 0, 12),
    Position = UDim2.new(0, 0, 1, -18),
    Text = "Right Shift - osamahub",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = Color3.fromRGB(80, 86, 98),
    TextXAlignment = Enum.TextXAlignment.Center
})

local Warn = Instance.new("Frame")
Warn.Name = "OsamaWarn"
Warn.Size = UDim2.new(1, 0, 1, 0)
Warn.BackgroundColor3 = Color3.fromRGB(4, 5, 8)
Warn.BackgroundTransparency = 0.35
Warn.BorderSizePixel = 0
Warn.ZIndex = 90
Warn.Parent = host

local Card = Instance.new("Frame")
Card.Size = UDim2.new(0, 340, 0, 210)
Card.AnchorPoint = Vector2.new(0.5, 0.5)
Card.Position = UDim2.new(0.5, 0, 0.5, 0)
Card.BackgroundColor3 = BG
Card.BorderSizePixel = 0
Card.ZIndex = 91
Card.Parent = Warn
F.corner(Card, 14)
F.stroke(Card, Color3.fromRGB(48, 52, 64), 0.35)

F.txt(Card, {
    Size = UDim2.new(1, -24, 0, 22),
    Position = UDim2.new(0, 12, 0, 16),
    Text = "WARNING",
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    TextColor3 = GOLD,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 92
})

F.txt(Card, {
    Size = UDim2.new(1, -32, 0, 72),
    Position = UDim2.new(0, 16, 0, 46),
    Text = "For the script to work properly:\nManually teleport to RNG Dice SPAWN,\nthen turn on Full Cycle.",
    Font = Enum.Font.Gotham,
    TextSize = 13,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 92
})

local TimerPill = Instance.new("Frame")
TimerPill.Size = UDim2.new(0, 44, 0, 34)
TimerPill.Position = UDim2.new(0, 16, 1, -50)
TimerPill.BackgroundColor3 = Color3.fromRGB(28, 24, 16)
TimerPill.BorderSizePixel = 0
TimerPill.ZIndex = 92
TimerPill.Parent = Card
F.corner(TimerPill, 8)
F.stroke(TimerPill, GOLD, 0.45)

local TimerLbl = F.txt(TimerPill, {
    Size = UDim2.new(1, 0, 1, 0),
    Text = "5",
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = GOLD,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 93
})

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(1, -76, 0, 34)
CloseBtn.Position = UDim2.new(0, 66, 1, -50)
CloseBtn.BackgroundColor3 = Color3.fromRGB(28, 30, 38)
CloseBtn.AutoButtonColor = false
CloseBtn.Text = "Please wait"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 13
CloseBtn.TextColor3 = MUTED
CloseBtn.Active = false
CloseBtn.ZIndex = 92
CloseBtn.Parent = Card
F.corner(CloseBtn, 8)

local warnLocked = true
task.spawn(function()
    for i = 5, 1, -1 do
        TimerLbl.Text = tostring(i)
        task.wait(1)
    end
    warnLocked = false
    TimerLbl.Text = "OK"
    CloseBtn.Active = true
    CloseBtn.AutoButtonColor = true
    CloseBtn.Text = "Close"
    CloseBtn.TextColor3 = Color3.fromRGB(20, 16, 10)
    CloseBtn.BackgroundColor3 = GOLD
end)

CloseBtn.MouseButton1Click:Connect(function()
    if warnLocked then
        return
    end
    Warn:Destroy()
end)

local open = true
local tw = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
function F.toggleGui()
    open = not open
    pcall(function()
        TweenService:Create(Panel, tw, {
            Position = open and UDim2.new(0, 16, 0.22, 0) or UDim2.new(0, -270, 0.22, 0)
        }):Play()
        if SidePanel then
            TweenService:Create(SidePanel, tw, {
                Position = open and UDim2.new(0, 260, 0.22, 48) or UDim2.new(0, -220, 0.22, 48)
            }):Play()
        end
    end)
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then
        return
    end
    if input.KeyCode == Enum.KeyCode.RightShift then
        F.toggleGui()
    end
end)

local lastUi = 0
RunService.Heartbeat:Connect(function()
    if tick() - lastUi < 0.25 then
        return
    end
    lastUi = tick()
    pcall(F.updateCoins)
    pcall(F.updateRebirthCost)
    pcall(F.updateRate)
    pcall(F.refreshEtaAvg)
    pcall(function()
        if Status then
            Status.Text = statusText
        end
        if CoinLbl then
            CoinLbl.Text = tostring(cachedCoinsText)
        end
        if CostLbl then
            CostLbl.Text = tostring(cachedCostText)
        end
        if EtaLbl then
            EtaLbl.Text = etaText
        end
        if AvgLbl then
            AvgLbl.Text = avgText
        end
        if TotalLbl then
            TotalLbl.Text = tostring(totalRebirths)
        end
        if SessionLbl then
            SessionLbl.Text = tostring(sessionRebirths)
        end
        if MercLbl then
            MercLbl.Text = tostring(merchantText)
        end
        if SideMerc then
            SideMerc.Text = tostring(merchantText)
        end
        if SideStock then
            SideStock.Text = F.stockLine()
        end
        if SideCoins then
            SideCoins.Text = tostring(cachedCoinsText)
        end
        if SideCost then
            SideCost.Text = tostring(cachedCostText)
        end
        if SideEta then
            SideEta.Text = etaText
        end
    end)
end)

local cycleThread

function F.stopCycle()
    running = false
    if cycleThread then
        pcall(function()
            task.cancel(cycleThread)
        end)
        cycleThread = nil
    end
    F.setToggle(CyclePill, CycleKnob, false, ACCENT)
    pcall(function()
        StatusDot.BackgroundColor3 = Color3.fromRGB(70, 76, 90)
    end)
    F.setStatus("Stopped")
end

function F.startCycle()
    if cycleThread then
        pcall(function()
            task.cancel(cycleThread)
        end)
        cycleThread = nil
    end
    running = true
    cycleStart = tick()
    lastRebirthAt = tick()
    eventEntered = false
    F.setToggle(CyclePill, CycleKnob, not comboOn, ACCENT)
    pcall(function()
        StatusDot.BackgroundColor3 = ACCENT
    end)
    F.setStatus("Starting")
    cycleThread = task.spawn(function()
        while running do
            local ok, err = pcall(F.doFullCycle)
            if not running then
                break
            end
            if not ok then
                F.setStatus("Retry")
                print("[osamahub] cycle", err)
                task.wait(2)
            else
                task.wait(1)
            end
        end
        F.setStatus("Stopped")
    end)
end

function F.setMerchantMode(on)
    merchantOn = on
    F.setToggle(MercPill, MercKnob, on and not comboOn, ACCENT4)
    F.setSideVisible(on)
    if on then
        task.spawn(function()
            pcall(F.visitMerchant)
            if running then
                pcall(F.goWinter)
                if autoRollOn then
                    F.startRollWatch()
                    F.recoverAutoRoll()
                end
            end
        end)
    else
        restockAt = nil
        merchantText = "Off"
    end
end

function F.setCombo(on)
    comboOn = on
    F.setToggle(ComboPill, ComboKnob, on, GOLD)
    if on then
        F.setToggle(CyclePill, CycleKnob, false, ACCENT)
        F.setToggle(MercPill, MercKnob, false, ACCENT4)
        merchantOn = true
        F.setSideVisible(true)
        F.startCycle()
        F.setToggle(CyclePill, CycleKnob, false, ACCENT)
    else
        merchantOn = false
        F.setSideVisible(false)
        F.stopCycle()
    end
end

CycleBtn.MouseButton1Click:Connect(function()
    if comboOn then
        F.setCombo(false)
    end
    if running then
        F.stopCycle()
    else
        F.startCycle()
        F.setToggle(CyclePill, CycleKnob, true, ACCENT)
    end
end)

MercBtn.MouseButton1Click:Connect(function()
    if comboOn then
        comboOn = false
        F.setToggle(ComboPill, ComboKnob, false, GOLD)
        F.stopCycle()
    end
    F.setMerchantMode(not merchantOn)
end)

ComboBtn.MouseButton1Click:Connect(function()
    F.setCombo(not comboOn)
end)

RollBtn.MouseButton1Click:Connect(function()
    autoRollOn = not autoRollOn
    F.setToggle(RollPill, RollKnob, autoRollOn, ACCENT3)
    if autoRollOn then
        F.startRollWatch()
        F.recoverAutoRoll()
    else
        F.stopAutoRoll()
    end
end)

AfkBtn.MouseButton1Click:Connect(function()
    afkEnabled = not afkEnabled
    F.setToggle(AfkPill, AfkKnob, afkEnabled, ACCENT2)
    if afkEnabled then
        F.startAntiAFK()
    else
        F.stopAntiAFK()
    end
end)

RaidBtn.MouseButton1Click:Connect(function()
    raidOn = not raidOn
    F.setToggle(RaidPill, RaidKnob, raidOn, GOLD)
    if raidOn then
        raidThread = task.spawn(function()
            while raidOn do
                local ok, err = pcall(doRaidCycle)
                if not ok then
                    F.setStatus("Raid retry")
                    print("[osamahub] raid", err)
                    task.wait(2)
                else
                    task.wait(1)
                end
            end
            F.setStatus("Raid off")
        end)
    else
        if raidThread then
            pcall(function()
                task.cancel(raidThread)
            end)
            raidThread = nil
        end
        F.setStatus("Raid off")
    end
end)

afkEnabled = true
F.setToggle(AfkPill, AfkKnob, true, ACCENT2)
F.startAntiAFK()
print("[osamahub] ready")
