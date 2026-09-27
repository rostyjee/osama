-- osamahub raid
-- Claim -> Start -> RaidLobby TP -> walk to each door -> Hit until dead -> Leave
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
repeat task.wait() until game:IsLoaded() and LP and LP:FindFirstChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local Init = remotes:FindFirstChild("Init")
local HttpService = game:GetService("HttpService")
local Network
pcall(function()
    Network = require(ReplicatedStorage.Library.Client.Network)
end)

local running = false
local enabled = false
local cycleThread
local rewardCount = 0
local Status

local function say(t)
    print("[raid1] " .. tostring(t))
    if Status then
        pcall(function()
            Status.Text = t
        end)
    end
end

local function getHRP()
    local c = LP.Character or LP.CharacterAdded:Wait()
    return c:WaitForChild("HumanoidRootPart")
end


local function startRewardWatch()
    pcall(function()
        for _, ev in ipairs(remotes:GetChildren()) do
            if ev:IsA("RemoteEvent") then
                ev.OnClientEvent:Connect(function(...)
                    local args = table.pack(...)
                    for i = 1, args.n do
                        local v = args[i]
                        if v == "Reward" or v == "RaidEnd" or v == "GateDestroyed" then
                            rewardCount = rewardCount + 1
                            print("[raid1] reward", rewardCount, v)
                        end
                    end
                end)
            end
        end
    end)
end
startRewardWatch()

local function kids()
    return remotes:GetChildren()
end

local function invoke(ev, a, b, c)
    if not ev then
        return nil
    end
    local res
    local ok = pcall(function()
        if c ~= nil then
            res = ev:InvokeServer(a, b, c)
        elseif b ~= nil then
            res = ev:InvokeServer(a, b)
        elseif a ~= nil then
            res = ev:InvokeServer(a)
        else
            res = ev:InvokeServer()
        end
    end)
    if not ok then
        return nil
    end
    return res
end

