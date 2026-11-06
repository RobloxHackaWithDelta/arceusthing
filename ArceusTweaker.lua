--[[
    ArceusX Tweaker
    A layer on top of the Arceus X UI: movable custom logo that always works,
    hides the NEO tag and the top bar, resize grip, and custom open/close
    animations.

    Usage (optional config first, then the loader):
        getgenv().ArceusTweakerConfig = {
            LogoId = "5538771889",
            OpenAnimation = {"Pop", "Fade"},
            CloseAnimation = "Slide",
        }
        loadstring(game:HttpGet("https://raw.githubusercontent.com/YOU/REPO/main/ArceusTweaker.lua"))()

    Built-in animations: None, Pop, Fade, Slide, Drop, Spin
    Use one name, or a list of names to combine them.

    Custom animation: a function(ctx, k). k goes from 0 (hidden) to 1 (shown).
        ctx.Window, ctx.Scale (UIScale), ctx.BaseScale, ctx.OrigPosition,
        ctx.OrigRotation, ctx.Opening
    Example:
        OpenAnimation = function(ctx, k) ctx.Window.Rotation = (1 - k) * 20 end
    Everything is reset automatically when the animation ends.

    If something is not found, set DumpTree = true, run once, then read
    ArceusTree.txt (or the console) for the real instance names and set
    HostName, WindowName, TopBarName, OriginalIconName or HideNames.
]]

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local GUI_NAME = "ArceusTweakerGui"
local SAVE_FILE = "ArceusTweaker.json"
local TREE_FILE = "ArceusTree.txt"

local Config = {
    -- Logo
    LogoId = "5538771889",           -- image or decal asset id, or a full rbx/http link
    LogoSize = 50,
    LogoPosition = UDim2.fromOffset(179, 174),
    LogoDraggable = true,
    UseThumbnail = true,             -- rbxthumb link, works for decal ids AND image ids
    HideOriginalIcon = true,         -- hide the stock Arceus X floating icon
    OriginalIconName = nil,          -- set if the auto-detect hides the wrong thing

    -- Window
    HostName = nil,                  -- ScreenGui name (auto-detected by default)
    WindowName = nil,                -- main window name (auto-detected by default)
    WindowScale = nil,               -- nil = leave the current scale alone
    MinScale = 0.5,
    MaxScale = 1.6,
    ShowResizeGrip = true,
    SaveSettings = true,             -- remembers logo position and window scale

    -- Cleanup
    HideNeo = true,
    StripNeoText = true,             -- turns "Arceus X NEO" text into "Arceus X"
    HideTopBar = true,
    TopBarName = nil,
    HideNames = {},                  -- extra instance names to hide

    -- Skin
    ApplySkin = true,
    WindowColor = Color3.fromRGB(14, 14, 16),
    WindowTransparency = 0.12,
    CornerRadius = 14,
    StrokeColor = Color3.fromRGB(43, 43, 48),
    StrokeThickness = 1,
    AccentColor = Color3.fromRGB(232, 32, 43),

    -- Animations
    OpenAnimation = "Pop",
    CloseAnimation = "Pop",
    AnimTime = 0.25,
    OpenStyle = Enum.EasingStyle.Back,
    OpenDirection = Enum.EasingDirection.Out,
    CloseStyle = Enum.EasingStyle.Quad,
    CloseDirection = Enum.EasingDirection.In,

    -- Misc
    FindTimeout = 20,
    LoadBaseModule = false,          -- also run the customization module first
    BaseModuleUrl = "https://ltseverydayyou.gitlab.io/uuuuuuu/ArceusCustomizationModule.luau",
    DumpTree = false,
}

local env = (getgenv and getgenv()) or _G
if type(env.ArceusTweakerConfig) == "table" then
    for k, v in pairs(env.ArceusTweakerConfig) do
        Config[k] = v
    end
end
if type(env.ArceusTweakerCleanup) == "function" then
    pcall(env.ArceusTweakerCleanup)
end

local conns = {}
local hidden = {}
local state = { window = nil, scale = nil }
local busy = false
local current = nil
local gui, grip, logo
local saved = {}

local function say(...)
    print("[ArceusTweaker]", ...)
end

local function bad(...)
    warn("[ArceusTweaker]", ...)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function textOf(inst)
    if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
        return inst.Text
    end
    return nil
end

local function findAllText(root, wanted, exact)
    wanted = wanted:lower()
    local out = {}
    for _, d in ipairs(root:GetDescendants()) do
        local t = textOf(d)
        if t then
            t = trim(t):lower()
            if (exact and t == wanted) or ((not exact) and t:find(wanted, 1, true)) then
                out[#out + 1] = d
            end
        end
    end
    return out
end

local function textCount(inst)
    local n = textOf(inst) and 1 or 0
    for _, d in ipairs(inst:GetDescendants()) do
        if textOf(d) then
            n = n + 1
        end
    end
    return n
end

local function commonAncestor(a, b)
    local seen = {}
    local cur = a
    while cur do
        seen[cur] = true
        cur = cur.Parent
    end
    cur = b
    while cur do
        if seen[cur] then
            return cur
        end
        cur = cur.Parent
    end
    return nil
end

local function forceHide(inst)
    if not inst or not inst:IsA("GuiObject") then
        return
    end
    if hidden[inst] == nil then
        hidden[inst] = inst.Visible
    end
    inst.Visible = false
    conns[#conns + 1] = inst:GetPropertyChangedSignal("Visible"):Connect(function()
        if inst.Visible then
            inst.Visible = false
        end
    end)
end

local function getRoots()
    local roots = {}
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then
            roots[#roots + 1] = h
        end
    end
    roots[#roots + 1] = CoreGui
    local lp = Players.LocalPlayer
    if lp and lp:FindFirstChildOfClass("PlayerGui") then
        roots[#roots + 1] = lp:FindFirstChildOfClass("PlayerGui")
    end
    return roots
end

local function mountGui(g)
    if syn and syn.protect_gui then
        pcall(syn.protect_gui, g)
    end
    local ok = false
    if gethui then
        ok = pcall(function()
            g.Parent = gethui()
        end)
    end
    if not ok or not g.Parent then
        ok = pcall(function()
            g.Parent = CoreGui
        end)
    end
    if not ok or not g.Parent then
        g.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
    end
end

local function imageFor(id)
    local s = tostring(id or "")
    if s == "" then
        return ""
    end
    if s:match("^%d+$") then
        if Config.UseThumbnail then
            return "rbxthumb://type=Asset&id=" .. s .. "&w=420&h=420"
        end
        return "rbxassetid://" .. s
    end
    return s
end

local function loadSaved()
    if not Config.SaveSettings or not (isfile and readfile) then
        return
    end
    local ok, data = pcall(function()
        if isfile(SAVE_FILE) then
            return HttpService:JSONDecode(readfile(SAVE_FILE))
        end
        return nil
    end)
    if ok and type(data) == "table" then
        saved = data
    end
end

local function save()
    if not Config.SaveSettings or not writefile then
        return
    end
    pcall(function()
        writefile(SAVE_FILE, HttpService:JSONEncode(saved))
    end)
end

local function dumpTree(root)
    local lines = {}
    local function walk(inst, depth)
        if #lines > 700 or depth > 9 then
            return
        end
        local extra = ""
        local t = textOf(inst)
        if t and t ~= "" then
            extra = ' "' .. t:sub(1, 40) .. '"'
        end
        lines[#lines + 1] = string.rep("  ", depth) .. inst.ClassName .. " " .. inst.Name .. extra
        for _, c in ipairs(inst:GetChildren()) do
            walk(c, depth + 1)
        end
    end
    walk(root, 0)
    local out = table.concat(lines, "\n")
    print(out)
    if writefile then
        pcall(writefile, TREE_FILE, out)
        say("tree saved to " .. TREE_FILE)
    end
end

---------------------------------------------------------------------------
-- Finding the Arceus X UI
---------------------------------------------------------------------------

local function findHost()
    for _, root in ipairs(getRoots()) do
        local ok, kids = pcall(root.GetChildren, root)
        if ok then
            for _, g in ipairs(kids) do
                if g:IsA("ScreenGui") and g.Name ~= GUI_NAME then
                    if Config.HostName then
                        if g.Name == Config.HostName then
                            return g, nil
                        end
                    else
                        local ok2, hits = pcall(findAllText, g, "arceus", false)
                        if ok2 and hits[1] then
                            return g, hits[1]
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

local function pickWindow(host, hit)
    if Config.WindowName then
        local w = host:FindFirstChild(Config.WindowName, true)
        if w and w:IsA("GuiObject") then
            return w
        end
    end
    if hit then
        local cur = hit
        while cur and cur.Parent ~= host do
            cur = cur.Parent
        end
        if cur and cur:IsA("GuiObject") then
            return cur
        end
    end
    local best, area = nil, 0
    for _, c in ipairs(host:GetChildren()) do
        if c:IsA("GuiObject") then
            local a = c.AbsoluteSize.X * c.AbsoluteSize.Y
            if a > area then
                best, area = c, a
            end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Cleaning up the UI (NEO tag, top bar, stock icon)
---------------------------------------------------------------------------

local function stripNeo(inst)
    local t = textOf(inst)
    if t and t:find("NEO") then
        local new = t:gsub("%s*%f[%a]NEO%f[%A]", "")
        if new ~= t then
            inst.Text = new
        end
    end
end

local function cleanUi(host, window)
    if Config.HideNeo then
        local count = 0
        for _, d in ipairs(findAllText(window, "neo", true)) do
            forceHide(d)
            count = count + 1
            local p = d.Parent
            if p and p ~= window and p:IsA("GuiObject") and textCount(p) == 1
                and p.AbsoluteSize.X <= 140 and p.AbsoluteSize.Y <= 60 then
                forceHide(p)
            end
        end
        for _, d in ipairs(window:GetDescendants()) do
            if d:IsA("GuiObject") and d.Name:lower() == "neo" then
                forceHide(d)
                count = count + 1
            end
        end
        say("NEO items hidden: " .. count)
    end

    if Config.StripNeoText then
        for _, d in ipairs(window:GetDescendants()) do
            if textOf(d) then
                stripNeo(d)
                conns[#conns + 1] = d:GetPropertyChangedSignal("Text"):Connect(function()
                    stripNeo(d)
                end)
            end
        end
    end

    for _, name in ipairs(Config.HideNames) do
        local o = window:FindFirstChild(name, true)
        if o then
            forceHide(o)
        end
    end

    if Config.HideTopBar then
        local bar = nil
        if Config.TopBarName then
            bar = window:FindFirstChild(Config.TopBarName, true)
        end
        if not bar then
            local infos = findAllText(window, "app info", true)
            local titles = findAllText(window, "arceus x", true)
            local bestArea = math.huge
            if infos[1] then
                for _, b in ipairs(titles) do
                    local lca = commonAncestor(infos[1], b)
                    if lca and lca ~= window and lca ~= host and lca:IsA("GuiObject") then
                        local s = lca.AbsoluteSize
                        if s.Y <= window.AbsoluteSize.Y * 0.4 and (s.X * s.Y) < bestArea then
                            bar = lca
                            bestArea = s.X * s.Y
                        end
                    end
                end
            end
        end
        if bar then
            forceHide(bar)
            say("top bar hidden: " .. bar:GetFullName())
        else
            bad("top bar not found. Set TopBarName (use DumpTree to see names).")
        end
    end

    if Config.HideOriginalIcon then
        if Config.OriginalIconName then
            local o = host:FindFirstChild(Config.OriginalIconName, true)
            if o then
                forceHide(o)
            end
        else
            for _, c in ipairs(host:GetChildren()) do
                if c ~= window and c:IsA("GuiObject") then
                    local s = c.AbsoluteSize
                    local small = s.X > 0 and s.X <= 120 and s.Y <= 120
                    local hasImage = c:IsA("ImageButton") or c:IsA("ImageLabel")
                        or c:FindFirstChildWhichIsA("ImageButton", true)
                        or c:FindFirstChildWhichIsA("ImageLabel", true)
                    if small and hasImage and textCount(c) == 0 then
                        forceHide(c)
                        say("stock icon hidden: " .. c:GetFullName())
                    end
                end
            end
        end
    end
end

local function applySkin(window)
    if window.BackgroundTransparency < 1 then
        window.BackgroundColor3 = Config.WindowColor
        window.BackgroundTransparency = Config.WindowTransparency
    end
    local corner = window:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, Config.CornerRadius)
    corner.Parent = window
    local stroke = window:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
    stroke.Color = Config.StrokeColor
    stroke.Thickness = Config.StrokeThickness
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = window
end

---------------------------------------------------------------------------
-- Animations
---------------------------------------------------------------------------

local function collectFade(window)
    local list = {}
    local function add(inst, prop)
        list[#list + 1] = { inst = inst, prop = prop, value = inst[prop] }
    end
    local all = window:GetDescendants()
    all[#all + 1] = window
    for _, d in ipairs(all) do
        if d:IsA("GuiObject") then
            add(d, "BackgroundTransparency")
        end
        if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
            add(d, "TextTransparency")
        end
        if d:IsA("ImageLabel") or d:IsA("ImageButton") then
            add(d, "ImageTransparency")
        end
        if d:IsA("UIStroke") then
            add(d, "Transparency")
        end
    end
    return list
end

local Anims = {}
Anims.None = function() end
Anims.Pop = function(ctx, k)
    ctx.Scale.Scale = ctx.BaseScale * (0.6 + 0.4 * k)
end
Anims.Fade = function(ctx, k)
    for _, e in ipairs(ctx:GetFade()) do
        e.inst[e.prop] = math.clamp(e.value + (1 - e.value) * (1 - k), 0, 1)
    end
end
Anims.Slide = function(ctx, k)
    ctx.Window.Position = ctx.OrigPosition + UDim2.fromOffset(0, 80 * (1 - k))
end
Anims.Drop = function(ctx, k)
    ctx.Window.Position = ctx.OrigPosition - UDim2.fromOffset(0, 80 * (1 - k))
end
Anims.Spin = function(ctx, k)
    ctx.Window.Rotation = ctx.OrigRotation - 90 * (1 - k)
    ctx.Scale.Scale = ctx.BaseScale * (0.5 + 0.5 * k)
end

local function refreshGrip()
    if not grip then
        return
    end
    local win = state.window
    if not win or not Config.ShowResizeGrip then
        grip.Visible = false
        return
    end
    grip.Visible = win.Visible and not busy
    local p, s = win.AbsolutePosition, win.AbsoluteSize
    grip.Position = UDim2.fromOffset(p.X + s.X - 30, p.Y + s.Y - 30)
end

local function play(opening)
    if busy or not state.window then
        return
    end
    busy = true
    local token = {}
    current = token

    local win = state.window
    local scale = state.scale
    local fade = nil
    local ctx = {
        Window = win,
        Scale = scale,
        BaseScale = scale.Scale,
        OrigPosition = win.Position,
        OrigRotation = win.Rotation,
        Opening = opening,
    }
    function ctx:GetFade()
        if not fade then
            fade = collectFade(win)
        end
        return fade
    end

    local spec = opening and Config.OpenAnimation or Config.CloseAnimation
    local names = {}
    if type(spec) == "table" then
        for _, a in ipairs(spec) do
            names[#names + 1] = a
        end
    else
        names[1] = spec
    end
    local fns = {}
    for _, a in ipairs(names) do
        local f = (type(a) == "function") and a or Anims[a]
        if f then
            fns[#fns + 1] = f
        else
            bad("unknown animation: " .. tostring(a))
        end
    end

    local style = opening and Config.OpenStyle or Config.CloseStyle
    local dir = opening and Config.OpenDirection or Config.CloseDirection
    local dur = math.max(Config.AnimTime, 0.01)
    local conn = nil
    local finished = false

    local function finish()
        if finished then
            return
        end
        finished = true
        if conn then
            conn:Disconnect()
            conn = nil
        end
        win.Position = ctx.OrigPosition
        win.Rotation = ctx.OrigRotation
        scale.Scale = ctx.BaseScale
        if fade then
            for _, e in ipairs(fade) do
                pcall(function()
                    e.inst[e.prop] = e.value
                end)
            end
        end
        if not opening then
            win.Visible = false
        end
        busy = false
        refreshGrip()
    end

    local function step(alpha)
        local eased = TweenService:GetValue(alpha, style, dir)
        local k = opening and eased or (1 - eased)
        for _, f in ipairs(fns) do
            local ok, err = pcall(f, ctx, k)
            if not ok then
                bad("animation error: " .. tostring(err))
            end
        end
    end

    if opening then
        win.Visible = true
    end
    refreshGrip()
    step(0)

    local startTime = os.clock()
    conn = RunService.RenderStepped:Connect(function()
        local alpha = math.clamp((os.clock() - startTime) / dur, 0, 1)
        step(alpha)
        if alpha >= 1 then
            finish()
        end
    end)

    task.delay(dur + 1, function()
        if current == token then
            finish()
        end
    end)
end

local function toggle()
    if state.window then
        play(not state.window.Visible)
    end
end

---------------------------------------------------------------------------
-- Main
---------------------------------------------------------------------------

local function isPointer(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
    return input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
end

local function main()
    if Config.LoadBaseModule then
        pcall(function()
            loadstring(game:HttpGet(Config.BaseModuleUrl))()
        end)
        task.wait(1.5)
    end

    local host, hit
    local deadline = os.clock() + Config.FindTimeout
    repeat
        host, hit = findHost()
        if not host then
            task.wait(0.5)
        end
    until host or os.clock() > deadline
    if not host then
        bad("could not find the Arceus X UI. Open it first, or set HostName.")
        return
    end

    local window = pickWindow(host, hit)
    if not window then
        bad("could not find the main window. Set WindowName.")
        return
    end
    say("host: " .. host:GetFullName() .. " | window: " .. window.Name)

    if Config.DumpTree then
        dumpTree(host)
    end

    loadSaved()

    local scale = window:FindFirstChildOfClass("UIScale")
    if not scale then
        scale = Instance.new("UIScale")
        scale.Scale = 1
        scale.Parent = window
    end
    if type(saved.scale) == "number" then
        scale.Scale = math.clamp(saved.scale, Config.MinScale, Config.MaxScale)
    elseif Config.WindowScale then
        scale.Scale = Config.WindowScale
    end
    state.window = window
    state.scale = scale

    cleanUi(host, window)
    if Config.ApplySkin then
        applySkin(window)
    end

    -- Our own gui: logo + resize grip
    gui = Instance.new("ScreenGui")
    gui.Name = GUI_NAME
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999999
    gui.IgnoreGuiInset = host.IgnoreGuiInset
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    mountGui(gui)

    -- Logo
    logo = Instance.new("ImageButton")
    logo.Name = "Logo"
    logo.AutoButtonColor = false
    logo.BackgroundTransparency = 1
    logo.BorderSizePixel = 0
    logo.Size = UDim2.fromOffset(Config.LogoSize, Config.LogoSize)
    logo.ScaleType = Enum.ScaleType.Fit
    logo.Image = imageFor(Config.LogoId)
    local sp = saved.logo
    if type(sp) == "table" and #sp == 4 then
        logo.Position = UDim2.new(sp[1], sp[2], sp[3], sp[4])
    else
        logo.Position = Config.LogoPosition
    end
    logo.Parent = gui

    -- If the thumbnail does not load, fall back to the plain asset link
    local idStr = tostring(Config.LogoId or "")
    if idStr:match("^%d+$") then
        task.delay(5, function()
            if logo and logo.Parent and not logo.IsLoaded then
                if Config.UseThumbnail then
                    logo.Image = "rbxassetid://" .. idStr
                else
                    logo.Image = "rbxthumb://type=Asset&id=" .. idStr .. "&w=420&h=420"
                end
                say("logo fallback link used")
            end
        end)
    end

    -- Resize grip
    grip = Instance.new("TextButton")
    grip.Name = "ResizeGrip"
    grip.Size = UDim2.fromOffset(26, 26)
    grip.AutoButtonColor = false
    grip.BackgroundColor3 = Config.AccentColor
    grip.BackgroundTransparency = 0.35
    grip.BorderSizePixel = 0
    grip.Text = "//"
    grip.TextColor3 = Color3.new(1, 1, 1)
    grip.TextSize = 14
    grip.Font = Enum.Font.GothamBold
    grip.Visible = false
    grip.Parent = gui
    local gc = Instance.new("UICorner")
    gc.CornerRadius = UDim.new(0, 8)
    gc.Parent = grip

    for _, sig in ipairs({ "AbsolutePosition", "AbsoluteSize", "Visible" }) do
        conns[#conns + 1] = window:GetPropertyChangedSignal(sig):Connect(refreshGrip)
    end
    refreshGrip()

    -- Logo drag / click
    local dragging, moved = false, false
    local dragStart, startPos
    conns[#conns + 1] = logo.InputBegan:Connect(function(input)
        if isPointer(input) then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = logo.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if moved and Config.LogoDraggable then
                        local p = logo.Position
                        saved.logo = { p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset }
                        save()
                    elseif not moved then
                        toggle()
                    end
                end
            end)
        end
    end)

    -- Resize drag
    local resizing = false
    local rStart, rScale, rW, rH
    conns[#conns + 1] = grip.InputBegan:Connect(function(input)
        if isPointer(input) then
            resizing = true
            rStart = input.Position
            rScale = scale.Scale
            rW = math.max(window.AbsoluteSize.X, 1)
            rH = math.max(window.AbsoluteSize.Y, 1)
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    resizing = false
                    saved.scale = scale.Scale
                    save()
                end
            end)
        end
    end)

    conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
        if not isMove(input) then
            return
        end
        if dragging and dragStart then
            local d = input.Position - dragStart
            if d.Magnitude > 6 then
                moved = true
            end
            if moved and Config.LogoDraggable then
                logo.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + d.X,
                    startPos.Y.Scale, startPos.Y.Offset + d.Y
                )
            end
        elseif resizing and rStart then
            local d = input.Position - rStart
            local ratio = 1 + ((d.X / rW) + (d.Y / rH)) / 2
            scale.Scale = math.clamp(rScale * ratio, Config.MinScale, Config.MaxScale)
        end
    end)

    env.ArceusTweakerCleanup = function()
        for _, c in ipairs(conns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        for inst, wasVisible in pairs(hidden) do
            pcall(function()
                inst.Visible = wasVisible
            end)
        end
        if gui then
            pcall(function()
                gui:Destroy()
            end)
        end
    end

    say("ready. Tap the logo to open/close, drag it to move it.")
end

task.spawn(function()
    local ok, err = pcall(main)
    if not ok then
        bad("error: " .. tostring(err))
    end
end)