local function findCluster()
    local list = kids()
    local slotsI, slotsEv
    for i = 130, math.min(180, #list) do
        local ev = list[i]
        if ev and ev:IsA("RemoteFunction") then
            local res
            local ok = pcall(function()
                res = ev:InvokeServer()
            end)
            if ok and type(res) == "table" then
                for _, info in pairs(res) do
                    if type(info) == "table" and info.Slot ~= nil and info.Difficulty ~= nil then
                        slotsI, slotsEv = i, ev
                        break
                    end
                end
            end
        end
        if slotsEv then
            break
        end
    end
    if not slotsI then
        slotsI = 146
        slotsEv = list[146]
    end
    local function at(off)
        return list[slotsI + off]
    end
    return {
        slotsI = slotsI,
        slots = slotsEv,
        claim = at(1),
        cfg = at(2),
        start = at(4),
        unclaim = at(3),
        hit = at(15),
        lobbyRF = at(16),
        leave = at(17),
        lobbyRE = at(18),
    }
end

local function petGuids()
    local out = {}
    pcall(function()
        local Pet = require(ReplicatedStorage.Library.Client.Pet)
        for _, data in pairs(Pet.Pets) do
            if type(data) == "table" and type(data.GUID) == "string" and #data.GUID == 16 then
                table.insert(out, data.GUID)
            end
        end
    end)
    return out
end

local function pickSlot(R)
    local mine, empty
    pcall(function()
        local all = R.slots:InvokeServer()
        if type(all) ~= "table" then
            return
        end
        for _, info in pairs(all) do
            if type(info) == "table" then
                if info.OwnerName == LP.Name then
                    mine = info.Slot
                elseif not empty and info.Started ~= true and (info.OwnerName == nil or info.OwnerName == "") then
                    empty = info.Slot
                end
            end
        end
    end)
    return mine or empty or 1
end

local function groundY(pos)
    local origin = pos + Vector3.new(0, 30, 0)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    if LP.Character then
        params.FilterDescendantsInstances = {LP.Character}
    end
    local hit = workspace:Raycast(origin, Vector3.new(0, -90, 0), params)
    if hit then
        return hit.Position.Y + 3.2
    end
    return pos.Y
end

local function smoothTo(pos, look)
    local hrp = getHRP()
    local dir = look
    if typeof(dir) ~= "Vector3" or dir.Magnitude < 0.05 then
        dir = Vector3.new(pos.X - hrp.Position.X, 0, pos.Z - hrp.Position.Z)
    end
    dir = Vector3.new(dir.X, 0, dir.Z)
    if dir.Magnitude < 0.05 then
        dir = Vector3.new(0, 0, -1)
    else
        dir = dir.Unit
    end
    local y = groundY(pos)
    local goal = CFrame.new(Vector3.new(pos.X, y, pos.Z), Vector3.new(pos.X, y, pos.Z) + dir)
    local startCf = hrp.CFrame
    for i = 1, 10 do
        hrp.CFrame = startCf:Lerp(goal, i / 10)
        task.wait(0.02)
    end
    hrp.CFrame = goal
end

local function groundY(pos)
    local origin = pos + Vector3.new(0, 30, 0)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    if LP.Character then
        params.FilterDescendantsInstances = {LP.Character}
    end
    local hit = workspace:Raycast(origin, Vector3.new(0, -90, 0), params)
    if hit then
        return hit.Position.Y + 3.2
    end
    return pos.Y
end

local function smoothTo(pos, lookAt)
    local hrp = getHRP()
    local y = groundY(pos)
    local dest = Vector3.new(pos.X, y, pos.Z)
    local look = lookAt or dest
    local goal = CFrame.new(dest, Vector3.new(look.X, y, look.Z))
    local startCf = hrp.CFrame
    for i = 1, 4 do
        hrp.CFrame = startCf:Lerp(goal, i / 4)
        task.wait(0.01)
    end
    hrp.CFrame = goal
end

local function roomGates()
    local out = {}
    local rooms
    pcall(function()
        rooms = workspace._THINGS.Minigames.RaidLobby.Rooms
    end)
    if not rooms then
        return out
    end
    for i = 1, 6 do
        local room = rooms:FindFirstChild(tostring(i))
        if room then
            local gate = room:FindFirstChild("Gate")
            local hit = gate and gate:FindFirstChild("Hitbox")
            if hit then
                table.insert(out, {n = i, part = hit, room = room})
            end
        end
    end
    return out
end

local function hitGate(R, pets, n)
    if not R.hit then
        return
    end
    local gs = tostring(n)
    for i = 1, #pets do
        invoke(R.hit, gs, pets[i])
    end
end

local function pushPath(R, pets)
    local gates = roomGates()
    print("[raid1] room gates", #gates)
    if #gates == 0 then
        say("No Rooms.Gate")
        return
    end
    for i = 1, #gates do
        if not running then
            break
        end
        local g = gates[i]
        say("Gate " .. tostring(g.n))
        local part = g.part
        -- stand in front of the wooden door, not inside hitbox
        local hrp = getHRP()
        local flat = Vector3.new(part.Position.X - hrp.Position.X, 0, part.Position.Z - hrp.Position.Z)
        if flat.Magnitude < 0.05 then
            flat = Vector3.new(0, 0, -1)
        else
            flat = flat.Unit
        end
        local stand = part.Position - flat * 5
        smoothTo(stand, part.Position)
        print("[raid1] at gate", g.n, getHRP().Position)
        local bh = g.room:FindFirstChild("BreakableHealth")
        print("[raid1] BH", bh and bh.ClassName, bh and bh:GetFullName())
        if bh then
            for _, a in ipairs(bh:GetAttributes()) do
            end
            pcall(function()
                for k, v in pairs(bh:GetAttributes()) do
                    print("[raid1] BHattr", k, v)
                end
                for _, d in ipairs(bh:GetDescendants()) do
                    print("[raid1] BHchild", d.ClassName, d.Name, d:IsA("ValueBase") and d.Value or "")
                end
            end)
        end
        local function hpNow()
            local bh = g.room:FindFirstChild("BreakableHealth")
            if not bh then
                return nil
            end
            local lab = bh:FindFirstChild("Label", true)
            if not (lab and lab:IsA("TextLabel")) then
                return nil
            end
            local txt = lab.Text or ""
            local cur = string.match(txt, "([%d%.]+)%s*/")
            return tonumber(cur), txt
        end
        local lab0
        pcall(function()
            lab0 = g.room.BreakableHealth:FindFirstChild("Label", true).Text
        end)
        print("[raid1] label", lab0)
        local hitting = true
        task.spawn(function()
            while hitting and running do
                for i = 1, #pets do
                    if not hitting then
                        break
                    end
                    task.spawn(function()
                        invoke(R.hit, tostring(g.n), pets[i])
                    end)
                end
                task.wait(0.08)
            end
        end)
        local t0 = os.clock()
        local lastPrint = 0
        local seenHp
        local damaged = false
        while running do
            local hp, txt = hpNow()
            if hp then
                seenHp = seenHp or hp
                if hp < seenHp then
                    damaged = true
                end
            end
            if hp == 0 then
                print("[raid1] gate down", g.n, "zero")
                break
            end
            if damaged and hp == nil then
                print("[raid1] gate down", g.n, "label gone")
                break
            end
            if os.clock() - lastPrint > 0.3 then
                lastPrint = os.clock()
                print("[raid1] label now", txt, hp, damaged)
            end
            if os.clock() - t0 > 15 then
                print("[raid1] gate timeout", g.n)
                break
            end
            task.wait(0.04)
        end
        hitting = false
    end
end


local function findEmperor()
    local best
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            local n = string.lower(d.Name)
            if string.find(n, "emperor", 1, true) then
                best = d
                break
            end
        end
    end
    if best then
        return best
    end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            local n = string.lower(d.Name)
            if string.find(n, "egg", 1, true) and not string.find(n, "billboard", 1, true) then
                local fn = string.lower(d:GetFullName())
                if string.find(fn, "raid", 1, true) or string.find(fn, "event", 1, true) or string.find(fn, "minigame", 1, true) then
                    return d
                end
            end
        end
    end
    return nil
end

local function hatchAmount()
    local n = 12
    pcall(function()
        for _, d in ipairs(LP.PlayerGui:GetDescendants()) do
            if d:IsA("TextLabel") or d:IsA("TextButton") then
                local t = d.Text or ""
                local m = string.match(t, "[Xx]%s*(%d+)")
                if not m then
                    m = string.match(t, "Open%s+(%d+)")
                end
                if m then
                    local v = tonumber(m)
                    if v and v > n and v <= 30 then
                        n = v
                    end
                end
            end
        end
    end)
    return n
end

local function hatchEmperor()
    say("Hatch Emperor")
    local part
    pcall(function()
        part = workspace._THINGS.Minigames.RaidEvent.Map.Scenery.Decor.EmperorEgg.EggModel
    end)
    if not part then
        part = findEmperor()
    end
    print("[raid1] egg part", part and part:GetFullName())
    pcall(function()
        if part then
            local cf = part:IsA("Model") and part:GetPivot() or part.CFrame
            getHRP().CFrame = cf * CFrame.new(0, 3, 6)
        end
    end)
    task.wait(0.45)
    local amt = 12
    task.spawn(function()
        pcall(function()
            local OpenEgg = require(ReplicatedStorage.Library.Client.OpenEgg)
            pcall(function()
                OpenEgg.Request("EmperorEgg", amt)
            end)
            pcall(function()
                OpenEgg.Play("EmperorEgg", amt)
            end)
        end)
        local guid = HttpService:GenerateGUID(false)
        local list = remotes:GetChildren()
        for _, i in ipairs({91, 90, 92, 89}) do
            local ev = list[i]
            if ev and ev:IsA("RemoteFunction") then
                pcall(function()
                    ev:InvokeServer("EmperorEgg", amt, guid)
                end)
            end
        end
    end)
    task.wait(1.4)
    say("Hatch done")
end

local function go()
    running = true
    say("Resolve remotes")
    local R = findCluster()
    print("[raid1] cluster slotsI", R.slotsI)

    pcall(function()
        if R.unclaim then
            for i = 1, 10 do
                invoke(R.unclaim, i)
            end
        end
    end)
    task.wait(0.25)
    local slot = pickSlot(R)
    local claimed = invoke(R.claim, slot)
    print("[raid1] claim", slot, claimed)
    if claimed ~= true then
        for i = 1, 10 do
            local ok = invoke(R.claim, i)
            print("[raid1] claim try", i, ok)
            if ok == true then
                slot, claimed = i, true
                break
            end
        end
    end
    if claimed ~= true then
        say("No empty slot")
        running = false
        return
    end

    for d = 2, 1, -1 do
        local res = invoke(R.cfg, slot, d, "Public")
        print("[raid1] cfg", slot, d, res)
        if res then
            break
        end
    end

    local started = invoke(R.start, slot)
    print("[raid1] start", slot, started)
    say("Start " .. tostring(started))

    if Init then
        pcall(function()
            Init:FireServer("RaidPortals", "RemoteEvent", "SlotUpdated")
            Init:FireServer("RaidGates", "RemoteEvent", "State")
            Init:FireServer("RaidGates", "RemoteEvent", "Snapshot")
        end)
    end

    invoke(R.lobbyRF, "RaidLobby")
    pcall(function()
        if R.lobbyRE and R.lobbyRE.FireServer then
            R.lobbyRE:FireServer("RaidLobby")
        end
    end)

    say("Wait instance")
    task.wait(0.4)

    local pets = petGuids()
    print("[raid1] pets", #pets)
    if #pets == 0 then
        say("No pets")
        running = false
        return
    end

    local readyAt = os.clock()
    while #roomGates() == 0 and os.clock() - readyAt < 6 do
        say("Wait rooms")
        task.wait(0.2)
    end
    print("[raid1] rooms ready", #roomGates())
    if #roomGates() == 0 then
        say("No rooms — stop")
        running = false
        return
    end
    pushPath(R, pets)

    say("Leaving")
    task.wait(0.35)
    invoke(R.leave)
    say("Wait hatch world")
    task.wait(1)
    hatchEmperor()
    running = false
    say(enabled and "Loop" or "Done")
end

local function host()
    local p
    pcall(function()
        if gethui then
            p = gethui()
        end
    end)
    return p or game:GetService("CoreGui")
end

pcall(function()
    local old = host():FindFirstChild("OsamaRaid1")
    if old then
        old:Destroy()
    end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "OsamaRaid1"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 9999
gui.Parent = host()

local box = Instance.new("Frame")
box.Size = UDim2.fromOffset(240, 100)
box.Position = UDim2.new(0, 20, 0.5, -50)
box.BackgroundColor3 = Color3.fromRGB(16, 18, 24)
box.BorderSizePixel = 0
box.Parent = gui
Instance.new("UICorner", box).CornerRadius = UDim.new(0, 10)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -12, 0, 22)
title.Position = UDim2.fromOffset(8, 6)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(240, 242, 246)
title.Text = "osamahub raid"
title.Parent = box

Status = Instance.new("TextLabel")
Status.BackgroundTransparency = 1
Status.Size = UDim2.new(1, -12, 0, 18)
Status.Position = UDim2.fromOffset(8, 28)
Status.Font = Enum.Font.Gotham
Status.TextSize = 12
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.TextColor3 = Color3.fromRGB(150, 158, 172)
Status.Text = "raid hub → START"
Status.Parent = box

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -16, 0, 34)
btn.Position = UDim2.fromOffset(8, 56)
btn.BackgroundColor3 = Color3.fromRGB(90, 96, 110)
btn.Text = "AUTO RAID  OFF"
btn.Font = Enum.Font.GothamBold
btn.TextSize = 13
btn.TextColor3 = Color3.fromRGB(16, 18, 24)
btn.Parent = box
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
local function setSwitch(on)
    enabled = on
    btn.Text = on and "AUTO RAID  ON" or "AUTO RAID  OFF"
    btn.BackgroundColor3 = on and Color3.fromRGB(80, 220, 140) or Color3.fromRGB(90, 96, 110)
    btn.TextColor3 = on and Color3.fromRGB(16, 18, 24) or Color3.fromRGB(240, 242, 246)
end

btn.MouseButton1Click:Connect(function()
    if enabled then
        enabled = false
        running = false
        setSwitch(false)
        say("Stopped")
        return
    end
    setSwitch(true)
    cycleThread = task.spawn(function()
        while enabled do
            print("[raid1] cycle start")
            local ok, err = pcall(go)
            print("[raid1] cycle end", ok, err)
            if not ok then
                say("Retry")
            end
            if not enabled then
                break
            end
            say("Next raid")
            task.wait(0.8)
        end
        running = false
        setSwitch(false)
        say("Stopped")
    end)
end)

print("[raid1] ready — raid hub → START RAID")
