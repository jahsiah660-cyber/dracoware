local createApplication = (function()
return function(host, options)
    options = options or {}
    host = host or getfenv()
    local shared = {}
    local lifecycle = {alive = true, suspended = false, connections = {}, instances = {}, threads = {}, errors = {}, engine = nil}
    local controller = {}
    local globals

    local function readCell(cell) return cell[6][cell[3]] end
    local function writeCell(cell, value) cell[6][cell[3]] = value end
    local function cell(value)
        local result = {[3] = 5, [5] = value}
        result[6] = result
        return result
    end
    local function captureValue(frame, index) return {[6] = frame, [3] = index} end
    local function captureShared(cells, frame, index)
        local capture = cells[index]
        if not capture then capture = captureValue(frame, index); cells[index] = capture end
        return capture
    end
    local function closeCapture(cells, frame, index)
        local capture = cells[index]
        if capture then capture[5] = frame[index]; capture[6] = capture; capture[3] = 5; cells[index] = nil end
    end
    local function closeCaptures(cells, frame)
        for index in pairs(cells) do closeCapture(cells, frame, index) end
    end
    local function iterateValues(iterator, state, index)
        local co = coroutine.wrap(function(f, s, k)
            coroutine.yield()
            for key, value in f, s, k do coroutine.yield(true, key, value) end
        end)
        co(iterator, state, index)
        return co
    end

    local players = assert(host.game, "Run in the compatible Roblox client, not a plain Lua process"):GetService("Players")
    local localPlayer = assert(players.LocalPlayer, "A local client player is required")
    local publicEnvironment = host._G
    if type(host.getgenv) == "function" then
        local ok, environment = pcall(host.getgenv)
        if ok and type(environment) == "table" then publicEnvironment = environment end
    end
    local existingBot = type(publicEnvironment) == "table" and rawget(publicEnvironment, "FANAKA")
    assert(type(existingBot) ~= "table" or type(rawget(existingBot, "select")) ~= "function",
        "Another Fanaka session is already present. Use a fresh client session; this script will not disconnect another bot's callbacks")
    local world = host.workspace or host.game:GetService("Workspace")
    assert(world:FindFirstChild("Characters"), "This place has no Workspace.Characters; no fake game objects were created")
    assert(localPlayer.Name ~= "tgodjk", "The recovered constructor excludes this player name")
    local originalHumanoids = {}
    local function rememberCharacter(character)
        if not character then return end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid and originalHumanoids[humanoid] == nil then
            originalHumanoids[humanoid] = {autoRotate = humanoid.AutoRotate}
        end
    end
    rememberCharacter(localPlayer.Character)

    function lifecycle.attachEngine(enabledCell, teleportHeldCell, debugState, humanization, settingsCell, queueState)
        lifecycle.engine = {enabled = enabledCell, teleportHeld = teleportHeldCell,
            debug = debugState, humanization = humanization, settings = settingsCell, queueState = queueState}
    end
    local function restoreMovement()
        for humanoid, saved in pairs(originalHumanoids) do
            pcall(function()
                humanoid.AutoRotate = saved.autoRotate
                humanoid:Move(host.Vector3.new(0, 0, 0), false)
                local character = humanoid.Parent
                local root = character and (character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso"))
                if root then humanoid:MoveTo(root.Position) end
            end)
        end
    end
    function controller:setEnabled(enabled)
        assert(type(enabled) == "boolean", "enabled must be a boolean")
        if not lifecycle.alive then return false end
        local engine = lifecycle.engine
        if not engine then return false end
        writeCell(engine.enabled, enabled)
        lifecycle.suspended = not enabled
        if not enabled then writeCell(engine.teleportHeld, false); restoreMovement() end
        return true
    end
    function controller:isEnabled()
        return lifecycle.alive and lifecycle.engine ~= nil and readCell(lifecycle.engine.enabled) == true
    end
    function controller:getSettings() return shared.FANAKA_CONFIG end
    function controller:getDebugState() return lifecycle.engine and lifecycle.engine.debug or shared.FANAKA_DEBUG end
    function controller:getRegistry() return shared.FANAKA end
    function controller:getInterface() return shared.FANAKA_UI end
    function controller:getErrors() return table.clone(lifecycle.errors) end
    function controller:isAlive() return lifecycle.alive end
    function controller:resourceCounts()
        local connected, parented = 0, 0
        for _, connection in ipairs(lifecycle.connections) do
            if connection.Connected then connected += 1 end
        end
        for _, instance in ipairs(lifecycle.instances) do
            local ok, parent = pcall(function() return instance.Parent end)
            if ok and parent ~= nil then parented += 1 end
        end
        return {connections = connected, parentedInstances = parented, createdInstances = #lifecycle.instances}
    end
    function controller:destroy()
        if not lifecycle.alive then return end
        controller:setEnabled(false)
        lifecycle.alive = false
        for _, connection in ipairs(lifecycle.connections) do pcall(function() connection:Disconnect() end) end
        local current = coroutine.running()
        for thread in pairs(lifecycle.threads) do
            if thread ~= current and host.task and host.task.cancel then pcall(host.task.cancel, thread) end
        end
        for index = #lifecycle.instances, 1, -1 do
            pcall(function() lifecycle.instances[index]:Destroy() end)
        end
        shared.FANAKA_UI = nil
        if options.onDestroy then options.onDestroy(controller) end
    end
    local function recordError(message)
        if #lifecycle.errors < 32 then lifecycle.errors[#lifecycle.errors + 1] = message end
        controller:setEnabled(false)
        if host.warn then host.warn("[Fanaka reconstructed] paused after callback error: " .. message) end
        return message
    end
    function lifecycle.connect(signal, callback)
        assert(lifecycle.alive, "Application has been unloaded")
        local connection = signal:Connect(function(...)
            if not lifecycle.alive then return end
            rememberCharacter(localPlayer.Character)
            local thread = coroutine.running()
            lifecycle.threads[thread] = true
            local arguments = table.pack(...)
            local outcome = table.pack(xpcall(function()
                return callback(table.unpack(arguments, 1, arguments.n))
            end, function(err)
                local trace = host.debug and host.debug.traceback
                return recordError(tostring(err) .. (trace and ("\n" .. trace()) or ""))
            end))
            lifecycle.threads[thread] = nil
            if outcome[1] then return table.unpack(outcome, 2, outcome.n) end
        end)
        lifecycle.connections[#lifecycle.connections + 1] = connection
        return connection
    end
    function lifecycle.connectEngine(signal, callback)
        return lifecycle.connect(signal, function(...)
            if lifecycle.suspended then
                if not controller:isEnabled() then return end
                lifecycle.suspended = false
            end
            return callback(...)
        end)
    end
    local instanceAPI = setmetatable({new = function(className, parent)
        assert(lifecycle.alive, "Application has been unloaded")
        local object = host.Instance.new(className)
        lifecycle.instances[#lifecycle.instances + 1] = object
        if parent then object.Parent = parent end
        return object
    end}, {__index = host.Instance})
    local taskAPI = host.task and setmetatable({}, {__index = host.task}) or nil
    if taskAPI then
        for _, method in ipairs({"spawn", "defer", "delay"}) do
            if type(host.task[method]) == "function" then
                taskAPI[method] = function(...)
                    assert(lifecycle.alive, "Application has been unloaded")
                    local thread = host.task[method](...)
                    if type(thread) == "thread" then lifecycle.threads[thread] = true end
                    return thread
                end
            end
        end
    end
    globals = setmetatable({getgenv = function() return shared end, _G = shared,
        Instance = instanceAPI, task = taskAPI, workspace = world}, {__index = host})
    lifecycle.connect(localPlayer.CharacterAdded, rememberCharacter)

    local Functions = {}

    local Catalog = (function()
return {
    [1] = 13,
    [2] = 60,
    [3] = 90,
    [4] = 2334,
    [5] = 5721,
    [6] = "Arena",
    [7] = 0.15,
    [8] = 180,
    [9] = "4",
    [10] = "Left",
    [11] = "ON",
    [12] = "Bots",
    [13] = 20,
    [14] = 3,
    [15] = "either",
    [16] = 2922,
    [17] = 999,
    [18] = "table",
    [19] = 3.5,
    [20] = 0.5,
    [21] = "Rows",
    [22] = 1018,
    [23] = "Title",
    [24] = "chase",
    [25] = 28,
    [26] = 1.6,
    [27] = "Enabled",
    [28] = "ELO ",
    [29] = 6,
    [30] = "readied",
    [31] = 26,
    [32] = "  ",
    [33] = "bot",
    [34] = "Frame",
    [35] = "tgodjk",
    [36] = 1000,
    [37] = "Time",
    [38] = "grab",
    [39] = 2.2360679775,
    [40] = 0.01,
    [41] = 5758,
    [42] = 2000,
    [43] = 0.001,
    [44] = 18,
    [45] = 230,
    [46] = 10,
    [47] = 36,
    [48] = 72,
    [49] = 62,
    [50] = "Press",
    [51] = 2.2,
    [52] = 1485,
    [53] = "patient",
    [54] = 2.5,
    [55] = 1461,
    [56] = "TextButton",
    [57] = 118,
    [58] = 0.3,
    [59] = "UIPadding",
    [60] = 88,
    [61] = 5.03553390593,
    [62] = 220,
    [63] = "ready",
    [64] = 100,
    [65] = 1001,
    [66] = "NumberValue",
    [67] = 120,
    [68] = 24,
    [69] = 56,
    [70] = "Default style",
    [71] = 80,
    [72] = 240,
    [73] = 3.7,
    [74] = "restart",
    [75] = "idle",
    [76] = "right",
    [77] = "Opening",
    [78] = "Mode",
    [79] = 524,
    [80] = 255,
    [81] = "CoreGui",
    [82] = 0.1,
    [83] = 150,
    [84] = 182,
    [85] = 0.3839724354387525,
    [86] = false,
    [87] = "CFrame",
    [88] = 54,
    [89] = 16,
    [90] = "number",
    [91] = "Slot",
    [92] = "IntValue",
    [93] = 4.5,
    [94] = 1523,
    [95] = "second",
    [96] = 0.2792526803190927,
    [97] = "orbit",
    [98] = "BasePart",
    [99] = "Randomise per new player",
    [100] = 0.95,
    [101] = 15316,
    [102] = 4.03553390593,
    [103] = "start",
    [104] = 34,
    [105] = "Configurables",
    [106] = "6",
    [107] = 7,
    [108] = "Torso",
    [109] = 0.05,
    [110] = "Dracoware Bot v1.6",
    [111] = 1.25,
    [112] = 5,
    [113] = "TextLabel",
    [114] = 0.55,
    [115] = 4,
    [116] = 0.18,
    [117] = "loseLoseRaw",
    [118] = 148,
    [119] = "retry",
    [120] = 440,
    [121] = 1.5,
    [122] = "around",
    [123] = "master",
    [124] = 9,
    [125] = 2,
    [126] = "wiggleoff",
    [127] = 1.1,
    [128] = "Receiving",
    [129] = 0,
    [130] = 30,
    [131] = "Debris",
    [132] = "UI_Back",
    [133] = "Headshot",
    [134] = 337.5,
    [135] = 1,
    [136] = 22,
    [137] = "Bomb time when tagged",
    [138] = 1.2,
    [139] = 0.85,
    [140] = "maximum",
    [141] = 0.4,
    [142] = "OFF",
    [143] = 1908,
    [144] = "none",
    [145] = 170,
    [146] = 4.2,
    [147] = "Bomb time at tag",
    [148] = "UIListLayout",
    [149] = "function",
    [150] = 202,
    [151] = "Credits",
    [152] = "Time until they reach us",
    [153] = 0.8,
    [154] = 2167,
    [155] = "Data",
    [156] = "charge",
    [157] = "run",
    [158] = 11,
    [159] = 78,
    [160] = 235,
    [161] = "LastTick",
    [162] = "Right",
    [163] = 0.75,
    [164] = 52,
    [165] = 14,
    [166] = "UserInputService",
    [167] = "Statsboard",
    [168] = "ScreenGui",
    [169] = "Part",
    [170] = "Aggression",
    [171] = "Main",
    [172] = 0.45,
    [173] = 0.7,
    [174] = 70,
    [175] = 25,
    [176] = "aggressive",
    [177] = 40,
    [178] = 8,
    [179] = 6.283185307179586,
    [180] = 2336,
    [181] = true,
    [182] = "Humanoid",
    [183] = 12,
    [184] = "auto",
    [185] = 122,
    [186] = "TabBar",
    [187] = "ScrollingFrame",
    [188] = 0.2,
    [189] = 15,
    [190] = "LastPing",
    [191] = 0.08,
    [192] = 250,
    [193] = "aggroRaw",
    [194] = "FanakaBotUI",
    [195] = "PingHolder",
    [196] = 9999999,
    [197] = "onslot",
    [198] = 4055,
    [199] = 4908,
    [200] = 0.25,
}

    end)()
    table.freeze(Catalog)

Functions.helper_142 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value20, value21

        tmp_X = {...}
        value20, value21 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value1 = value20.stats[value21]
        value3 = (value1.kills + value1.deaths)
        if (not (value3 == 0)) then
            value1 = (value1.deaths / value3)
            return value1
        end
        return -1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_146 = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, loopExit_19, loopExit_80, value2, value3, value4, value5, value6, value7, value9, value10, value11, value13, value14, value15

        tmp_X = {...}
        value2, value3, value4, value5 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        if (not ((# value3) < 2)) then
            R[19] = value13
            R[19] = Functions.helper_1001({slot1 = value2}, globals)
            value9 = Functions.helper_797({slot1 = value3, slot2 = value4, slot3 = captureShared(cells, R, 19), slot4 = value2}, globals)
            value6 = value2.streak
            if (not value6) then
                value6 = 0
            end
            value6 = (value6 + 1)
            value2.streak = value6
            value5 = globals.ipairs
            value6 = value3
            value5, value6, value7 = value5(value6)
            loop = {parent = loop, iterator = iterateValues(value5, value6, value7)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value6, value7 = tmp_key, tmp_value
                end
                if loopContinues then
                    value10 = value2.stats[value7]
                    if (value10.kills < 1) then
                        loopExit_19 = 30
                        break
                    else
                        value10 = value10.deaths
                        if (value10 < (1)) then
                            loopExit_19 = 34
                            break
                        else
                            continue
                        end
                    end
                else
                    loopExit_19 = 21
                    break
                end
            end
            if (loopExit_19 == 21) then
                loop = loop.parent
                value5 = value2.streak
                value6 = 3
                if (value6 <= value5) then
                    value9()
                else
                    value5 = globals.ipairs
                    value6 = value3
                    value5, value6, value7 = value5(value6)
                    value9 = value5
                    value10 = value6
                    value11 = value7
                    value5 = 0
                    loop = {parent = loop, iterator = iterateValues(value9, value10, value11)}
                    while true do
                        loopContinues, tmp_key, tmp_value = loop.iterator()
                        if loopContinues then
                            value10, value11 = tmp_key, tmp_value
                        end
                        if loopContinues then
                            value5 = (value5 + (value2.stats[value11].kills / value2.stats[value11].deaths))
                            continue
                        else
                            break
                        end
                    end
                    loop = loop.parent
                    value9 = value3[(# value3)]
                    if (0 < value5) then
                        value10 = ((globals.math.random()) * value5)
                        value5 = globals.ipairs
                        value6 = value3
                        value5, value6, value7 = value5(value6)
                        value13 = value5
                        value14 = value6
                        value15 = value7
                        loop = {parent = loop, iterator = iterateValues(value13, value14, value15)}
                        while true do
                            loopContinues, tmp_key, tmp_value = loop.iterator()
                            if loopContinues then
                                value14, value15 = tmp_key, tmp_value
                            end
                            if loopContinues then
                                value5 = (value2.stats[value15].kills / value2.stats[value15].deaths)
                                if (value10 < value5) then
                                    loopExit_80 = 93
                                    break
                                else
                                    value10 = (value10 - value5)
                                    continue
                                end
                            else
                                loopExit_80 = 82
                                break
                            end
                        end
                        if (loopExit_80 == 82) then
        
                        elseif (loopExit_80 == 93) then
                            value9 = value15
                        end
                        loop = loop.parent
                    end
                    if (value9 ~= value2.style) then
                        value2.streak = 0
                    end
                    value2.style = value9
                end
            elseif (loopExit_19 == 30) then
                value9()
            elseif (loopExit_19 == 34) then
                value9()
            end
        end
        closeCaptures(cells, R)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_150 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value5, value6

        tmp_X = captures.authAliveCell
        value5 = (not (readCell(tmp_X)))
        if (not value5) then
            value6 = captures.slot2
            value5 = value6.GetNetworkPing(value6)
            tmp_X = captures.slot3
            writeCell(tmp_X, value5)
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.resetAutoQueue = function(captures, globals)
    local function recovered(...)
        local value4, value6, value9, value10, value11, value13, value19

        value4 = captures.slot1
        value6 = captures.slot1
        value9 = captures.slot1
        value11 = captures.slot1
        captures.slot1.state = "start"
        value4.arena = value13
        value6.side = value19
        value9.slot = value10
        value11.attempts = 0
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_167 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value7, value8, value25, value26, value27, value28, value30

        tmp_X = {...}
        value30 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value25 = readCell(tmp_X)
        value1 = {}
        value3 = (value30 .. "Tab")
        value1.Name = value3
        value26 = globals.UDim2.fromOffset
        value27 = 84
        value28 = 26
        value26 = value26(value27, value28)
        value1.Size = value26
        value3 = captures.slot2.panel2
        value1.BackgroundColor3 = value3
        value1.Text = value30
        value3 = globals.Enum.Font.GothamMedium
        value1.Font = value3
        value3 = captures.slot2.subtext
        value1.TextColor3 = value3
        value1.TextSize = 12
        value1.AutoButtonColor = true
        value1.BorderSizePixel = 0
        value26 = "TextButton"
        value28 = captures.slot3
        value27 = value1
        value25 = value25(value26, value27, value28)
        tmp_X = captures.slot4
        readCell(tmp_X)(value25, 6)
        tmp_X = captures.slot1
        value7 = readCell(tmp_X)
        value8 = {}
        value2 = (value30 .. "Page")
        value8.Name = value2
        value1 = globals.UDim2.new
        value2 = 1
        value3 = 0
        value4 = 1
        value5 = 0
        value1 = value1(value2, value3, value4, value5)
        value8.Size = value1
        value8.BackgroundTransparency = 1
        value2 = false
        value8.Visible = value2
        value2 = "Frame"
        value4 = captures.slot6
        value1 = value7
        value3 = value8
        value1 = value1(value2, value3, value4)
        tmp_X = captures.slot7
        value2 = readCell(tmp_X)
        value2(value1, (12))
        captures.slot8[value30] = value25
        captures.slot9[value30] = value1
        value28 = value25.MouseButton1Click
        lifecycle.connect(value28, (Functions.handleTabClick({authReadyCell = captures.authReadyCell, slot2 = captures.slot11, slot3 = value30}, globals)))
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_173 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value34

        tmp_X = {...}
        value34 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value1 = readCell(tmp_X)()
        if value1 then
            value2 = ((globals.type(value1.brains)) == "table")
            if value2 then
                value2 = (value1.brains[value34] ~= nil)
                if (not value2) then
                    value2 = false
                end
            else
                value2 = false
            end
        else
            value2 = false
        end
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.updateKevin = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local loop, loopContinues, tmp_D, tmp_I, tmp_X, tmp_cache_r, tmp_key, tmp_n, tmp_value, loopExit_1209, value1, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value12, value13, value14, value15, value16, value17, value18, value19, value20, value21, value22, value23, value24, value25, value26, value27, value28, value29, value30, value31, value32, value33, value34, value35, value36, value37, value38, value39, value40, value41, value44, value47, value48, value52, value55, value60, value61
        local sharedPath_160, sharedPath_268, sharedPath_644, sharedPath_1124, sharedPath_1520, sharedPath_1573, sharedPath_1634, sharedPath_1910

        sharedPath_160 = function(...)
            value1 = captures.queueState.pendingBake
            if value1 then
                tmp_X = captures.authAliveCell
                value2 = (not (readCell(tmp_X)))
                if (not value2) then
                    value3 = value30.Torso.Position
                    value4 = (value3 - captures.queueState.bakeLastPos).Magnitude
                    if (value4 < captures.queueState.BAKE_STABLE_EPS) then
                        value4 = captures.queueState.bakeStableSince
                        if (value4 == 0) then
                            value4 = captures.queueState
                            value6 = globals.tick()
                            value4.bakeStableSince = value6
                        end
                    else
                        value4 = captures.queueState
                        value6 = 0
                        value4.bakeStableSince = value6
                    end
                    captures.queueState.bakeLastPos = value3
                    value3 = ((value3 - captures.queueState.bakeEntryPos).Magnitude > captures.queueState.BAKE_MOVE_MIN)
                    value4 = (captures.queueState.bakeStableSince ~= 0)
                    if value4 then
                        value4 = (((globals.tick()) - captures.queueState.bakeStableSince) >= captures.queueState.BAKE_STABLE_WIN)
                    end
                    if value3 then
                        if value4 then
                            if (((globals.tick()) - captures.queueState.bakeEnter) >= captures.queueState.BAKE_MIN_WAIT) then
                                value3 = true
                                tmp_X = captures.respawnPendingCell
                                writeCell(tmp_X, value3)
                                captures.queueState.pendingBake = false
                            else
                                if (((globals.tick()) - captures.queueState.bakeEnter) > captures.queueState.BAKE_MAX_WAIT) then
                                    value3 = true
                                    tmp_X = captures.respawnPendingCell
                                    writeCell(tmp_X, value3)
                                    captures.queueState.pendingBake = false
                                end
                            end
                        else
                            if (((globals.tick()) - captures.queueState.bakeEnter) > captures.queueState.BAKE_MAX_WAIT) then
                                value3 = true
                                tmp_X = captures.respawnPendingCell
                                writeCell(tmp_X, value3)
                                captures.queueState.pendingBake = false
                            end
                        end
                    else
                        if (((globals.tick()) - captures.queueState.bakeEnter) > captures.queueState.BAKE_MAX_WAIT) then
                            value3 = true
                            tmp_X = captures.respawnPendingCell
                            writeCell(tmp_X, value3)
                            captures.queueState.pendingBake = false
                        end
                    end
                    value1 = captures.debugState
                    tmp_X = captures.settingsCell
                    value3 = readCell(tmp_X).autoQueue
                    if value3 then
                        value3 = "in-game"
                    else
                        value3 = "-"
                    end
                    value1.autoQueueState = value3
                    value1 = value30.Torso.Position
                    tmp_X = captures.teleportHeldCell
                    value2 = (not (readCell(tmp_X)))
                    if value2 then
                        value2 = captures.respawnState.lastPos
                        if value2 then
                            value2 = ((value1 - captures.respawnState.lastPos).Magnitude > captures.respawnState.JUMP)
                            if value2 then
                                value2 = captures.respawnState
                                value4 = captures.respawnState
                                value6 = captures.respawnState
                                value8 = captures.respawnState
                                value12 = globals.tick()
                                value2.pending = true
                                value4.jumpAt = value12
                                value6.settlePos = value1
                                value8.settleSince = 0
                            end
                        end
                        value2 = captures.respawnState.pending
                        if value2 then
                            value2 = (((globals.tick()) - captures.respawnState.jumpAt) >= captures.respawnState.MINWAIT)
                            if value2 then
                                value2 = (value1 - captures.respawnState.settlePos).Magnitude
                                if (captures.respawnState.EPS < value2) then
                                    value4 = captures.respawnState
                                    captures.respawnState.settlePos = value1
                                    value4.settleSince = 0
                                else
                                    value2 = captures.respawnState.settleSince
                                    if (value2 == (0)) then
                                        value2 = captures.respawnState
                                        value4 = globals.tick()
                                        value2.settleSince = value4
                                    end
                                    value2 = ((globals.tick()) - captures.respawnState.settleSince)
                                    if (captures.respawnState.WIN <= value2) then
                                        tmp_X = captures.respawnPendingCell
                                        writeCell(tmp_X, true)
                                        captures.respawnState.pending = false
                                    end
                                end
                            end
                        end
                    end
                    captures.respawnState.lastPos = value1
                    value1 = captures.opening.USE
                    if value1 then
                        value1 = (captures.opening.prevChar ~= value30)
                        if value1 then
                            value1 = captures.opening.prevChar
                            if (value1 ~= nil) then
                                if (not captures.opening.resolved) then
                                    if captures.opening.targetName then
                                        if captures.opening.style then
                                            value26 = captures.opening.recordOutcome
                                            value27 = captures.opening.targetName
                                            value28 = captures.opening.style
                                            value29 = true
                                            value26(value27, value28, value29)
                                        end
                                    end
                                end
                                value1 = captures.opening
                                value3 = true
                                value1.armed = value3
                                value1 = captures.opening
                                value3 = globals.tick()
                                value1.roundStart = value3
                                captures.opening.style = nil
                                captures.opening.targetName = nil
                                captures.opening.cornerTarget = nil
                                captures.opening.moveStart = nil
                                value1 = captures.opening
                                value3 = false
                                value1.resolved = value3
                            end
                            captures.opening.prevChar = value30
                        end
                    end
                    return sharedPath_268(...)
                end
            else
                value1 = captures.debugState
                tmp_X = captures.settingsCell
                value3 = readCell(tmp_X).autoQueue
                if value3 then
                    value3 = "in-game"
                else
                    value3 = "-"
                end
                value1.autoQueueState = value3
                value1 = value30.Torso.Position
                tmp_X = captures.teleportHeldCell
                value2 = (not (readCell(tmp_X)))
                if value2 then
                    value2 = captures.respawnState.lastPos
                    if value2 then
                        value2 = ((value1 - captures.respawnState.lastPos).Magnitude > captures.respawnState.JUMP)
                        if value2 then
                            value2 = captures.respawnState
                            value4 = captures.respawnState
                            value6 = captures.respawnState
                            value8 = captures.respawnState
                            value12 = globals.tick()
                            value2.pending = true
                            value4.jumpAt = value12
                            value6.settlePos = value1
                            value8.settleSince = 0
                        end
                    end
                    value2 = captures.respawnState.pending
                    if value2 then
                        value2 = (((globals.tick()) - captures.respawnState.jumpAt) >= captures.respawnState.MINWAIT)
                        if value2 then
                            value2 = (value1 - captures.respawnState.settlePos).Magnitude
                            if (captures.respawnState.EPS < value2) then
                                value4 = captures.respawnState
                                captures.respawnState.settlePos = value1
                                value4.settleSince = 0
                            else
                                value2 = captures.respawnState.settleSince
                                if (value2 == (0)) then
                                    value2 = captures.respawnState
                                    value4 = globals.tick()
                                    value2.settleSince = value4
                                end
                                value2 = ((globals.tick()) - captures.respawnState.settleSince)
                                if (captures.respawnState.WIN <= value2) then
                                    tmp_X = captures.respawnPendingCell
                                    writeCell(tmp_X, true)
                                    captures.respawnState.pending = false
                                end
                            end
                        end
                    end
                end
                captures.respawnState.lastPos = value1
                value1 = captures.opening.USE
                if value1 then
                    value1 = (captures.opening.prevChar ~= value30)
                    if value1 then
                        value1 = captures.opening.prevChar
                        if (value1 ~= nil) then
                            if (not captures.opening.resolved) then
                                if captures.opening.targetName then
                                    if captures.opening.style then
                                        value26 = captures.opening.recordOutcome
                                        value27 = captures.opening.targetName
                                        value28 = captures.opening.style
                                        value29 = true
                                        value26(value27, value28, value29)
                                    end
                                end
                            end
                            value1 = captures.opening
                            value3 = true
                            value1.armed = value3
                            value1 = captures.opening
                            value3 = globals.tick()
                            value1.roundStart = value3
                            captures.opening.style = nil
                            captures.opening.targetName = nil
                            captures.opening.cornerTarget = nil
                            captures.opening.moveStart = nil
                            value1 = captures.opening
                            value3 = false
                            value1.resolved = value3
                        end
                        captures.opening.prevChar = value30
                    end
                end
                return sharedPath_268(...)
            end
            closeCaptures(cells, R)
            return
        end

        sharedPath_268 = function(...)
            value1 = captures.opponentStats.prevChar
            if (value1 ~= value30) then
                value1 = (captures.opponentStats.prevChar ~= nil)
                if value1 then
                    value1 = (not captures.opponentStats.resolved)
                    if value1 then
                        value1 = captures.opponentStats.opponent
                        if value1 then
                            captures.opponentStats.ensure(captures.opponentStats.opponent)
                            value1 = captures.opponentStats.players[captures.opponentStats.opponent]
                            value3 = (captures.opponentStats.players[captures.opponentStats.opponent].wins + 1)
                            value1.wins = value3
                        end
                    end
                end
                value1 = captures.opponentStats
                value3 = false
                value1.resolved = value3
                captures.opponentStats.opponent = nil
                captures.opponentStats.prevChar = value30
            end
            tmp_X = captures.refreshNavigationCell
            readCell(tmp_X)(value30.Torso.Position)
            value7 = {}
            value1 = globals.pairs
            value29 = captures.characters
            value28 = value29.GetChildren
            tmp_n = table.pack(value28(value29))
            tmp_I = tmp_n.n
            tmp_cache_r = table.pack(value1(table.unpack(tmp_n, 1, tmp_n.n)))
            value1, value2, value3 = rawget(tmp_cache_r, 1), rawget(tmp_cache_r, 2), rawget(tmp_cache_r, 3)
            loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value2, value3 = tmp_key, tmp_value
                end
                if loopContinues then
                    value29 = value3
                    value28 = value29.FindFirstChild
                    value4 = "Torso"
                    value27 = value28
                    value28 = value29
                    value29 = value4
                    value27 = value27(value28, value29)
                    if value27 then
                        value4 = (value3.Torso.Position - value30.Torso.Position).Magnitude
                        tmp_X = captures.isValidOpponentCell
                        value5 = readCell(tmp_X)(value3)
                        if value5 then
                            value5 = globals.table.insert
                            value6 = {}
                            value6.char = value3
                            value6.dist = value4
                            value28 = value3
                            value27 = value28.FindFirstChild
                            value29 = "Bomb"
                            value8 = ((value27(value28, value29)) ~= nil)
                            value6.hasBomb = value8
                            value5(value7, value6)
                        end
                        value27 = value3
                        value26 = value27.FindFirstChild
                        value28 = "Bomb"
                        value26 = value26(value27, value28)
                        if value26 then
                            value26 = value3
                            value25 = value26.FindFirstChild
                            value27 = "Bomb"
                            value25 = value25(value26, value27)
                            value24 = value25
                            value23 = value24.FindFirstChild
                            value4 = "LastTick"
                            value22 = value23
                            value23 = value24
                            value24 = value4
                            if ((value22(value23, value24))) then
                                value24 = value25
                                value23 = value24.FindFirstChild
                                value29 = "LastTick"
                                value27 = value23
                                value28 = value24
                                value27 = value27(value28, value29)
                                value4 = globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)
                                value5 = value27.Value
                                if (value4 ~= value5) then
                                    value29 = value27
                                    value28 = value29.FindFirstChild
                                    value6 = "Time"
                                    value4 = value28
                                    value5 = value29
                                    value4 = value4(value5, value6)
                                    if value4 then
                                        value29 = value27
                                        value28 = value29.FindFirstChild
                                        value6 = "Time"
                                        value4 = value28
                                        value5 = value29
                                        value4 = value4(value5, value6)
                                        value6 = ((globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)) - value10)
                                        value4.Value = value6
                                    else
                                        value4 = globals.Instance.new("NumberValue")
                                        value6 = ((globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)) - value10)
                                        value4.Value = value6
                                        value4.Parent = value27
                                        value4.Name = "Time"
                                    end
                                    value5 = globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)
                                    value27.Value = value5
                                else
                                    value29 = value27
                                    value28 = value29.FindFirstChild
                                    value6 = "Time"
                                    value4 = value28
                                    value5 = value29
                                    if ((value4(value5, value6))) then
                                        value26 = value27.FindFirstChild
                                        value28 = "Time"
                                        value26 = value26(value27, value28)
                                        value5 = (value26.Value - value10)
                                        value26.Value = value5
                                    else
                                        value5 = globals.Instance.new("NumberValue")
                                        value8 = ((globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)) - value10)
                                        value5.Value = value8
                                        value5.Parent = value27
                                        value5.Name = "Time"
                                    end
                                end
                            else
                                value4 = globals.Instance.new("IntValue")
                                value6 = globals.tonumber(value25.BombHandle.UIAttachment.UI.TimeLeft.Text)
                                value4.Value = value6
                                value4.Parent = value25
                                value6 = "LastTick"
                                value4.Name = value6
                            end
                            continue
                        else
                            continue
                        end
                    else
                        continue
                    end
                else
                    break
                end
            end
            loop = loop.parent
            globals.table.sort(value7, (Functions.helper_1073({}, globals)))
            value1 = value7[(1)]
            value26 = nil
            if value1 then
                value26 = value7[1].char
                value1 = value7[1].dist
            end
            if R[42] then
                value1 = (not captures.opponentStats.opponent)
                if value1 then
                    value1 = value26
                    if value1 then
                        value1 = captures.opponentStats
                        value3 = value26.Name
                        value1.opponent = value3
                        captures.opponentStats.ensure(value26.Name)
                    end
                end
            else
                value1 = R[42]
            end
            value44 = value7[2]
            value31 = {}
            value4 = globals.ipairs
            value5 = value7
            value4, value5, value6 = value4(value5)
            loop = {parent = loop, iterator = iterateValues(value4, value5, value6)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value5, value6 = tmp_key, tmp_value
                end
                if loopContinues then
                    if (not value6.hasBomb) then
                        globals.table.insert(value31, value6)
                        continue
                    else
                        continue
                    end
                else
                    break
                end
            end
            loop = loop.parent
            value33 = value31[1]
            if value33 then
                value33 = value31[1].char
                if (not value33) then
                    value33 = value26
                end
            else
                value33 = value26
            end
            value7 = globals.pairs
            value29 = captures.characters
            value28 = value29.GetChildren
            tmp_n = table.pack(value28(value29))
            tmp_I = tmp_n.n
            tmp_D = table.pack(value7(table.unpack(tmp_n, 1, tmp_n.n)))
            value7, value8, value9 = rawget(tmp_D, 1), rawget(tmp_D, 2), rawget(tmp_D, 3)
            value4 = 9999999
            value36 = nil
            value5 = 9999999
            value40 = nil
            loop = {parent = loop, iterator = iterateValues(value7, value8, value9)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value8, value9 = tmp_key, tmp_value
                end
                if loopContinues then
                    value21 = value9
                    value1 = value21.FindFirstChild
                    value22 = "Torso"
                    value20 = value1
                    value1 = (value20(value21, value22))
                    if value1 then
                        value21 = value9
                        value2 = value21.FindFirstChild
                        value22 = "Bomb"
                        value20 = value2
                        value1 = (value20(value21, value22))
                        if value1 then
                            value21 = globals.game.Players
                            value1 = value21.FindFirstChild
                            value22 = value9.Name
                            value20 = value1
                            value1 = (value20(value21, value22))
                            if value1 then
                                value20 = value1
                                value2 = value20.FindFirstChild
                                value21 = "Data"
                                value19 = value2
                                value2 = (value19(value20, value21))
                                if value2 then
                                    value20 = value1.Data
                                    value3 = value20.FindFirstChild
                                    value21 = "ActiveArena"
                                    value19 = value3
                                    value2 = (value19(value20, value21))
                                    if value2 then
                                        value20 = captures.localPlayer
                                        value3 = value20.FindFirstChild
                                        value21 = "Data"
                                        value19 = value3
                                        value2 = (value19(value20, value21))
                                        if value2 then
                                            value20 = captures.localPlayer.Data
                                            value3 = value20.FindFirstChild
                                            value21 = "ActiveArena"
                                            value19 = value3
                                            value2 = (value19(value20, value21))
                                            if value2 then
                                                value2 = (value1.Data.ActiveArena.Value == captures.localPlayer.Data.ActiveArena.Value)
                                                if value2 then
                                                    value2 = (value9.Torso.Position - value30.Torso.Position).Magnitude
                                                    value21 = value9
                                                    value1 = value21.FindFirstChild
                                                    value22 = "TeamHighlight"
                                                    value20 = value1
                                                    if ((value20(value21, value22))) then
                                                        if (not (value2 < value4)) then
                                                            continue
                                                        else
                                                            value4 = value2
                                                            value36 = value9
                                                            continue
                                                        end
                                                    else
                                                        if (value2 < value5) then
                                                            value5 = value2
                                                            value40 = value9
                                                            continue
                                                        else
                                                            continue
                                                        end
                                                    end
                                                else
                                                    continue
                                                end
                                            else
                                                continue
                                            end
                                        else
                                            continue
                                        end
                                    else
                                        continue
                                    end
                                else
                                    continue
                                end
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        continue
                    end
                else
                    break
                end
            end
            loop = loop.parent
            value8 = Functions.helper_1781({slot1 = captures.playersService, catalogCell = captures.catalogCell}, globals)
            R[45] = value8(value30)
            if value26 then
                value1 = value8(value26)
                if (not value1) then
                    value1 = 25
                end
            else
                value1 = 25
            end
            return sharedPath_644(...)
        end

        sharedPath_644 = function(...)
            R[46] = value1
            if value40 then
                value47 = value8(value40)
                if (not value47) then
                    value47 = 25
                end
            else
                value47 = 25
            end
            value4 = {}
            value11 = globals.pairs
            value29 = captures.characters
            value28 = value29.GetChildren
            tmp_n = table.pack(value28(value29))
            tmp_I = tmp_n.n
            tmp_D = table.pack(value11(table.unpack(tmp_n, 1, tmp_n.n)))
            value11, value12, value13 = rawget(tmp_D, 1), rawget(tmp_D, 2), rawget(tmp_D, 3)
            loop = {parent = loop, iterator = iterateValues(value11, value12, value13)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value12, value13 = tmp_key, tmp_value
                end
                if loopContinues then
                    value21 = value13
                    value1 = value21.FindFirstChild
                    value22 = "Bomb"
                    value20 = value1
                    value1 = (value20(value21, value22))
                    if value1 then
                        value21 = value13
                        value2 = value21.FindFirstChild
                        value22 = "Torso"
                        value20 = value2
                        value1 = (value20(value21, value22))
                        if value1 then
                            value1 = true
                            value4[value13] = value1
                            continue
                        else
                            continue
                        end
                    else
                        continue
                    end
                else
                    break
                end
            end
            loop = loop.parent
            value24 = value30
            value23 = value24.FindFirstChild
            value25 = "Bomb"
            value5 = ((value23(value24, value25)) ~= nil)
            tmp_X = captures.jumpPendingCell
            value1 = readCell(tmp_X)
            tmp_X = captures.jumpPendingCell
            value2 = readCell(tmp_X)
            if value1 then
                value2 = (not value5)
            end
            if value2 then
                value3 = globals.math.huge
                value14 = globals.pairs
                value15 = value4
                value14, value15, value16 = value14(value15)
                value6 = nil
                loop = {parent = loop, iterator = iterateValues(value14, value15, value16)}
                while true do
                    loopContinues, tmp_key, tmp_value = loop.iterator()
                    if loopContinues then
                        value15, value16 = tmp_key, tmp_value
                    end
                    if loopContinues then
                        tmp_X = captures.trackedJumpTargetsCell
                        if (not readCell(tmp_X)[value15]) then
                            value21 = value15
                            value1 = value21.FindFirstChild
                            value22 = "Torso"
                            value20 = value1
                            if (((value20(value21, value22)))) then
                                value1 = (value15.Torso.Position - value30.Torso.Position).Magnitude
                                if (not (value1 < value3)) then
                                    continue
                                else
                                    value3 = value1
                                    value6 = value15
                                    continue
                                end
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                tmp_X = captures.hadTargetCell
                value1 = readCell(tmp_X)
                if value1 then
                    if value6 then
                        tmp_X = captures.hadBombCell
                        value1 = (not (readCell(tmp_X)))
                        if value1 then
                            tmp_X = captures.recordKillCell
                            value1 = readCell(tmp_X)
                            tmp_X = captures.previousTargetNameCell
                            value1((readCell(tmp_X)))
                        else
                            tmp_X = captures.hadBombCell
                            value1 = readCell(tmp_X)
                            if value1 then
                                tmp_X = captures.recordWaverOutcomeCell
                                value1 = readCell(tmp_X)
                                tmp_X = captures.previousTargetNameCell
                                value1((readCell(tmp_X)))
                            end
                        end
                    else
                        tmp_X = captures.hadBombCell
                        value1 = readCell(tmp_X)
                        if value1 then
                            tmp_X = captures.recordWaverOutcomeCell
                            value1 = readCell(tmp_X)
                            tmp_X = captures.previousTargetNameCell
                            value1((readCell(tmp_X)))
                        end
                    end
                end
                tmp_X = captures.hadTargetCell
                writeCell(tmp_X, false)
                tmp_X = captures.previousAggressionTargetCell
                value1 = readCell(tmp_X)
                if value1 then
                    tmp_X = captures.recordAggressionOutcomeCell
                    value1 = readCell(tmp_X)
                    tmp_X = captures.previousAggressionTargetCell
                    value1((readCell(tmp_X)), (value6 ~= nil))
                    tmp_X = captures.previousAggressionTargetCell
                    writeCell(tmp_X, nil)
                end
                if (not value6) then
                    value6 = value40
                end
                if value6 then
                    value1 = captures.waverState
                    value2 = ((globals.tick()) + 1.25)
                    value3 = value8(value6)
                    value2 = (value2 + (value3 / (1000)))
                    value1[value6] = value2
                end
                tmp_X = captures.previousBombCell
                writeCell(tmp_X, nil)
                value3 = nil
            else
                tmp_X = captures.jumpPendingCell
                value1 = (not (readCell(tmp_X)))
                if value1 then
                    value1 = value5
                    value3 = nil
                    if value1 then
                        if captures.humanization.ON then
                            value2 = captures.humanization
                            value7 = ((globals.math.random()) * 2)
                            value7 = ((value7 - (1)) * captures.humanization.TIMING)
                            value2.timingBias = value7
                            value2 = captures.humanization
                            value7 = ((((globals.math.random()) * 2) - 1) * captures.humanization.WAVER)
                            value2.waverJitter = value7
                        end
                        value6 = globals.math.huge
                        value17 = globals.pairs
                        tmp_X = captures.trackedJumpTargetsCell
                        value18 = readCell(tmp_X)
                        value17, value18, value19 = value17(value18)
                        value3 = nil
                        loop = {parent = loop, iterator = iterateValues(value17, value18, value19)}
                        while true do
                            loopContinues, tmp_key, tmp_value = loop.iterator()
                            if loopContinues then
                                value18, value19 = tmp_key, tmp_value
                            end
                            if loopContinues then
                                if (not value4[value18]) then
                                    value21 = value18
                                    value1 = value21.FindFirstChild
                                    value22 = "Torso"
                                    value20 = value1
                                    if (((value20(value21, value22)))) then
                                        value1 = (value18.Torso.Position - value30.Torso.Position).Magnitude
                                        if (value1 < value6) then
                                            value6 = value1
                                            value3 = value18
                                            continue
                                        else
                                            continue
                                        end
                                    else
                                        continue
                                    end
                                else
                                    continue
                                end
                            else
                                break
                            end
                        end
                        loop = loop.parent
                        if value3 then
                            value26 = value3
                            tmp_X = captures.previousBombCell
                            writeCell(tmp_X, value26)
                            if value3 then
                                value21 = value3
                                value1 = value21.FindFirstChild
                                value22 = "Torso"
                                value20 = value1
                                if ((value20(value21, value22))) then
                                    value1 = 5758
                                    tmp_X = captures.recordReachCell
                                    value1 = readCell(tmp_X)
                                    value2 = value3.Name
                                    tmp_X = captures.horizontalVectorCell
                                    value6 = readCell(tmp_X)(value3.Torso.Position)
                                    tmp_X = captures.horizontalVectorCell
                                    value1(value2, (value6 - (readCell(tmp_X)(value30.Torso.Position))).Magnitude)
                                end
                            else
            
                            end
                        else
                            tmp_X = captures.previousBombCell
                            writeCell(tmp_X, value26)
                        end
                    end
                else
                    value3 = nil
                end
            end
            value1 = captures.encounter.engaged
            if value1 then
                value1 = (not captures.encounter.resolved)
                if value1 then
                    value1 = captures.encounter.victimChar
                    if value1 then
                        value1 = captures.encounter.phase
                        value2 = "bot"
                        if (value1 == value2) then
                            tmp_X = captures.jumpPendingCell
                            value1 = readCell(tmp_X)
                            tmp_X = captures.jumpPendingCell
                            value2 = readCell(tmp_X)
                            if value1 then
                                value2 = (not value5)
                            end
                            if value2 then
                                tmp_X = captures.recordEncounterOutcomeCell
                                value26 = readCell(tmp_X)
                                value27 = captures.encounter.victimName
                                value28 = captures.encounter.style
                                value29 = true
                                value26(value27, value28, value29)
                                captures.encounter.resolved = true
                                captures.encounter.engaged = false
                            end
                        else
                            if (value3 == captures.encounter.victimChar) then
                                captures.encounter.phase = "bot"
                            else
                                tmp_X = captures.trackedJumpTargetsCell
                                if (readCell(tmp_X))[captures.encounter.victimChar] then
                                    if (not value4[captures.encounter.victimChar]) then
                                        tmp_X = captures.recordEncounterOutcomeCell
                                        value26 = readCell(tmp_X)
                                        value27 = captures.encounter.victimName
                                        value28 = captures.encounter.style
                                        value29 = true
                                        value26(value27, value28, value29)
                                        captures.encounter.resolved = true
                                        captures.encounter.engaged = false
                                    end
                                end
                            end
                        end
                    end
                end
            end
            tmp_X = captures.trackedJumpTargetsCell
            writeCell(tmp_X, value4)
            tmp_X = captures.jumpPendingCell
            writeCell(tmp_X, value5)
            value23 = value30
            value22 = value23.FindFirstChild
            value24 = "Bomb"
            if ((value22(value23, value24))) then
                tmp_X = captures.localHasBombCell
                value1 = readCell(tmp_X)
                if (value1 == false) then
                    tmp_X = captures.localHasBombCell
                    writeCell(tmp_X, true)
                    value1 = ((1.25 + (R[45] / 1000)) - value10)
                    tmp_X = captures.bombHoldDelayCell
                    writeCell(tmp_X, value1)
                else
                    tmp_X = captures.bombHoldDelayCell
                    value1 = ((readCell(tmp_X)) - value10)
                    tmp_X = captures.bombHoldDelayCell
                    writeCell(tmp_X, value1)
                    tmp_X = captures.bombHoldDelayCell
                    if ((readCell(tmp_X)) <= 0) then
                        tmp_X = captures.bombHoldDelayCell
                        writeCell(tmp_X, 0)
                    end
                end
            else
                tmp_X = captures.localHasBombCell
                value1 = readCell(tmp_X)
                if (value1 == true) then
                    tmp_X = captures.localHasBombCell
                    writeCell(tmp_X, false)
                    value1 = ((1.25 + (value47 / 1000)) - value10)
                    tmp_X = captures.bombHoldDelayCell
                    writeCell(tmp_X, value1)
                else
                    tmp_X = captures.bombHoldDelayCell
                    value1 = ((readCell(tmp_X)) - value10)
                    tmp_X = captures.bombHoldDelayCell
                    writeCell(tmp_X, value1)
                    tmp_X = captures.bombHoldDelayCell
                    if ((readCell(tmp_X)) <= 0) then
                        tmp_X = captures.bombHoldDelayCell
                        writeCell(tmp_X, 0)
                    end
                end
            end
            tmp_X = captures.enabledCell
            value1 = readCell(tmp_X)
            if (value1 == true) then
                value11 = Functions.helper_1837({slot1 = captures.debugState, catalogCell = captures.catalogCell, slot3 = captures.hadBombCell, slot4 = value30, slot5 = captures.humanization, slot6 = captures.startTime, slot7 = captures.navigateCell, slot8 = captures.teleportHeldCell}, globals)
                value12 = Functions.steerAroundTarget({slot1 = captures.debugState, catalogCell = captures.catalogCell, slot3 = captures.hadBombCell, slot4 = captures.hadTargetCell, slot5 = value30, slot6 = captures.horizontalVectorCell, slot7 = captures.chasingCell, slot8 = captures.chaseTargetCell, slot9 = captures.orbitSettings, slot10 = captures.waveringCell, slot11 = captures.humanization, slot12 = captures.chaseCell, slot13 = captures.fleeingCell, numericBCell = captures.numericBCell, sentinelACell = captures.sentinelACell, sentinelBCell = captures.sentinelBCell, authAliveCell = captures.authAliveCell, slot18 = captures.fleeCell, slot19 = captures.navigateCell, slot20 = captures.teleportHeldCell}, globals)
                value48 = Functions.helper_2259({slot1 = captures.debugState, catalogCell = captures.catalogCell, slot3 = captures.roundActiveCell, slot4 = value30, slot5 = captures.lastTargetPositionCell, slot6 = captures.lastTargetVelocityCell, slot7 = captures.smoothedMoveCell, slot8 = captures.lastMoveAtCell, slot9 = captures.avoidanceSettings, slot10 = captures.horizontalVectorCell, slot11 = captures.humanization, sentinelACell = captures.sentinelACell, slot13 = captures.startTime, slot14 = captures.navigateCell, slot15 = captures.teleportHeldCell}, globals)
                value13 = Functions.helper_504({slot1 = captures.debugState, catalogCell = captures.catalogCell, slot3 = captures.roundActiveCell, slot4 = value30, slot5 = captures.raycastParams, authAliveCell = captures.authAliveCell, slot7 = captures.pathfindCell, slot8 = captures.horizontalVectorCell, slot9 = captures.hadContactCell, slot10 = captures.lastContactAtCell, slot11 = captures.localPlayer, slot12 = captures.lastSteeringCell, slot13 = captures.estimateReachCell, slot14 = captures.humanization, slot15 = captures.steeringModeCell}, globals)
                tmp_X = captures.localHasBombCell
                value1 = readCell(tmp_X)
                if (value1 == true) then
                    tmp_X = captures.lockDeadlineCell
                    writeCell(tmp_X, nil)
                    value22 = value30
                    value21 = value22.FindFirstChild
                    value23 = "Bomb"
                    value21 = value21(value22, value23)
                    value20 = value21.FindFirstChild
                    value22 = "LastTick"
                    value20 = value20(value21, value22)
                    value14 = 10
                    if value20 then
                        value21 = value30
                        value20 = value21.FindFirstChild
                        value22 = "Bomb"
                        value20 = value20(value21, value22)
                        value19 = value20.FindFirstChild
                        value21 = "LastTick"
                        value19 = value19(value20, value21)
                        value18 = value19.FindFirstChild
                        value20 = "Time"
                        value18 = value18(value19, value20)
                        value14 = 10
                        if value18 then
                            value20 = value30
                            value19 = value20.FindFirstChild
                            value21 = "Bomb"
                            value19 = value19(value20, value21)
                            value18 = value19.FindFirstChild
                            value20 = "LastTick"
                            value18 = value18(value19, value20)
                            value17 = value18.FindFirstChild
                            value19 = "Time"
                            value14 = (value17(value18, value19)).Value
                        end
                    end
                    return sharedPath_1124(...)
                else
                    tmp_X = captures.lastTagTargetCell
                    writeCell(tmp_X, nil)
                    value1 = (not value40)
                    if value1 then
                        if value36 then
                            value34 = value36
                            value33 = value34.FindFirstChild
                            value35 = "Torso"
                            if ((value33(value34, value35))) then
                                value37 = 999
                                value39 = value36.Torso.Position
                                value38 = 10
                                value35 = value13
                                value35(value36, value37, value38, value39)
                                captures.debugState.navMode = "team-flee"
                            else
                                value1 = value30.Humanoid
                                value3 = true
                                value1.AutoRotate = value3
                            end
                        else
                            value1 = value30.Humanoid
                            value3 = true
                            value1.AutoRotate = value3
                        end
                    else
                        value38 = value40
                        value37 = value38.FindFirstChild
                        value39 = "Bomb"
                        value37 = value37(value38, value39)
                        value36 = value37.FindFirstChild
                        value38 = "LastTick"
                        value36 = value36(value37, value38)
                        value16 = 10
                        if value36 then
                            value37 = value40
                            value36 = value37.FindFirstChild
                            value38 = "Bomb"
                            value36 = value36(value37, value38)
                            value35 = value36.FindFirstChild
                            value37 = "LastTick"
                            value35 = value35(value36, value37)
                            value34 = value35.FindFirstChild
                            value36 = "Time"
                            value34 = value34(value35, value36)
                            value16 = 10
                            if value34 then
                                value36 = value40
                                value35 = value36.FindFirstChild
                                value37 = "Bomb"
                                value35 = value35(value36, value37)
                                value34 = value35.FindFirstChild
                                value36 = "LastTick"
                                value34 = value34(value35, value36)
                                value33 = value34.FindFirstChild
                                value35 = "Time"
                                value16 = (value33(value34, value35)).Value
                            end
                        end
                        tmp_X = captures.queueCell
                        value38 = readCell(tmp_X)(value40)
                        tmp_X = captures.chaseCell
                        value37 = readCell(tmp_X)
                        value19 = value30
                        value18 = value19.FindFirstChild
                        value20 = "Torso"
                        value39 = (value18(value19, value20)).Position
                        value37 = value37(value38, value39)
                        tmp_X = captures.lockStateCell
                        value7 = readCell(tmp_X)
                        value8 = value37
                        value9 = value40
                        value7 = value7(value8, value9, value10)
                        value1 = captures.humanization.ON
                        if value1 then
                            value1 = (captures.humanization.DISTBIAS > 0)
                            if value1 then
                                value4 = globals.math.max
                                value1 = (1 - captures.humanization.DISTBIAS)
                                value2 = globals.math.random()
                                value2 = (value2 - (0.5))
                                value3 = (value7 * (value1 + (value2 * (0.08))))
                                value2 = 0
                                value1 = value4
                                value7 = (value1(value2, value3))
                            end
                        end
                        tmp_X = captures.estimateReachCell
                        value5 = readCell(tmp_X)(value40.Name)
                        value1 = ((value7 - value5) / 2)
                        value2 = 1000
                        value22 = ((value1 - (R[45] / value2)) - (value47 / 1000))
                        tmp_X = captures.teleportHeldCell
                        if ((readCell(tmp_X)) == true) then
                            value22 = 0
                        end
                        value23 = 0
                        value1 = captures.waverState[value40]
                        if value1 then
                            value1 = globals.math.max
                            value25 = (captures.waverState[value40] - (globals.tick()))
                            value24 = 0
                            value23 = value1
                            value23 = value23(value24, value25)
                        end
                        value21 = globals.math.max
                        value21 = value21(value22, value23)
                        value11 = (value16 - value21)
                        value2 = 1000
                        value1 = (1.25 + (R[45] / value2))
                        value12 = (value1 + (value47 / (1000)))
                        value19 = globals.math.max
                        value20 = 0
                        value19 = value19(value20, value21)
                        captures.debugState.mode = "receive"
                        captures.debugState.bombTime = value16
                        captures.debugState.nearestDist = value7
                        captures.debugState.tagTime = value19
                        value1 = captures.debugState
                        value3 = (value16 - value19)
                        value1.contactBombTime = value3
                        value1 = captures.debugState
                        if value44 then
                            value3 = value44.dist
                            if (not value3) then
                                value3 = 0
                            end
                        else
                            value3 = 0
                        end
                        value1.secondDist = value3
                        value1 = captures.debugState
                        if value44 then
                            value44 = value44.hasBomb
                            if (not value44) then
                                value44 = false
                            end
                        else
                            value44 = false
                        end
                        value1.secondHasBomb = value44
                        captures.debugState.victimReach = value5
                        value1 = captures.reachRecords[value40.Name]
                        value2 = captures.debugState
                        if value1 then
                            value1 = value1.n
                            if (not value1) then
                                value1 = 0
                            end
                        else
                            value1 = 0
                        end
                        value2.victimReachN = value1
                        value1 = captures.debugState
                        tmp_X = captures.chooseEncounterCell
                        value3 = readCell(tmp_X)(value40.Name)
                        value1.loseLoseStyle = value3
                        value20 = captures.opening.USE
                        if value20 then
                            value20 = captures.opening.armed
                            if value20 then
                                value20 = (((globals.tick()) - captures.opening.roundStart) < captures.opening.DURATION)
                                if value20 then
                                    value1 = (not captures.opening.style)
                                    if value1 then
                                        value1 = captures.opening
                                        value3 = captures.opening.ensureStyle(value40.Name)
                                        value1.style = value3
                                        value1 = captures.opening
                                        value3 = value40.Name
                                        value1.targetName = value3
                                    end
                                    value1 = captures.debugState
                                    value3 = captures.opening.style
                                    value1.openingStyle = value3
                                end
                            end
                        end
                        return sharedPath_1573(...)
                    end
                end
            else
                value1 = value30.Humanoid
                value1.AutoRotate = true
            end
            closeCaptures(cells, R)
            return
        end

        sharedPath_1124 = function(...)
            value1 = (not value33)
            if value1 then
                value2 = value30.Humanoid
                value2.AutoRotate = true
            else
                value9 = globals.math.huge
                value20 = globals.ipairs
                value21 = value31
                value20, value21, value22 = value20(value21)
                value15 = true
                value16 = nil
                value7 = nil
                loop = {parent = loop, iterator = iterateValues(value20, value21, value22)}
                while true do
                    loopContinues, tmp_key, tmp_value = loop.iterator()
                    if loopContinues then
                        value21, value22 = tmp_key, tmp_value
                    end
                    if loopContinues then
                        if (3 < value21) then
                            loopExit_1209 = 1219
                            break
                        else
                            value2 = value22.char
                            value24 = value2
                            value1 = value24.FindFirstChild
                            value25 = "Torso"
                            value23 = value1
                            if ((value23(value24, value25))) then
                                tmp_X = captures.chaseCell
                                value3 = readCell(tmp_X)
                                value4 = value30.Torso.Position
                                value5 = value2.Torso.Position
                                value3 = value3(value4, value5)
                                value4 = globals.math.max
                                value6 = (value3 - 3.65)
                                value5 = 0
                                value5 = ((value4(value5, value6)) / 2)
                                tmp_X = captures.previousBombCell
                                value1 = (value2 == (readCell(tmp_X)))
                                if value1 then
                                    tmp_X = captures.bombHoldDelayCell
                                    value4 = readCell(tmp_X)
                                    value4 = (value4 > (0))
                                    if value4 then
                                        value4 = globals.math.max
                                        tmp_X = captures.bombHoldDelayCell
                                        value6 = readCell(tmp_X)
                                        value4 = value4(value5, value6)
                                    else
                                        value4 = value5
                                    end
                                else
                                    value4 = value5
                                end
                                if (value4 < (value9 - 0.3)) then
                                    value9 = value4
                                    value15 = value1
                                    value16 = value2
                                    value7 = value3
                                    continue
                                else
                                    value6 = globals.math.abs((value4 - value9))
                                    if (value6 <= (0.3)) then
                                        if value15 then
                                            if (not value1) then
                                                value9 = value4
                                                value15 = value1
                                                value16 = value2
                                                value7 = value3
                                                continue
                                            else
                                                continue
                                            end
                                        else
                                            continue
                                        end
                                    else
                                        continue
                                    end
                                end
                            else
                                continue
                            end
                        end
                    else
                        loopExit_1209 = 1213
                        break
                    end
                end
                if (loopExit_1209 == 1213) then
            
                elseif (loopExit_1209 == 1219) then
            
                end
                loop = loop.parent
                if value16 then
                    value33 = value16
                    value32 = value33
                    value31 = value32.FindFirstChild
                    value3 = "Torso"
                    value1 = value31
                    value2 = value32
                    if (not (value1(value2, value3))) then
                        value1 = value30.Humanoid
                        value1.AutoRotate = true
                    else
                        tmp_X = captures.chooseWaverCell
                        value1 = readCell(tmp_X)(value33.Name)
                        tmp_X = captures.waverStyleCell
                        writeCell(tmp_X, value1)
                        value1 = value33.Name
                        tmp_X = captures.previousTargetNameCell
                        writeCell(tmp_X, value1)
                        tmp_X = captures.waverStyleCell
                        value3 = readCell(tmp_X)
                        captures.debugState.waverStyle = value3
                        tmp_X = captures.chooseAggressionCell
                        value1 = readCell(tmp_X)(value33.Name)
                        tmp_X = captures.aggressionStyleCell
                        writeCell(tmp_X, value1)
                        value1 = value33.Name
                        tmp_X = captures.previousAggressionTargetCell
                        writeCell(tmp_X, value1)
                        tmp_X = captures.aggressionStyleCell
                        value3 = readCell(tmp_X)
                        captures.debugState.aggroStyle = value3
                        R[45] = value8(value30)
                        if (R[45] == 0) then
                            R[45] = 25
                        end
                        R[46] = value8(value33)
                        value1 = (value33 == value16)
                        if value1 then
                            if (not value7) then
                                tmp_X = captures.chaseCell
                                value4 = readCell(tmp_X)
                                value2 = value30.Torso.Position
                                value3 = value33.Torso.Position
                                value1 = value4
                                value7 = (value1(value2, value3))
                            end
                        else
                            tmp_X = captures.chaseCell
                            value4 = readCell(tmp_X)
                            value2 = value30.Torso.Position
                            value3 = value33.Torso.Position
                            value1 = value4
                            value7 = (value1(value2, value3))
                        end
                        tmp_X = captures.tagTransitionCell
                        value6 = readCell(tmp_X)
                        value8 = value33
                        value9 = value10
                        value6 = value6(value7, value8, value9)
                        value1 = globals.math.max
                        value3 = (value6 - 3.65)
                        value2 = 0
                        value2 = ((value1(value2, value3)) / 2)
                        tmp_X = captures.previousBombCell
                        value1 = (value33 == (readCell(tmp_X)))
                        if value1 then
                            tmp_X = captures.bombHoldDelayCell
                            value1 = ((readCell(tmp_X)) > 0)
                            if value1 then
                                value1 = globals.math.max
                                tmp_X = captures.bombHoldDelayCell
                                value3 = readCell(tmp_X)
                                value1 = value1(value2, value3)
                            else
                                value1 = value2
                            end
                        else
                            value1 = value2
                        end
                        value2 = (value14 - value1)
                        captures.debugState.mode = "give"
                        captures.debugState.bombTime = value14
                        captures.debugState.nearestDist = value6
                        captures.debugState.tagTime = value1
                        captures.debugState.contactBombTime = value2
                        value1 = captures.debugState
                        if value44 then
                            value4 = value44.dist
                            if (not value4) then
                                value4 = 0
                            end
                        else
                            value4 = 0
                        end
                        return sharedPath_1520(...)
                    end
                else
                    if value33 then
                        value32 = value33
                        value31 = value32.FindFirstChild
                        value3 = "Torso"
                        value1 = value31
                        value2 = value32
                        if (not (value1(value2, value3))) then
                            value1 = value30.Humanoid
                            value1.AutoRotate = true
                        else
                            tmp_X = captures.chooseWaverCell
                            value1 = readCell(tmp_X)(value33.Name)
                            tmp_X = captures.waverStyleCell
                            writeCell(tmp_X, value1)
                            value1 = value33.Name
                            tmp_X = captures.previousTargetNameCell
                            writeCell(tmp_X, value1)
                            tmp_X = captures.waverStyleCell
                            value3 = readCell(tmp_X)
                            captures.debugState.waverStyle = value3
                            tmp_X = captures.chooseAggressionCell
                            value1 = readCell(tmp_X)(value33.Name)
                            tmp_X = captures.aggressionStyleCell
                            writeCell(tmp_X, value1)
                            value1 = value33.Name
                            tmp_X = captures.previousAggressionTargetCell
                            writeCell(tmp_X, value1)
                            tmp_X = captures.aggressionStyleCell
                            value3 = readCell(tmp_X)
                            captures.debugState.aggroStyle = value3
                            R[45] = value8(value30)
                            if (R[45] == 0) then
                                R[45] = 25
                            end
                            R[46] = value8(value33)
                            value1 = (value33 == value16)
                            if value1 then
                                if (not value7) then
                                    tmp_X = captures.chaseCell
                                    value4 = readCell(tmp_X)
                                    value2 = value30.Torso.Position
                                    value3 = value33.Torso.Position
                                    value1 = value4
                                    value7 = (value1(value2, value3))
                                end
                            else
                                tmp_X = captures.chaseCell
                                value4 = readCell(tmp_X)
                                value2 = value30.Torso.Position
                                value3 = value33.Torso.Position
                                value1 = value4
                                value7 = (value1(value2, value3))
                            end
                            tmp_X = captures.tagTransitionCell
                            value6 = readCell(tmp_X)
                            value8 = value33
                            value9 = value10
                            value6 = value6(value7, value8, value9)
                            value1 = globals.math.max
                            value3 = (value6 - 3.65)
                            value2 = 0
                            value2 = ((value1(value2, value3)) / 2)
                            tmp_X = captures.previousBombCell
                            value1 = (value33 == (readCell(tmp_X)))
                            if value1 then
                                tmp_X = captures.bombHoldDelayCell
                                value1 = ((readCell(tmp_X)) > 0)
                                if value1 then
                                    value1 = globals.math.max
                                    tmp_X = captures.bombHoldDelayCell
                                    value3 = readCell(tmp_X)
                                    value1 = value1(value2, value3)
                                else
                                    value1 = value2
                                end
                            else
                                value1 = value2
                            end
                            value2 = (value14 - value1)
                            captures.debugState.mode = "give"
                            captures.debugState.bombTime = value14
                            captures.debugState.nearestDist = value6
                            captures.debugState.tagTime = value1
                            captures.debugState.contactBombTime = value2
                            value1 = captures.debugState
                            if value44 then
                                value4 = value44.dist
                                if (not value4) then
                                    value4 = 0
                                end
                            else
                                value4 = 0
                            end
                            return sharedPath_1520(...)
                        end
                    else
                        value1 = value30.Humanoid
                        value1.AutoRotate = true
                    end
                end
            end
            closeCaptures(cells, R)
            return
        end

        sharedPath_1520 = function(...)
            value1.secondDist = value4
            value1 = captures.debugState
            if value44 then
                value44 = value44.hasBomb
                if (not value44) then
                    value44 = false
                end
            else
                value44 = false
            end
            value1.secondHasBomb = value44
            value1 = Functions.helper_289({slot1 = captureShared(cells, R, 45), slot2 = captureShared(cells, R, 46), catalogCell = captures.catalogCell, authAliveCell = captures.authAliveCell}, globals)
            value34 = value1(value14)
            if (not value34) then
                value34 = (value14 < 1.25)
                if (not value34) then
                    value34 = (value2 <= 0)
                end
            end
            tmp_X = captures.aggressionStyleCell
            value1 = ((readCell(tmp_X)) == "aggressive")
            if value1 then
                value1 = value14
                if (not value1) then
                    value1 = value2
                end
            else
                value1 = value2
            end
            if captures.humanization.ON then
                value1 = (value1 + captures.humanization.timingBias)
            end
            value2 = (value14 < (1.25))
            if value2 then
                value35 = (value14 < 1.25)
                value32 = value11
                value32(value33, value34, value35)
            else
                value4 = 1000
                value2 = (value1 < (1.2 + (R[45] / value4)))
                if value2 then
                    value35 = (value14 < 1.25)
                    value32 = value11
                    value32(value33, value34, value35)
                else
                    value2 = (1.5 + (R[45] / 1000))
                    value4 = 1000
                    value2 = (value2 + (1.5 + (R[46] / value4)))
                    if (value1 < value2) then
                        value5 = (value14 - ((1.5 + (R[45] / 1000)) / 2))
                        value3 = value12
                        value4 = value33
                        value3(value4, value5, value6)
                    else
                        value3 = 1000
                        value2 = (1.5 + (R[45] / value3))
                        value2 = ((value2 / (2)) + (1.5 + (R[46] / 1000)))
                        value2 = (value2 + (1.5 + (R[45] / 1000)))
                        if (value1 < value2) then
                            value11(value33, value34)
                        else
                            value2 = (((1.5 + (R[45] / 1000)) / 2) + (1.5 + (R[46] / 1000)))
                            value4 = 1000
                            value2 = ((value2 + (1.5 + (R[45] / value4))) + (1.5 + (R[46] / 1000)))
                            if (value1 < value2) then
                                value2 = ((1.5) + (R[45] / 1000))
                                value2 = (value2 / (2))
                                value5 = ((value2 + ((1.5) + (R[46] / 1000))) + (1.5 + (R[45] / 1000)))
                                value3 = value12
                                value4 = value33
                                value3(value4, value5, value6)
                            else
                                value2 = (((1.5) + (R[45] / 1000)) / 2)
                                value4 = 1000
                                value2 = ((value2 + (1.5 + (R[46] / value4))) + (1.5 + (R[45] / 1000)))
                                value2 = ((value2 + ((1.5) + (R[46] / 1000))) + (1.5 + (R[45] / 1000)))
                                if (value1 < value2) then
                                    value11(value33, value34)
                                else
                                    value3 = ((((1.5) + (R[45] / 1000)) / 2) + (1.5 + (R[46] / 1000)))
                                    value5 = 1000
                                    value3 = (value3 + (1.5 + (R[45] / value5)))
                                    value3 = ((value3 + ((1.5) + (R[46] / 1000))) + (1.5 + (R[45] / 1000)))
                                    value4 = 1.5
                                    value5 = 1000
                                    value1 = (value1 < (value3 + (value4 + (R[46] / value5))))
                                    if value1 then
                                        value1 = ((((1.5) + (R[45] / 1000)) / 2) + (1.5 + (R[46] / 1000)))
                                        value4 = 1000
                                        value1 = (value1 + (1.5 + (R[45] / value4)))
                                        value1 = (value1 + ((1.5) + (R[46] / 1000)))
                                        value5 = (value1 + ((1.5) + (R[45] / 1000)))
                                        value3 = value12
                                    else
                                        value3 = ((((1.5) + (R[45] / 1000)) / 2) + (1.5 + (R[46] / 1000)))
                                        value3 = ((value3 + ((1.5) + (R[45] / 1000))) + (1.5 + (R[46] / 1000)))
                                        value5 = (value3 + (1.5 + (R[45] / 1000)))
                                        value3 = value12
                                    end
                                    value4 = value33
                                    value3(value4, value5, value6)
                                end
                            end
                        end
                    end
                end
            end
            return sharedPath_1634(...)
        end

        sharedPath_1573 = function(...)
            value1 = captures.opening.USE
            if value1 then
                value1 = captures.opening.armed
                if value1 then
                    value1 = (captures.opening.style == captures.opening.CORNER)
                    value31 = false
                    if value1 then
                        value1 = (captures.opening.moveStart == nil)
                        if value1 then
                            value31 = false
                            if value20 then
                                value18 = value30
                                value17 = value18.FindFirstChild
                                value19 = "Humanoid"
                                value17 = value17(value18, value19)
                                if value17 then
                                    value1 = value17.WalkSpeed
                                    if (value1 > (0)) then
                                        value1 = captures.opening
                                        value3 = globals.tick()
                                        value1.moveStart = value3
                                        value9 = value40
                                        value8 = value9.FindFirstChild
                                        value3 = "Torso"
                                        value1 = value8
                                        value2 = value9
                                        value1 = value1(value2, value3)
                                        value6 = captures.opening
                                        value4 = captures.opening.pickCorner
                                        value2 = value30.Torso.Position
                                        if value1 then
                                            value1 = value1.Position
                                        end
                                        value3 = value1
                                        value1 = value4
                                        value1 = value1(value2, value3)
                                        value6.cornerTarget = value1
                                    end
                                end
                                value31 = true
                                tmp_X = captures.sentinelBCell
                            end
                        else
                            value31 = (((globals.tick()) - captures.opening.moveStart) < captures.opening.MOVE_TIME)
                        end
                    end
                else
                    value31 = false
                end
            else
                value31 = false
            end
            value1 = globals.math.max
            value3 = (value7 - value5)
            value2 = 0
            value22 = ((value1(value2, value3)) / 1)
            value21 = globals.math.max
            value18 = ((value21(value22, value23)) > (value16 + 0))
            value4 = captures.debugState.loseLoseStyle
            if value40 then
                value8 = value40
                value7 = value8.FindFirstChild
                value9 = "Torso"
                value7 = value7(value8, value9)
            else
                value7 = value40
            end
            value1 = captures.encounter.USE
            if value1 then
                value1 = value7
                value9 = false
                if value1 then
                    tmp_X = captures.horizontalVectorCell
                    value1 = readCell(tmp_X)((value30.Torso.Position - value7.Position))
                    value2 = value1.Magnitude
                    value26 = (value2 > (0.01))
                    if value26 then
                        value26 = value1.Unit
                        if (not value26) then
                            value1 = globals.Vector3.new
                            value27 = 0
                            value28 = 0
                            value29 = 1
                            value26 = value1
                            value26 = value26(value27, value28, value29)
                        end
                    else
                        value1 = globals.Vector3.new
                        value27 = 0
                        value28 = 0
                        value29 = 1
                        value26 = value1
                        value26 = value26(value27, value28, value29)
                    end
                    tmp_X = captures.lastSteeringCell
                    value25 = readCell(tmp_X)
                    value24 = value25.Dot
                    value24 = value24(value25, value26)
                    value7 = value40
                    value6 = value7.FindFirstChild
                    value8 = "Bomb"
                    value6 = value6(value7, value8)
                    if value6 then
                        value2 = value40.Bomb
                        value1 = value2.FindFirstChild
                        value3 = "BombHandle"
                        value6 = (value1(value2, value3))
                        value1 = (not value6)
                        if (not value1) then
                            tmp_X = captures.horizontalVectorCell
                            value1 = ((readCell(tmp_X)((value6.Position - value30.Torso.Position))).Magnitude > captures.encounter.REACH)
                        end
                    else
                        value1 = (not value6)
                    end
                    value2 = (value16 < captures.encounter.MAX_TIME)
                    if value2 then
                        value2 = ((- value24) > captures.encounter.AWAY_SPEED)
                        if value2 then
                            value2 = value1
                        end
                    end
                    if (captures.encounter.baitVictim ~= value40) then
                        captures.encounter.baitVictim = value40
                        captures.encounter.baitUntil = 0
                    end
                    value9 = false
                    if (value4 == "run") then
                        if (captures.encounter.baitUntil > (globals.tick())) then
                            if (value24 > captures.encounter.CANCEL_SPEED) then
                                value3 = captures.encounter
                                value6 = 0
                                value3.baitUntil = value6
                            end
                        end
                        if value2 then
                            value1 = (captures.encounter.baitUntil <= (globals.tick()))
                            if value1 then
                                value1 = captures.encounter
                                value5 = ((globals.tick()) + captures.encounter.DURATION)
                                value1.baitUntil = value5
                                value1 = captures.encounterRecords[value40.Name]
                                if value1 then
                                    value5 = value1.uses
                                    if (not value5) then
                                        value5 = 0
                                    end
                                    value5 = (value5 + 1)
                                    value1.uses = value5
                                end
                            end
                        else
            
                        end
                        value9 = (captures.encounter.baitUntil > (globals.tick()))
                    end
                    value1 = (value16 < value12)
                    if (not value1) then
                        value1 = (value23 > 0)
                        if value1 then
                            value1 = ((value16 - value23) < value12)
                            if (not value1) then
                                if value20 then
                                    value1 = (captures.opening.style == captures.opening.CHARGE)
                                    if (not value1) then
                                        value1 = value31
                                        if (not value1) then
                                            value1 = value18
                                        end
                                    end
                                else
                                    value1 = value31
                                    if (not value1) then
                                        value1 = value18
                                    end
                                end
                            end
                        else
                            if value20 then
                                value1 = (captures.opening.style == captures.opening.CHARGE)
                                if (not value1) then
                                    value1 = value31
                                    if (not value1) then
                                        value1 = value18
                                    end
                                end
                            else
                                value1 = value31
                                if (not value1) then
                                    value1 = value18
                                end
                            end
                        end
                    end
                    if value2 then
                        if (not value1) then
                            if (not captures.encounter.engaged) then
                                value1 = captures.encounter
                                value3 = captures.encounter
                                value6 = captures.encounter
                                value8 = captures.encounter
                                value52 = captures.encounter
                                value55 = captures.encounter
                                value60 = true
                                value61 = value40.Name
                                value1.engaged = value60
                                value3.victimChar = value40
                                value6.victimName = value61
                                value8.style = value4
                                value52.resolved = false
                                value55.phase = "holder"
                            end
                        end
                    end
                end
            else
                value9 = false
            end
            value1 = ((value16 + (R[45] / 1000)) + (R[46] / 1000))
            value1 = (value1 * (16))
            value15 = (value1 + (3))
            if (value16 < value12) then
                value14 = value40
                value17 = value38
                value13(value14, value15, value16, value17)
            else
                value1 = (value23 > 0)
                if value1 then
                    value1 = ((value16 - value23) < value12)
                    if value1 then
                        value14 = value40
                        value17 = value38
                        value13(value14, value15, value16, value17)
                    else
                        if value20 then
                            if (captures.opening.style == captures.opening.CHARGE) then
                                value48(value40)
                            else
                                if value31 then
                                    value1 = captures.debugState
                                    value3 = false
                                    value1.goodWindow = value3
                                    if captures.opening.cornerTarget then
                                        tmp_X = captures.navigateCell
                                        value2 = readCell(tmp_X)
                                        value3 = captures.opening.cornerTarget
                                        value7 = true
                                        value4 = true
                                        value5 = 2
                                        value8 = false
                                        value6 = value40
                                        value2(value3, value4, value5, value6, value7, value8)
                                    end
                                else
                                    if value18 then
                                        value14 = value40
                                        value17 = value38
                                        value13(value14, value15, value16, value17)
                                    else
                                        if value9 then
                                            captures.debugState.loseLoseStyle = "run"
                                            value14 = value40
                                            value17 = value38
                                            value13(value14, value15, value16, value17)
                                            captures.debugState.navMode = "ll-bait"
                                        else
                                            if (value11 < ((1.5 + (value47 / 1000)) / 2)) then
                                                value14 = value40
                                                value17 = value38
                                                value13(value14, value15, value16, value17)
                                            else
                                                value48(value40)
                                            end
                                        end
                                    end
                                end
                            end
                        else
                            if value31 then
                                value1 = captures.debugState
                                value3 = false
                                value1.goodWindow = value3
                                if captures.opening.cornerTarget then
                                    tmp_X = captures.navigateCell
                                    value2 = readCell(tmp_X)
                                    value3 = captures.opening.cornerTarget
                                    value7 = true
                                    value4 = true
                                    value5 = 2
                                    value8 = false
                                    value6 = value40
                                    value2(value3, value4, value5, value6, value7, value8)
                                end
                            else
                                if value18 then
                                    value14 = value40
                                    value17 = value38
                                    value13(value14, value15, value16, value17)
                                else
                                    if value9 then
                                        captures.debugState.loseLoseStyle = "run"
                                        value14 = value40
                                        value17 = value38
                                        value13(value14, value15, value16, value17)
                                        captures.debugState.navMode = "ll-bait"
                                    else
                                        if (value11 < ((1.5 + (value47 / 1000)) / 2)) then
                                            value14 = value40
                                            value17 = value38
                                            value13(value14, value15, value16, value17)
                                        else
                                            value48(value40)
                                        end
                                    end
                                end
                            end
                        end
                    end
                else
                    if value20 then
                        if (captures.opening.style == captures.opening.CHARGE) then
                            value48(value40)
                        else
                            if value31 then
                                value1 = captures.debugState
                                value3 = false
                                value1.goodWindow = value3
                                if captures.opening.cornerTarget then
                                    tmp_X = captures.navigateCell
                                    value2 = readCell(tmp_X)
                                    value3 = captures.opening.cornerTarget
                                    value7 = true
                                    value4 = true
                                    value5 = 2
                                    value8 = false
                                    value6 = value40
                                    value2(value3, value4, value5, value6, value7, value8)
                                end
                            else
                                if value18 then
                                    value14 = value40
                                    value17 = value38
                                    value13(value14, value15, value16, value17)
                                else
                                    if value9 then
                                        captures.debugState.loseLoseStyle = "run"
                                        value14 = value40
                                        value17 = value38
                                        value13(value14, value15, value16, value17)
                                        captures.debugState.navMode = "ll-bait"
                                    else
                                        if (value11 < ((1.5 + (value47 / 1000)) / 2)) then
                                            value14 = value40
                                            value17 = value38
                                            value13(value14, value15, value16, value17)
                                        else
                                            value48(value40)
                                        end
                                    end
                                end
                            end
                        end
                    else
                        if value31 then
                            value1 = captures.debugState
                            value3 = false
                            value1.goodWindow = value3
                            if captures.opening.cornerTarget then
                                tmp_X = captures.navigateCell
                                value2 = readCell(tmp_X)
                                value3 = captures.opening.cornerTarget
                                value7 = true
                                value4 = true
                                value5 = 2
                                value8 = false
                                value6 = value40
                                value2(value3, value4, value5, value6, value7, value8)
                            end
                        else
                            if value18 then
                                value14 = value40
                                value17 = value38
                                value13(value14, value15, value16, value17)
                            else
                                if value9 then
                                    captures.debugState.loseLoseStyle = "run"
                                    value14 = value40
                                    value17 = value38
                                    value13(value14, value15, value16, value17)
                                    captures.debugState.navMode = "ll-bait"
                                else
                                    if (value11 < ((1.5 + (value47 / 1000)) / 2)) then
                                        value14 = value40
                                        value17 = value38
                                        value13(value14, value15, value16, value17)
                                    else
                                        value48(value40)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            value1 = captures.humanization.ON
            if value1 then
                value1 = (captures.humanization.TURN > 0)
                if value1 then
                    value17 = value30
                    value16 = value17.FindFirstChild
                    value18 = "Torso"
                    value16 = value16(value17, value18)
                    value18 = value30
                    value17 = value18.FindFirstChildOfClass
                    value19 = "Humanoid"
                    value17 = value17(value18, value19)
                    if value16 then
                        value1 = value17
                        if value1 then
                            value1 = captures.humanization.slideNow
                            value2 = globals.tick()
                            value3 = captures.humanization.slideUntil
                            if (not value3) then
                                value3 = 0
                            end
                            value2 = (value2 < value3)
                            if value1 then
                                if (not captures.humanization.slidingPrev) then
                                    value4 = captures.humanization
                                    value6 = globals.math.random()
                                    value6 = (((value6 * (2)) - 1) * captures.humanization.SLIDEERR)
                                    value4.slideBias = value6
                                end
                            else
            
                            end
                            captures.humanization.slidingPrev = value1
                            if (value17.AutoRotate == false) then
                                return sharedPath_1910(...)
                            else
                                if value2 then
                                    return sharedPath_1910(...)
                                else
                                    tmp_X = captures.horizontalVectorCell
                                    value1 = readCell(tmp_X)(value16.CFrame.LookVector)
                                    value2 = value1.Magnitude
                                    if (0.001 < value2) then
                                        value2 = captures.humanization
                                        value1 = value1.Unit
                                        value2.lastLook = value1
                                    end
                                end
                            end
                        end
                    else
            
                    end
                end
            end
            closeCaptures(cells, R)
            return
        end

        sharedPath_1634 = function(...)
            value1 = captures.humanization.ON
            if value1 then
                value1 = (captures.humanization.TURN > 0)
                if value1 then
                    value17 = value30
                    value16 = value17.FindFirstChild
                    value18 = "Torso"
                    value16 = value16(value17, value18)
                    value18 = value30
                    value17 = value18.FindFirstChildOfClass
                    value19 = "Humanoid"
                    value17 = value17(value18, value19)
                    if value16 then
                        value1 = value17
                        if value1 then
                            value1 = captures.humanization.slideNow
                            value2 = globals.tick()
                            value3 = captures.humanization.slideUntil
                            if (not value3) then
                                value3 = 0
                            end
                            value2 = (value2 < value3)
                            if value1 then
                                if (not captures.humanization.slidingPrev) then
                                    value4 = captures.humanization
                                    value6 = globals.math.random()
                                    value6 = (((value6 * (2)) - 1) * captures.humanization.SLIDEERR)
                                    value4.slideBias = value6
                                end
                            else
            
                            end
                            captures.humanization.slidingPrev = value1
                            if (value17.AutoRotate == false) then
                                return sharedPath_1910(...)
                            else
                                if value2 then
                                    return sharedPath_1910(...)
                                else
                                    tmp_X = captures.horizontalVectorCell
                                    value1 = readCell(tmp_X)(value16.CFrame.LookVector)
                                    value2 = value1.Magnitude
                                    if (0.001 < value2) then
                                        value2 = captures.humanization
                                        value1 = value1.Unit
                                        value2.lastLook = value1
                                    end
                                end
                            end
                        end
                    else
            
                    end
                end
            end
            closeCaptures(cells, R)
            return
        end

        sharedPath_1910 = function(...)
            value9 = globals.math.min
            value11 = 0.05
            value9 = value9(value10, value11)
            if value3 then
                tmp_X = captures.horizontalVectorCell
                value2 = readCell(tmp_X)(value16.CFrame.LookVector)
                if value1 then
                    value3 = value2.Magnitude
                    value1 = (value3 > (0.001))
                    if value1 then
                        value1 = (captures.humanization.slideBias ~= 0)
                        if value1 then
                            value26 = globals.CFrame.Angles
                            value28 = captures.humanization.slideBias
                            value27 = 0
                            value29 = 0
                            value26 = ((value26(value27, value28, value29)))
                            value1 = value26.VectorToWorldSpace
                            value27 = value2.Unit
                            value25 = value1
                            value2 = (value25(value26, value27))
                        end
                    end
                end
            else
                tmp_X = captures.horizontalVectorCell
                value2 = readCell(tmp_X)(value17.MoveDirection)
            end
            if (value2.Magnitude < 0.001) then
                value2 = captures.humanization.lastLook
            end
            if value2 then
                value1 = (value2.Magnitude > 0.001)
                if value1 then
                    value1 = value2.Unit
                    value2 = captures.humanization.lastLook
                    if (not value2) then
                        value2 = value1
                    else
                        if (value2.Magnitude < 0.001) then
                            value2 = value1
                        end
                    end
                    value2 = value2.Unit
                    value17.AutoRotate = false
                    value37 = globals.math.atan2
                    value38 = value2.X
                    value39 = value2.Z
                    value37 = value37(value38, value39)
                    value38 = globals.math.atan2
                    value39 = value1.X
                    value40 = value1.Z
                    value39 = ((value38(value39, value40)) - value37)
                    if (3.141592653589793 < value39) then
                        value39 = (value39 - (6.283185307179586))
                    else
                        if (value39 < (- 3.141592653589793)) then
                            value39 = (value39 + 6.283185307179586)
                        end
                    end
                    value38 = globals.math.clamp
                    value40 = ((- captures.humanization.TURN) * value9)
                    value41 = (captures.humanization.TURN * value9)
                    value1 = (value37 + (value38(value39, value40, value41)))
                    value37 = globals.Vector3.new
                    value38 = globals.math.sin(value1)
                    value39 = 0
                    value2 = globals.math.cos
                    tmp_n = table.pack(value2(value1))
                    tmp_I = tmp_n.n
                    tmp_cache_r = ((3 + tmp_I) - 1)
                    tmp_n.n = tmp_cache_r
                    table.move(tmp_n, 1, tmp_I, 3, tmp_n)
                    table.move({[38] = value38, [39] = value39}, 38, 39, 1, tmp_n)
                    tmp_D = table.pack(value37(table.unpack(tmp_n, 1, tmp_n.n)))
                    value37 = rawget(tmp_D, 1)
                    value38 = globals.CFrame.lookAt
                    value39 = value16.Position
                    value40 = (value16.Position + value37)
                    value38 = value38(value39, value40)
                    value16.CFrame = value38
                    captures.humanization.lastLook = value37
                end
            else
            
            end
            closeCaptures(cells, R)
            return
        end

        tmp_X = {...}
        value10 = rawget(tmp_X, 1)
        tmp_X = captures.registryCell
        value1 = readCell(tmp_X).selected
        if (value1 == "kevin") then
            value3 = captures.debugState
            captures.sharedEnvironment.FANAKA_DEBUG = value3
            captures.debugState.mode = "idle"
            captures.debugState.navMode = "-"
            captures.debugState.waverMode = "-"
            captures.humanization.slideNow = false
            captures.debugState.loseLoseStyle = "-"
            captures.debugState.openingStyle = "-"
            value3 = captures.debugState
            value5 = captures.debugState
            value7 = captures.showGraph
            value8 = captures.showRays
            value9 = captures.showBeams
            captures.debugState.vizGraph = value7
            value3.vizRays = value8
            value5.vizBeams = value9
            value1 = globals.tick()
            tmp_X = captures.filterRefreshAtCell
            value1 = (value1 - (readCell(tmp_X)))
            if (10 < value1) then
                tmp_X = captures.refreshFiltersCell
                readCell(tmp_X)()
                value1 = globals.tick()
                tmp_X = captures.filterRefreshAtCell
                writeCell(tmp_X, value1)
            end
            value30 = captures.localPlayer.Character
            if captures.opening.USE then
                if captures.opening.armed then
                    if captures.opening.style then
                        if captures.opening.targetName then
                            if (not captures.opening.resolved) then
                                if value30 then
                                    value28 = value30
                                    value27 = value28.FindFirstChildOfClass
                                    value29 = "Humanoid"
                                    value27 = value27(value28, value29)
                                    if value27 then
                                        if (value27.Health <= 0) then
                                            captures.opening.markDeath()
                                        end
                                    end
                                else
        
                                end
                            end
                        end
                    end
                end
            end
            if captures.encounter.USE then
                if captures.encounter.engaged then
                    if captures.encounter.style then
                        if captures.encounter.victimName then
                            if (not captures.encounter.resolved) then
                                if value30 then
                                    value27 = value30
                                    value26 = value27.FindFirstChildOfClass
                                    value28 = "Humanoid"
                                    value26 = value26(value27, value28)
                                    if value26 then
                                        if (value26.Health <= 0) then
                                            captures.encounter.markDeath()
                                        end
                                    end
                                else
        
                                end
                            end
                        end
                    end
                end
            end
            value1 = captures.opponentStats.opponent
            if value1 then
                value1 = (not captures.opponentStats.resolved)
                if value1 then
                    if value30 then
                        value26 = value30
                        value25 = value26.FindFirstChildOfClass
                        value27 = "Humanoid"
                        value25 = value25(value26, value27)
                        if value25 then
                            value1 = value25.Health
                            if (value1 <= (0)) then
                                captures.opponentStats.ensure(captures.opponentStats.opponent)
                                value1 = captures.opponentStats.players[captures.opponentStats.opponent]
                                value3 = (captures.opponentStats.players[captures.opponentStats.opponent].losses + 1)
                                value1.losses = value3
                                captures.opponentStats.resolved = true
                            end
                        end
                    else
        
                    end
                end
            end
            value1 = (not value30)
            if (not value1) then
                value25 = value30
                value24 = value25.FindFirstChild
                value26 = "Torso"
                value1 = (not (value24(value25, value26)))
                if (not value1) then
                    R[42] = false
                    globals.pcall((Functions.helper_941({slot1 = captures.localPlayer, slot2 = captureShared(cells, R, 42)}, globals)))
                    value1 = captures.queueState.wasInGame
                    if (R[42] ~= value1) then
                        if R[42] then
                            tmp_X = captures.settingsCell
                            if readCell(tmp_X).autoQueue then
                                value2 = captures.queueState
                                value4 = captures.queueState
                                value6 = true
                                value7 = globals.tick()
                                value2.pendingBake = value6
                                value4.bakeEnter = value7
                                value2 = captures.queueState
                                value4 = captures.queueState
                                value6 = captures.queueState
                                value8 = value30.Torso.Position
                                value9 = value30.Torso.Position
                                value2.bakeEntryPos = value8
                                value4.bakeLastPos = value9
                                value6.bakeStableSince = 0
                            end
                        else
                            value1 = R[42]
                        end
                        if R[42] then
                            captures.queueState.reset()
                        end
                        captures.queueState.wasInGame = R[42]
                    end
                    tmp_X = captures.settingsCell
                    if readCell(tmp_X).autoQueue then
                        if (not R[42]) then
                            captures.queueState.run()
                        else
                            return sharedPath_160(...)
                        end
                    else
                        return sharedPath_160(...)
                    end
                end
            end
        end
        closeCaptures(cells, R)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.roundCorners = function(captures, globals)
    return function(parent, radius)
        local corner = globals.Instance.new("UICorner")
        corner.CornerRadius = globals.UDim.new(0, radius or 6)
        corner.Parent = parent
        return corner
    end
end

Functions.helper_242 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value4, value5, value7

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value4 = value2.reachAdjust
        value5 = captures.slot2
        value7 = globals.math.floor
        value2 = value2.reachAdjust[captures.slot2]
        if (not value2) then
            value2 = 0
        end
        value2 = (value2 + 0.1)
        value2 = ((value7(((value2 * (100)) + 0.5))) / 100)
        value4[value5] = value2
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.handleKevinKeyDown = function(captures, globals)
    return function(input)
        if input.UserInputType ~= globals.Enum.UserInputType.Keyboard then return end
        local key = input.KeyCode
        if key == globals.Enum.KeyCode.B then writeCell(captures.enabledCell, true) end
        if key == globals.Enum.KeyCode.P then writeCell(captures.teleportHeldCell, true) end
        if key == globals.Enum.KeyCode.V then writeCell(captures.enabledCell, true) end
        if key == globals.Enum.KeyCode.N then writeCell(captures.enabledCell, false) end
    end
end

Functions.helper_271 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value14, value15

        tmp_X = {...}
        value14, value15 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = captures.slot1
        if (value14 == value2) then
            value2 = (value15 ~= captures.slot2)
            if value2 then
                value2 = captures.slot3[value15]
                if value2 then
                    return value2
                else
                    value2 = false
                    return value2
                end
            else
                value2 = false
                return value2
            end
        end
        value2 = (value15 == captures.slot1)
        if (not value2) then
            value2 = captures.slot2
            if (value14 == value2) then
                value2 = captures.slot5[value15]
                return value2
            else
                value2 = captures.slot2
                if (value15 == value2) then
                    value2 = captures.slot5[value14]
                    return value2
                else
                    tmp_X = captures.slot6
                    value2 = readCell(tmp_X)[value14][value15]
                    return value2
                end
            end
        end
        value3 = (value14 ~= captures.slot2)
        if value3 then
            value3 = captures.slot3[value14]
            if (not value3) then
                value3 = false
            end
        else
            value3 = false
        end
        return value3
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_280 = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local tmp_D, tmp_X, value4, value5, value6, value7, value12, value30, value31, value32, value33, value34

        tmp_X = {...}
        value30 = rawget(tmp_X, 1)
        if (not value30) then
            closeCaptures(cells, R)
            return nil
        end
        value32 = value30
        value31 = value32.FindFirstChild
        R[1] = value31
        value33 = "Torso"
        value31 = R[1]
        value31 = value31(value32, value33)
        if (not value31) then
            closeCaptures(cells, R)
            return nil
        end
        value4 = value31.Position
        tmp_X = captures.slot1
        R[1] = readCell(tmp_X)
        if (value30 ~= R[1]) then
            R[1] = globals.Vector3
            value31 = R[1].new
            value32 = 0
            value33 = 0
            value34 = 0
            value31 = value31(value32, value33, value34)
            tmp_X = captures.slot3
            writeCell(tmp_X, value31)
            tmp_X = captures.slot4
            writeCell(tmp_X, value12)
            tmp_X = captures.slot1
            writeCell(tmp_X, value30)
        end
        tmp_X = captures.slot5
        R[1] = readCell(tmp_X)
        value5 = R[1](value4)
        R[1] = globals.tick
        value6 = R[1]()
        tmp_X = captures.slot4
        R[1] = readCell(tmp_X)
        tmp_X = captures.slot4
        value7 = readCell(tmp_X)
        if R[1] then
            tmp_X = captures.slot6
            value7 = readCell(tmp_X)
        end
        if value7 then
            tmp_X = captures.slot6
            R[1] = readCell(tmp_X)
            value7 = (value6 - R[1])
            R[1] = 0.001
            if (value7 > R[1]) then
                if (value7 < 0.5) then
                    tmp_X = captures.slot3
                    value31 = readCell(tmp_X)
                    value30 = value31.Lerp
                    R[1] = value30
                    tmp_X = captures.slot4
                    value32 = ((value5 - (readCell(tmp_X))) / value7)
                    value33 = 0.35
                    value30 = R[1]
                    value30 = value30(value31, value32, value33)
                    tmp_X = captures.slot3
                    writeCell(tmp_X, value30)
                end
            end
        end
        tmp_X = captures.slot4
        writeCell(tmp_X, value5)
        tmp_X = captures.slot6
        writeCell(tmp_X, value6)
        R[1] = 0.05
        globals.pcall((Functions.helper_1766({slot1 = captures.slot7, slot2 = captureShared(cells, R, 1)}, globals)))
        value30 = globals.math.clamp
        value31 = (R[1] + 0.1)
        value32 = 0
        value33 = 0.35
        value5 = ((value30(value31, value32, value33)) - captures.slot8.REACT)
        value30 = globals.Vector3.new
        tmp_X = captures.slot3
        value31 = readCell(tmp_X).X
        value32 = 0
        tmp_X = captures.slot3
        value33 = readCell(tmp_X).Z
        value4 = (value4 + ((value30(value31, value32, value33)) * value5))
        closeCaptures(cells, R)
        return value4
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_281 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value6, value8, value31, value32, value33, value34, value35

        tmp_X = {...}
        value34, value35 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value31 = readCell(tmp_X)
        value6 = "TextLabel"
        value8 = {}
        value1 = globals.UDim2.new
        value2 = 1
        value5 = 18
        value3 = 0
        value4 = 0
        value1 = value1(value2, value3, value4, value5)
        value8.Size = value1
        value32 = globals.UDim2.fromOffset
        value33 = 0
        value32 = value32(value33, value34)
        value8.Position = value32
        value8.BackgroundTransparency = 1
        value2 = globals.Enum.Font.GothamBold
        value8.Font = value2
        value8.Text = value35
        value2 = captures.slot3.text
        value8.TextColor3 = value2
        value8.TextSize = 14
        value2 = globals.Enum.TextXAlignment.Left
        value8.TextXAlignment = value2
        value34 = captures.slot4
        value32 = value6
        value33 = value8
        value31(value32, value33, value34)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_289 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value13

        tmp_X = {...}
        value13 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value2 = (1.5 + ((readCell(tmp_X)) / 1000))
        tmp_X = captures.slot2
        value4 = (1.5 + ((readCell(tmp_X)) / 1000))
        tmp_X = captures.slot1
        if (value13 < (1.2 + ((readCell(tmp_X)) / 1000))) then
            return true
        end
        if (value13 < (value2 + value4)) then
            return false
        end
        if (value13 < (((value2 / (2)) + value4) + value2)) then
            tmp_X = captures.authAliveCell
            if (not (readCell(tmp_X))) then
                return
            else
                return true
            end
        end
        if (value13 < ((((value2 / 2) + value4) + value2) + value4)) then
            return false
        end
        value2 = (((((value2 / 2) + value4) + value2) + value4) + value2)
        if (value13 < value2) then
            return true
        end
        value2 = false
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_299 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, tmp_Y, value1, value2, value3, value4, value5, value33, value34, value35, value36

        tmp_X = {...}
        value35, value36 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value1 = readCell(tmp_X)(value35)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)(value36)
        value3 = globals.math.floor
        value4 = value1.X
        value3 = value3((value4 * (2)))
        value1 = globals.math.floor((value1.Z * 2))
        value2 = ((globals.math.floor((value2.X * 2))) .. (":" .. (globals.math.floor((value2.Z * 2)))))
        value1 = (value3 .. (":" .. (value1 .. (":" .. value2))))
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)[value1]
        if value2 then
            value3 = value2[1]
            value4 = value2[2]
            value5 = value2[(3)]
            return value3, value4, value5
        end
        tmp_X = captures.slot4
        value34 = readCell(tmp_X)
        value34, value35, value36 = value34(value35, value36)
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        value33 = {}
        tmp_Y = value33
        table.move({[34] = value34, [35] = value35, [36] = value36}, 34, 36, 1, tmp_Y)
        value2[value1] = value33
        return value34, value35, value36
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_306 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, loopExit_49, loopExit_68, loopExit_90, loopExit_121, loopExit_178, value2, value3, value5, value6, value7, value8, value10, value11, value12, value13, value14, value15, value17, value18, value20, value21, value22, value23, value24, value25

        tmp_X = {...}
        value2, value3 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)(value2)
        tmp_X = captures.slot1
        value10 = readCell(tmp_X)(value3)
        tmp_X = captures.slot2
        value5 = readCell(tmp_X)
        value6 = value2
        value7 = value10
        value5 = value5(value6, value7)
        if value5 then
            value5 = (value10 - value2).Magnitude
            return value5, true, value3
        end
        tmp_X = captures.slot3
        value12 = (# (readCell(tmp_X)))
        if (value12 == 0) then
            value5 = (value10 - value2).Magnitude
            return value5, false, value3
        end
        tmp_X = captures.slot4
        value5 = readCell(tmp_X)
        value14 = (value5 ~= value25)
        if value14 then
            tmp_X = captures.slot5
            value5 = readCell(tmp_X)
            value14 = (value5 ~= value24)
            if value14 then
                tmp_X = captures.slot4
                value5 = (# (readCell(tmp_X)))
                value14 = (value5 == value12)
                if value14 then
                    tmp_X = captures.slot5
                    value5 = (value2 - (readCell(tmp_X))).Magnitude
                    value14 = (value5 < 0.5)
                    value15 = {}
                    value17 = {}
                    value11 = 1
                    value13 = 1
                    loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
                    while true do
                        loop.index += loop.step
                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                        if loopContinues then
                            value11 = loop.index
                        end
                        if loopContinues then
                            if value14 then
                                tmp_X = captures.slot4
                                value5 = readCell(tmp_X)[value11]
                                if (not value5) then
                                    tmp_X = captures.slot2
                                    value8 = readCell(tmp_X)
                                    tmp_X = captures.slot3
                                    value7 = readCell(tmp_X)[value11]
                                    value5 = value8
                                    value6 = value2
                                    value5 = value5(value6, value7)
                                end
                                value15[value11] = value5
                                tmp_X = captures.slot2
                                value6 = readCell(tmp_X)
                                tmp_X = captures.slot3
                                value8 = readCell(tmp_X)[value11]
                                value7 = value10
                                value6 = value6(value7, value8)
                                value17[value11] = value6
                                continue
                            else
                                loopExit_178 = 42
                                break
                            end
                        else
                            loopExit_178 = 39
                            break
                        end
                    end
                    if (loopExit_178 == 39) then
        
                    elseif (loopExit_178 == 42) then
                        while true do
                            value5 = value14
                            while true do
                                tmp_X = captures.slot2
                                value8 = readCell(tmp_X)
                                tmp_X = captures.slot3
                                value7 = readCell(tmp_X)[value11]
                                value5 = value8
                                value6 = value2
                                value5 = value5(value6, value7)
                                while true do
                                    value15[value11] = value5
                                    tmp_X = captures.slot2
                                    value6 = readCell(tmp_X)
                                    tmp_X = captures.slot3
                                    value8 = readCell(tmp_X)[value11]
                                    value7 = value10
                                    value6 = value6(value7, value8)
                                    value17[value11] = value6
                                    loop.index += loop.step
                                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                    if loopContinues then
                                        value11 = loop.index
                                    end
                                    if loopContinues then
                                        if value14 then
                                            tmp_X = captures.slot4
                                            value5 = readCell(tmp_X)[value11]
                                            if value5 then
                                                continue
                                            else
                                                loopExit_68 = 49
                                                break
                                            end
                                        else
                                            loopExit_68 = 42
                                            break
                                        end
                                    else
                                        loopExit_68 = 39
                                        break
                                    end
                                end
                                if (loopExit_68 == 39) then
                                    loopExit_49 = 39
                                    break
                                elseif (loopExit_68 == 42) then
                                    loopExit_49 = 42
                                    break
                                elseif (loopExit_68 == 49) then
                                    continue
                                end
                            end
                            if (loopExit_49 == 39) then
                                break
                            elseif (loopExit_49 == 42) then
                                continue
                            end
                        end
                    end
                else
                    value15 = {}
                    value17 = {}
                    value11 = 1
                    value13 = 1
                    loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value11 = loop.index
                    end
                    if loopContinues then
                        while true do
                            value5 = value14
                            while true do
                                tmp_X = captures.slot2
                                value8 = readCell(tmp_X)
                                tmp_X = captures.slot3
                                value7 = readCell(tmp_X)[value11]
                                value5 = value8
                                value6 = value2
                                value5 = value5(value6, value7)
                                while true do
                                    value15[value11] = value5
                                    tmp_X = captures.slot2
                                    value6 = readCell(tmp_X)
                                    tmp_X = captures.slot3
                                    value8 = readCell(tmp_X)[value11]
                                    value7 = value10
                                    value6 = value6(value7, value8)
                                    value17[value11] = value6
                                    loop.index += loop.step
                                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                    if loopContinues then
                                        value11 = loop.index
                                    end
                                    if loopContinues then
                                        if value14 then
                                            tmp_X = captures.slot4
                                            value5 = readCell(tmp_X)[value11]
                                            if value5 then
                                                continue
                                            else
                                                loopExit_68 = 49
                                                break
                                            end
                                        else
                                            loopExit_68 = 42
                                            break
                                        end
                                    else
                                        loopExit_68 = 39
                                        break
                                    end
                                end
                                if (loopExit_68 == 39) then
                                    loopExit_49 = 39
                                    break
                                elseif (loopExit_68 == 42) then
                                    loopExit_49 = 42
                                    break
                                elseif (loopExit_68 == 49) then
                                    continue
                                end
                            end
                            if (loopExit_49 == 39) then
                                break
                            elseif (loopExit_49 == 42) then
                                continue
                            end
                        end
                    end
                end
            else
                value15 = {}
                value17 = {}
                value11 = 1
                value13 = 1
                loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
                loop.index += loop.step
                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                if loopContinues then
                    value11 = loop.index
                end
                if loopContinues then
                    while true do
                        value5 = value14
                        while true do
                            tmp_X = captures.slot2
                            value8 = readCell(tmp_X)
                            tmp_X = captures.slot3
                            value7 = readCell(tmp_X)[value11]
                            value5 = value8
                            value6 = value2
                            value5 = value5(value6, value7)
                            while true do
                                value15[value11] = value5
                                tmp_X = captures.slot2
                                value6 = readCell(tmp_X)
                                tmp_X = captures.slot3
                                value8 = readCell(tmp_X)[value11]
                                value7 = value10
                                value6 = value6(value7, value8)
                                value17[value11] = value6
                                loop.index += loop.step
                                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                if loopContinues then
                                    value11 = loop.index
                                end
                                if loopContinues then
                                    if value14 then
                                        tmp_X = captures.slot4
                                        value5 = readCell(tmp_X)[value11]
                                        if value5 then
                                            continue
                                        else
                                            loopExit_68 = 49
                                            break
                                        end
                                    else
                                        loopExit_68 = 42
                                        break
                                    end
                                else
                                    loopExit_68 = 39
                                    break
                                end
                            end
                            if (loopExit_68 == 39) then
                                loopExit_49 = 39
                                break
                            elseif (loopExit_68 == 42) then
                                loopExit_49 = 42
                                break
                            elseif (loopExit_68 == 49) then
                                continue
                            end
                        end
                        if (loopExit_49 == 39) then
                            break
                        elseif (loopExit_49 == 42) then
                            continue
                        end
                    end
                end
            end
        else
            value15 = {}
            value17 = {}
            value11 = 1
            value13 = 1
            loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value11 = loop.index
            end
            if loopContinues then
                while true do
                    value5 = value14
                    while true do
                        tmp_X = captures.slot2
                        value8 = readCell(tmp_X)
                        tmp_X = captures.slot3
                        value7 = readCell(tmp_X)[value11]
                        value5 = value8
                        value6 = value2
                        value5 = value5(value6, value7)
                        while true do
                            value15[value11] = value5
                            tmp_X = captures.slot2
                            value6 = readCell(tmp_X)
                            tmp_X = captures.slot3
                            value8 = readCell(tmp_X)[value11]
                            value7 = value10
                            value6 = value6(value7, value8)
                            value17[value11] = value6
                            loop.index += loop.step
                            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                            if loopContinues then
                                value11 = loop.index
                            end
                            if loopContinues then
                                if value14 then
                                    tmp_X = captures.slot4
                                    value5 = readCell(tmp_X)[value11]
                                    if value5 then
                                        continue
                                    else
                                        loopExit_68 = 49
                                        break
                                    end
                                else
                                    loopExit_68 = 42
                                    break
                                end
                            else
                                loopExit_68 = 39
                                break
                            end
                        end
                        if (loopExit_68 == 39) then
                            loopExit_49 = 39
                            break
                        elseif (loopExit_68 == 42) then
                            loopExit_49 = 42
                            break
                        elseif (loopExit_68 == 49) then
                            continue
                        end
                    end
                    if (loopExit_49 == 39) then
                        break
                    elseif (loopExit_49 == 42) then
                        continue
                    end
                end
            end
        end
        loop = loop.parent
        value14 = (value12 + 1)
        value12 = (value12 + 2)
        value18 = Functions.helper_540({slot1 = value14, slot2 = value2, slot3 = value12, slot4 = value10, slot5 = captures.slot3}, globals)
        value8 = Functions.helper_271({slot1 = value14, slot2 = value12, slot3 = value15, catalogCell = captures.catalogCell, slot5 = value17, slot6 = captures.slot7}, globals)
        value20 = {}
        value21 = {}
        value22 = {}
        value11 = 1
        value13 = 1
        loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value5 = loop.index
            end
            if loopContinues then
                value6 = globals.math.huge
                value20[value5] = value6
                continue
            else
                break
            end
        end
        loop = loop.parent
        value20[value14] = 0
        value11 = 1
        value13 = 1
        loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value5 = loop.index
            end
            if loopContinues then
                value5 = globals.math.huge
                value11 = 1
                value13 = 1
                value6 = nil
                loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value7 = loop.index
                    end
                    if loopContinues then
                        if (not value21[value7]) then
                            if (value20[value7] < value5) then
                                value5 = value20[value7]
                                value6 = value7
                                continue
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                value5 = (not value6)
                if value5 then
                    loopExit_90 = 96
                    break
                else
                    value5 = (value6 == value12)
                    if value5 then
                        loopExit_90 = 96
                        break
                    else
                        value5 = true
                        value21[value6] = value5
                        value23 = value18(value6)
                        value11 = 1
                        value13 = 1
                        loop = {parent = loop, index = (value11 - value13), limit = value12, step = value13}
                        while true do
                            loop.index += loop.step
                            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                            if loopContinues then
                                value7 = loop.index
                            end
                            if loopContinues then
                                value5 = (not value21[value7])
                                if value5 then
                                    value5 = (value7 ~= value6)
                                    if value5 then
                                        value5 = value8
                                        value5 = value5(value6, value7)
                                        if value5 then
                                            value5 = (value20[value6] + ((value18(value7)) - value23).Magnitude)
                                            if (not (value5 < value20[value7])) then
                                                continue
                                            else
                                                value20[value7] = value5
                                                value22[value7] = value6
                                                continue
                                            end
                                        else
                                            continue
                                        end
                                    else
                                        continue
                                    end
                                else
                                    continue
                                end
                            else
                                break
                            end
                        end
                        loop = loop.parent
                        continue
                    end
                end
            else
                loopExit_90 = 92
                break
            end
        end
        if (loopExit_90 == 92) then
        
        elseif (loopExit_90 == 96) then
        
        end
        loop = loop.parent
        value5 = value20[value12]
        value6 = globals.math.huge
        if (value5 == value6) then
            value5 = (value10 - value2).Magnitude
            value6 = false
            return value5, value6, value3
        end
        value3 = value12
        while true do
            if value3 then
                value5 = value22[value3]
                value6 = nil
                if value5 then
                    if (value22[value3] == value14) then
                        loopExit_121 = 142
                        break
                    else
                        value3 = value22[value3]
                        continue
                    end
                else
                    loopExit_121 = 139
                    break
                end
            else
                loopExit_121 = 122
                break
            end
        end
        if (loopExit_121 == 122) then
            value6 = nil
        elseif (loopExit_121 == 139) then
        
        elseif (loopExit_121 == 142) then
            value6 = value3
        end
        if value6 then
            value6 = value18(value6)
            if (not value6) then
                value6 = value10
            end
        else
            value6 = value10
        end
        value3 = value20[value12]
        return value3, false, value6
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_331 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value5, value15, value16, value17, value18, value19

        tmp_X = {...}
        value15, value16, value17 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value3 = globals.Instance.new("Part")
        value5 = globals.Enum.PartType.Ball
        value3.Shape = value5
        value3.Anchored = true
        value3.CanCollide = false
        value3.CanQuery = false
        value5 = false
        value3.CastShadow = value5
        value5 = globals.Enum.Material.Neon
        value3.Material = value5
        value3.Color = value16
        value16 = globals.Vector3.new
        value18 = value17
        value19 = value17
        value16 = value16(value17, value18, value19)
        value3.Size = value16
        value2 = globals.CFrame.new
        value16 = value15.X
        tmp_X = captures.slot2
        value17 = readCell(tmp_X)
        value18 = value15.Z
        value15 = value2
        value15 = value15(value16, value17, value18)
        value3.CFrame = value15
        tmp_X = captures.slot3
        value5 = readCell(tmp_X)
        value3.Parent = value5
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_344 = function(captures, globals)
    local function recovered(...)
        local value3, value8

        value3 = globals.Instance.new("Folder")
        value8 = captures.slot1
        value3.Parent = value8
        value3.Destroy(value3)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_366 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, value1, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value12, value13, value14, value31, value32, value33, value34, value35, value36

        tmp_X = {...}
        value33, value34, value35, value36 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        tmp_X = captures.slot1
        value6 = readCell(tmp_X)
        value7 = "Frame"
        value8 = {}
        value1 = globals.UDim2.new
        value2 = 1
        value3 = 0
        value4 = 0
        value5 = 28
        value1 = value1(value2, value3, value4, value5)
        value8.Size = value1
        value31 = globals.UDim2.fromOffset
        value32 = 0
        value31 = value31(value32, value33)
        value8.Position = value31
        value2 = captures.slot3.panel2
        value8.BackgroundColor3 = value2
        value8.BorderSizePixel = 0
        value4 = captures.slot4
        value1 = value6
        value2 = value7
        value3 = value8
        value5 = (value1(value2, value3, value4))
        tmp_X = captures.slot5
        readCell(tmp_X)(value5, 6)
        tmp_X = captures.slot1
        value11 = readCell(tmp_X)
        value12 = "TextLabel"
        value4 = {}
        value6 = globals.UDim2.new
        value7 = 0.5
        value8 = (- 10)
        value9 = 1
        value10 = 0
        value6 = value6(value7, value8, value9, value10)
        value4.Size = value6
        value1 = globals.UDim2.fromOffset
        value2 = 10
        value3 = 0
        value1 = value1(value2, value3)
        value4.Position = value1
        value4.BackgroundTransparency = 1
        value2 = globals.Enum.Font.GothamMedium
        value4.Font = value2
        value4.Text = value34
        value2 = captures.slot3.subtext
        value4.TextColor3 = value2
        value4.TextSize = 12
        value2 = globals.Enum.TextXAlignment.Left
        value4.TextXAlignment = value2
        value2 = value11
        value3 = value12
        value2(value3, value4, value5)
        value12 = {}
        value13 = (# value35)
        value34 = (value13 >= 3)
        if value34 then
            value34 = 56
            if (not value34) then
                value34 = 70
            end
        else
            value34 = 70
        end
        value14 = (value34 + (4))
        value1 = globals.ipairs
        value2 = value35
        value1, value2, value3 = value1(value2)
        loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value2, value3 = tmp_key, tmp_value
            end
            if loopContinues then
                tmp_X = captures.slot1
                value4 = readCell(tmp_X)
                value11 = {}
                value33 = globals.UDim2.fromOffset
                value35 = 22
                value33 = value33(value34, value35)
                value11.Size = value33
                value6 = globals.UDim2.new
                value7 = (- (value13 * value14))
                value8 = (value7 + ((value2 - (1)) * value14))
                value10 = (- (11))
                value7 = 1
                value9 = 0.5
                value6 = value6(value7, value8, value9, value10)
                value11.Position = value6
                value7 = captures.slot3.panel
                value11.BackgroundColor3 = value7
                value7 = value36(value3)
                value11.Text = value7
                value7 = globals.Enum.Font.GothamBold
                value11.Font = value7
                value7 = captures.slot3.subtext
                value11.TextColor3 = value7
                value11.TextSize = 12
                value7 = true
                value11.AutoButtonColor = value7
                value7 = 0
                value11.BorderSizePixel = value7
                value7 = "TextButton"
                value6 = value4
                value8 = value11
                value9 = value5
                value6 = value6(value7, value8, value9)
                tmp_X = captures.slot5
                readCell(tmp_X)(value6, 6)
                value12[value3] = value6
                continue
            else
                break
            end
        end
        loop = loop.parent
        return value12
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.beginWindowDrag = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value7

        tmp_X = {...}
        value4 = rawget(tmp_X, 1)
        value2 = (value4.UserInputType == globals.Enum.UserInputType.MouseButton1)
        if value2 then
            tmp_X = captures.slot1
            writeCell(tmp_X, true)
            value2 = value4.Position
            tmp_X = captures.slot2
            writeCell(tmp_X, value2)
            value2 = captures.slot3.Position
            tmp_X = captures.slot4
            writeCell(tmp_X, value2)
            value7 = value4.Changed
            lifecycle.connect(value7, (Functions.helper_1856({slot1 = value4, catalogCell = captures.catalogCell, slot3 = captures.slot1}, globals)))
        else
            value2 = (value4.UserInputType == globals.Enum.UserInputType.Touch)
            if value2 then
                tmp_X = captures.slot1
                writeCell(tmp_X, true)
                value2 = value4.Position
                tmp_X = captures.slot2
                writeCell(tmp_X, value2)
                value2 = captures.slot3.Position
                tmp_X = captures.slot4
                writeCell(tmp_X, value2)
                value7 = value4.Changed
                lifecycle.connect(value7, (Functions.helper_1856({slot1 = value4, catalogCell = captures.catalogCell, slot3 = captures.slot1}, globals)))
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_379 = function(captures, globals)
    local function recovered(...)
        local R = {}
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value12, value13, value14, value15, value17, value18, value20, value21, value23

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value3 = "Configurables"
        if (value2 == value3) then
            tmp_X = captures.slot3
            value15 = readCell(tmp_X)()
            value17 = captures.slot4.FANAKA_DEBUG
            tmp_X = captures.slot5
            value2 = readCell(tmp_X)
            value4 = value15.randomiseAggro
            if value4 then
                value4 = "ON"
            else
                value4 = "OFF"
            end
            value2.Text = value4
            tmp_X = captures.slot5
            value2 = readCell(tmp_X)
            value4 = value15.randomiseAggro
            if value4 then
                value4 = captures.slot6.accent
                if (not value4) then
                    value4 = captures.slot6.panel
                end
            else
                value4 = captures.slot6.panel
            end
            value2.BackgroundColor3 = value4
            value2 = globals.pairs
            tmp_X = captures.slot7
            value3 = readCell(tmp_X)
            value2, value3, value4 = value2(value3)
            loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value3, value4 = tmp_key, tmp_value
                end
                if loopContinues then
                    value5 = (value15.defaultAggroStyle == value3)
                    if value5 then
                        value7 = captures.slot6.accent
                        if (not value7) then
                            value7 = captures.slot6.panel
                        end
                    else
                        value7 = captures.slot6.panel
                    end
                    value4.BackgroundColor3 = value7
                    value9 = value15.randomiseAggro
                    if value9 then
                        value9 = captures.slot6.idle
                        if (not value9) then
                            if value5 then
                                value5 = globals.Color3.new
                                value12 = 1
                                value10 = 1
                                value11 = 1
                                value9 = value5
                                value9 = value9(value10, value11, value12)
                                if (not value9) then
                                    value9 = captures.slot6.subtext
                                end
                            else
                                value9 = captures.slot6.subtext
                            end
                        end
                    else
                        if value5 then
                            value5 = globals.Color3.new
                            value12 = 1
                            value10 = 1
                            value11 = 1
                            value9 = value5
                            value9 = value9(value10, value11, value12)
                            if (not value9) then
                                value9 = captures.slot6.subtext
                            end
                        else
                            value9 = captures.slot6.subtext
                        end
                    end
                    value4.TextColor3 = value9
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            tmp_X = captures.slot8
            value2 = readCell(tmp_X)
            value4 = value15.randomiseLoseLose
            if value4 then
                value4 = "ON"
            else
                value4 = "OFF"
            end
            value2.Text = value4
            tmp_X = captures.slot8
            value2 = readCell(tmp_X)
            value4 = value15.randomiseLoseLose
            if value4 then
                value4 = captures.slot6.accent
                if (not value4) then
                    value4 = captures.slot6.panel
                end
            else
                value4 = captures.slot6.panel
            end
            value2.BackgroundColor3 = value4
            value5 = globals.pairs
            tmp_X = captures.slot9
            value6 = readCell(tmp_X)
            value5, value6, value7 = value5(value6)
            loop = {parent = loop, iterator = iterateValues(value5, value6, value7)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value6, value7 = tmp_key, tmp_value
                end
                if loopContinues then
                    value2 = (value15.defaultLoseLoseStyle == value6)
                    if value2 then
                        value4 = captures.slot6.accent
                        if (not value4) then
                            value4 = captures.slot6.panel
                        end
                    else
                        value4 = captures.slot6.panel
                    end
                    value7.BackgroundColor3 = value4
                    value9 = value15.randomiseLoseLose
                    if value9 then
                        value9 = captures.slot6.idle
                        if (not value9) then
                            if value2 then
                                value2 = globals.Color3.new
                                value11 = 1
                                value10 = 1
                                value12 = 1
                                value9 = value2
                                value9 = value9(value10, value11, value12)
                                if (not value9) then
                                    value9 = captures.slot6.subtext
                                end
                            else
                                value9 = captures.slot6.subtext
                            end
                        end
                    else
                        if value2 then
                            value2 = globals.Color3.new
                            value11 = 1
                            value10 = 1
                            value12 = 1
                            value9 = value2
                            value9 = value9(value10, value11, value12)
                            if (not value9) then
                                value9 = captures.slot6.subtext
                            end
                        else
                            value9 = captures.slot6.subtext
                        end
                    end
                    value7.TextColor3 = value9
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            tmp_X = captures.slot10
            value2 = readCell(tmp_X)
            value4 = value15.randomiseOpening
            if value4 then
                value4 = "ON"
            else
                value4 = "OFF"
            end
            value2.Text = value4
            tmp_X = captures.slot10
            value2 = readCell(tmp_X)
            value4 = value15.randomiseOpening
            if value4 then
                value4 = captures.slot6.accent
                if (not value4) then
                    value4 = captures.slot6.panel
                end
            else
                value4 = captures.slot6.panel
            end
            value2.BackgroundColor3 = value4
            value8 = globals.pairs
            tmp_X = captures.slot11
            value9 = readCell(tmp_X)
            value8, value9, value10 = value8(value9)
            loop = {parent = loop, iterator = iterateValues(value8, value9, value10)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value9, value10 = tmp_key, tmp_value
                end
                if loopContinues then
                    value2 = (value15.defaultOpeningStyle == value9)
                    if value2 then
                        value4 = captures.slot6.accent
                        if (not value4) then
                            value4 = captures.slot6.panel
                        end
                    else
                        value4 = captures.slot6.panel
                    end
                    value10.BackgroundColor3 = value4
                    value11 = value15.randomiseOpening
                    if value11 then
                        value11 = captures.slot6.idle
                        if (not value11) then
                            if value2 then
                                value2 = globals.Color3.new
                                value12 = 1
                                value13 = 1
                                value14 = 1
                                value11 = value2
                                value11 = value11(value12, value13, value14)
                                if (not value11) then
                                    value11 = captures.slot6.subtext
                                end
                            else
                                value11 = captures.slot6.subtext
                            end
                        end
                    else
                        if value2 then
                            value2 = globals.Color3.new
                            value12 = 1
                            value13 = 1
                            value14 = 1
                            value11 = value2
                            value11 = value11(value12, value13, value14)
                            if (not value11) then
                                value11 = captures.slot6.subtext
                            end
                        else
                            value11 = captures.slot6.subtext
                        end
                    end
                    value10.TextColor3 = value11
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            value2 = {}
            value3 = Functions.helper_1366({slot1 = value2}, globals)
            if value17 then
                value3(value17.loseLoseRaw)
                value3(value17.reachTableRaw)
                value3(value17.aggroRaw)
                value3(value17.openingRaw)
                value3(value17.winLossRaw)
                value3(value15.reachAdjust)
                value15 = value17.loseLoseRaw
                value18 = value17.aggroRaw
                value20 = value17.openingRaw
                value17 = value17.winLossRaw
            else
                value3(value15.reachAdjust)
                value15 = value17
                if value17 then
                    value18 = value17.aggroRaw
                    value20 = value17.openingRaw
                    value17 = value17.winLossRaw
                else
                    value18 = value17
                    if value17 then
                        value20 = value17.openingRaw
                        value17 = value17.winLossRaw
                    else
                        value20 = value17
                        if value17 then
                            value17 = value17.winLossRaw
                        end
                    end
                end
            end
            value11 = globals.pairs
            value12 = value2
            value11, value12, value13 = value11(value12)
            loop = {parent = loop, iterator = iterateValues(value11, value12, value13)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value12, value13 = tmp_key, tmp_value
                end
                if loopContinues then
                    value21 = captures.slot12[value12]
                    if (not value21) then
                        tmp_X = captures.slot13
                        value21 = readCell(tmp_X)(value12)
                    end
                    if value17 then
                        value3 = value17[value12]
                        value8 = value21.wl
                        if value3 then
                            value7 = globals.string.format
                            value5 = value3.wins
                            value6 = value3.losses
                            value4 = "%d-%d"
                            value3 = value7
                            value3 = value3(value4, value5, value6)
                            if (not value3) then
                                value3 = ""
                            end
                        else
                            value3 = ""
                        end
                    else
                        value8 = value21.wl
                        value3 = ""
                    end
                    value8.Text = value3
                    tmp_X = captures.slot14
                    value3 = readCell(tmp_X)
                    value4 = value21.agStyle
                    value5 = value21.agStat
                    if value18 then
                        value6 = value18[value12]
                    else
                        value6 = value18
                    end
                    value7 = captures.slot15
                    tmp_X = captures.slot16
                    value8 = readCell(tmp_X)
                    value3(value4, value5, value6, value7, value8)
                    tmp_X = captures.slot14
                    value3 = readCell(tmp_X)
                    value4 = value21.llStyle
                    value5 = value21.llStat
                    if value15 then
                        value6 = value15[value12]
                    else
                        value6 = value15
                    end
                    value7 = captures.slot17
                    tmp_X = captures.slot18
                    value8 = readCell(tmp_X)
                    value3(value4, value5, value6, value7, value8)
                    tmp_X = captures.slot14
                    value3 = readCell(tmp_X)
                    value4 = value21.opStyle
                    value5 = value21.opStat
                    if value20 then
                        value6 = value20[value12]
                    else
                        value6 = value20
                    end
                    value7 = captures.slot19
                    tmp_X = captures.slot20
                    value8 = readCell(tmp_X)
                    value3(value4, value5, value6, value7, value8)
                    if value15 then
                        value4 = value15[value12]
                        if value4 then
                            value3 = value4.uses
                            if value3 then
                                value3 = (value4.uses > 0)
                                if value3 then
                                    value6 = value21.llStat
                                    value8 = value21.llStat.Text
                                    value3 = globals.string.format
                                    value5 = value4.uses
                                    value4 = "   \194\183 baited %d"
                                    value3 = (value8 .. (value3(value4, value5)))
                                    value6.Text = value3
                                end
                            end
                        else
        
                        end
                    else
        
                    end
                    tmp_X = captures.slot21
                    value3 = readCell(tmp_X)
                    value4 = value12
                    value3, value4, value5 = value3(value4)
                    value6 = (value4 ~= 0)
                    if value6 then
                        value9 = globals.string.format
                        value7 = " (%+.1f)"
                        value6 = value9
                        value8 = value4
                        value6 = value6(value7, value8)
                        if (not value6) then
                            value6 = ""
                        end
                    else
                        value6 = ""
                    end
                    value23 = value21.reach
                    value10 = globals.string.format
                    value14 = "R %.2f \194\183n%d%s"
                    value7 = value3
                    value8 = value5
                    value9 = value6
                    value5 = value10
                    value6 = value14
                    value5 = value5(value6, value7, value8, value9)
                    value23.Text = value5
                    value3 = value21.reach
                    value4 = (value4 ~= 0)
                    if value4 then
                        value4 = captures.slot6.accent
                        if (not value4) then
                            value4 = captures.slot6.subtext
                        end
                    else
                        value4 = captures.slot6.subtext
                    end
                    value3.TextColor3 = value4
                    continue
                else
                    break
                end
            end
            loop = loop.parent
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_407 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4

        value4 = captures.slot1
        value4 = value4[("Arena" .. captures.slot3)].Slots[captures.slot4][(globals.tostring(captures.slot5))]
        tmp_X = captures.slot6
        writeCell(tmp_X, value4)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.navigateKevin = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_I, tmp_X, tmp_cache_r, tmp_n, value1, value3, value5, value7, value8, value9, value10, value11, value12, value13, value14, value15, value16, value17, value18, value19, value20, value21, value22, value23, value24, value25, value26, value27, value28, value29, value30, value32, value33
        local sharedPath_146, sharedPath_201, sharedPath_283

        sharedPath_146 = function(...)
            if value14 then
                value1 = globals.tick()
                tmp_X = captures.lastPositionAtCell
                value14 = (value1 - (readCell(tmp_X)))
                if (value14 > 0.001) then
                    if (value14 < 0.5) then
                        tmp_X = captures.velocityCell
                        value23 = readCell(tmp_X)
                        value1 = value23.Lerp
                        tmp_X = captures.lastPositionCell
                        value24 = ((value3 - (readCell(tmp_X))) / value14)
                        value25 = 0.35
                        value22 = value1
                        value22 = value22(value23, value24, value25)
                        tmp_X = captures.velocityCell
                        writeCell(tmp_X, value22)
                    end
                end
            end
            tmp_X = captures.lastPositionCell
            writeCell(tmp_X, value3)
            value1 = globals.tick()
            tmp_X = captures.lastPositionAtCell
            writeCell(tmp_X, value1)
            tmp_X = captures.castProbeCell
            value25 = (readCell(tmp_X))
            value26 = value8
            value27 = value9
            value28 = value10
            value3 = (value25(value26, value27, value28))
            if value21 then
                value21 = (not value13)
                if value21 then
                    value21 = (value12 <= (11))
                    if value21 then
                        value1 = globals.tick()
                        tmp_X = captures.blockedUntilCell
                        value21 = (value1 >= (readCell(tmp_X)))
                        value33 = false
                        if value21 then
                            tmp_X = captures.castProbeCell
                            value24 = readCell(tmp_X)
                            value25 = value8
                            value26 = value11
                            value27 = value12
                            value24, value25 = value24(value25, value26, value27)
                            value1 = (value24 < value12)
                            if value1 then
                                value1 = value25
                                value33 = false
                                if value1 then
                                    value12 = ((value12 - value24) + 0.5)
                                    value33 = false
                                    if (value12 <= 5) then
                                        tmp_X = captures.horizontalVectorCell
                                        value1 = readCell(tmp_X)(value25)
                                        value14 = (value1.Magnitude > 0)
                                        if value14 then
                                            value14 = value1.Unit
                                            if (not value14) then
                                                value14 = value11
                                            end
                                        else
                                            value14 = value11
                                        end
                                        value23 = globals.Vector3.new
                                        value24 = (- value14.Z)
                                        value26 = value14.X
                                        value25 = 0
                                        value23 = value23(value24, value25, value26)
                                        value14 = globals.math.abs
                                        tmp_X = captures.horizontalVectorCell
                                        value22 = readCell(tmp_X)((value32.Position - value8))
                                        value21 = value22.Dot
                                        value21 = table.pack(value21(table.unpack({[22] = value22, [23] = value23}, 22, 23)))
                                        value1 = value14(table.unpack(value21, 1, value21.n))
                                        value14 = globals.math.sqrt(((value12 * value12) + (value1 * value1)))
                                        value23 = value19
                                        value1 = value23.FindFirstChild
                                        value24 = "Humanoid"
                                        value22 = value1
                                        value22 = value22(value23, value24)
                                        if value22 then
                                            value1 = (value22.WalkSpeed > 0)
                                            if value1 then
                                                value1 = value22.WalkSpeed
                                                if (not value1) then
                                                    value1 = 16
                                                end
                                            else
                                                value1 = 16
                                            end
                                        else
                                            value1 = 16
                                        end
                                        value1 = ((4.03553390593 - value12) / value1)
                                        value26 = globals.math.max
                                        value28 = (value14 - (4.03553390593))
                                        value27 = 0
                                        value14 = ((value26(value27, value28)) / 2)
                                        value12 = (value12 < (4.03553390593))
                                        if value12 then
                                            value12 = ((value14 + 0.15) <= value1)
                                            value33 = false
                                            if value12 then
                                                value33 = true
                                            end
                                        else
                                            value33 = false
                                        end
                                    end
                                end
                            else
                                value33 = false
                            end
                        end
                    else
                        value33 = false
                    end
                else
                    value33 = false
                end
            else
                value33 = false
            end
            if value33 then
                tmp_X = captures.wallContactSinceCell
                value1 = readCell(tmp_X)
                if (value1 == (0)) then
                    value1 = globals.tick()
                    tmp_X = captures.wallContactSinceCell
                    writeCell(tmp_X, value1)
                end
                return sharedPath_201(...)
            else
                value1 = 0
                tmp_X = captures.wallContactSinceCell
                writeCell(tmp_X, value1)
                value1 = (value3 >= value10)
                if value1 then
                    if value13 then
                        captures.debugState.navMode = "direct"
                        value1 = 0
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, value1)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, nil)
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value9)
                        captures.destinationMarker.Position = value16
                        value22 = value5
                        value22.MoveTo(value22, value16)
                    else
                        captures.debugState.navMode = "around"
                        tmp_X = captures.lastCharacterCell
                        if (value19 ~= (readCell(tmp_X))) then
                            tmp_X = captures.committedAtCell
                            writeCell(tmp_X, 0)
                            tmp_X = captures.committedPositionCell
                            writeCell(tmp_X, nil)
                        end
                        tmp_X = captures.findPathCell
                        value13 = readCell(tmp_X)
                        value14 = value8
                        value15 = value16
                        value13, value14, value15 = value13(value14, value15)
                        if (not value15) then
                            value15 = value16
                        end
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, 0)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, value15)
                        tmp_X = captures.horizontalVectorCell
                        value1 = readCell(tmp_X)((value15 - value8))
                        value29 = (value1.Magnitude > 0.5)
                        if value29 then
                            value29 = value1.Unit
                            if (not value29) then
                                value29 = value9
                            end
                        else
                            value29 = value9
                        end
                        value3 = captures.debugState
                        if value14 then
                            value14 = "graph-los"
                        else
                            value14 = "graph"
                        end
                        value3.navMode = value14
                        if captures.showRays then
                            tmp_X = captures.drawRayCell
                            value22 = readCell(tmp_X)
                            value25 = globals.Color3.new
                            value26 = 1
                            value27 = 1
                            value28 = 1
                            value25 = value25(value26, value27, value28)
                            value26 = 0.1
                            value23 = value8
                            value24 = value15
                            value22(value23, value24, value25, value26)
                        end
                        tmp_X = captures.steerDirectionCell
                        if (readCell(tmp_X).Magnitude < 0.01) then
                            tmp_X = captures.steerDirectionCell
                            writeCell(tmp_X, value29)
                        end
                        value3 = captures.humanization.ON
                        if value3 then
                            value3 = (captures.humanization.ANTIJITTER > 0)
                            if value3 then
                                value3 = (value29.Magnitude > 0.001)
                                if value3 then
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (readCell(tmp_X).Magnitude > 0.001)
                                    value30 = 0.7
                                    if value3 then
                                        tmp_X = captures.steerDirectionCell
                                        value3 = (readCell(tmp_X).X * value29.Z)
                                        tmp_X = captures.steerDirectionCell
                                        value3 = (value3 - (readCell(tmp_X).Z * value29.X))
                                        value9 = globals.math.abs(value3)
                                        value9 = (value9 > (0.08))
                                        if value9 then
                                            value9 = (value3 > 0)
                                            if value9 then
                                                value9 = 1
                                                if (not value9) then
                                                    value9 = (- 1)
                                                    if (not value9) then
                                                        value9 = 0
                                                    end
                                                end
                                            else
                                                value9 = (- 1)
                                                if (not value9) then
                                                    value9 = 0
                                                end
                                            end
                                        else
                                            value9 = 0
                                        end
                                        value3 = (value9 ~= (0))
                                        if value3 then
                                            value3 = (captures.humanization.lastTurnSign ~= 0)
                                            if value3 then
                                                value3 = (value9 ~= captures.humanization.lastTurnSign)
                                                if value3 then
                                                    value3 = captures.humanization
                                                    value26 = globals.math.min
                                                    value28 = (captures.humanization.oscScore + 0.34)
                                                    value27 = 1
                                                    value26 = value26(value27, value28)
                                                    value3.oscScore = value26
                                                else
                                                    value3 = captures.humanization
                                                    value26 = globals.math.max
                                                    value27 = 0
                                                    value28 = (captures.humanization.oscScore - 0.16)
                                                    value26 = value26(value27, value28)
                                                    value3.oscScore = value26
                                                end
                                            else
                                                value3 = captures.humanization
                                                value26 = globals.math.max
                                                value27 = 0
                                                value28 = (captures.humanization.oscScore - 0.16)
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            end
                                        else
                                            value3 = captures.humanization
                                            value26 = globals.math.max
                                            value27 = 0
                                            value28 = (captures.humanization.oscScore - 0.16)
                                            value26 = value26(value27, value28)
                                            value3.oscScore = value26
                                        end
                                        if (value9 ~= (0)) then
                                            captures.humanization.lastTurnSign = value9
                                        end
                                        value30 = (0.7 * ((1) - (captures.humanization.ANTIJITTER * captures.humanization.oscScore)))
                                    end
                                else
                                    value30 = 0.7
                                end
                            else
                                value30 = 0.7
                            end
                        else
                            value30 = 0.7
                        end
                        tmp_X = captures.steerDirectionCell
                        value28 = readCell(tmp_X)
                        value27 = value28.Lerp
                        value27 = value27(value28, value29, value30)
                        value1 = (value27.Magnitude > 0)
                        if value1 then
                            value1 = value27.Unit
                            if value1 then
                                value29 = value1
                            end
                        end
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value29)
                        tmp_X = captures.castProbeCell
                        value27 = readCell(tmp_X)
                        value30 = 12
                        value28 = value8
                        value27 = value27(value28, value29, value30)
                        value23 = globals.math.max
                        value24 = 1
                        value25 = globals.math.min
                        value27 = (value27 - (0.2))
                        value26 = 12
                        tmp_n = table.pack(value25(table.unpack({[26] = value26, [27] = value27}, 26, 27)))
                        tmp_I = tmp_n.n
                        tmp_cache_r = ((2 + tmp_I) - 1)
                        tmp_n.n = tmp_cache_r
                        table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                        table.move({[24] = value24}, 24, 24, 1, tmp_n)
                        tmp_I = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
                        value23 = rawget(tmp_I, 1)
                        value1 = captures.destinationMarker
                        value9 = (value8 + (value29 * value23))
                        value1.Position = value9
                        value22 = value5
                        value22.MoveTo(value22, (value8 + (value29 * value23)))
                    end
                else
                    captures.debugState.navMode = "around"
                    tmp_X = captures.lastCharacterCell
                    if (value19 ~= (readCell(tmp_X))) then
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, 0)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, nil)
                    end
                    tmp_X = captures.findPathCell
                    value13 = readCell(tmp_X)
                    value14 = value8
                    value15 = value16
                    value13, value14, value15 = value13(value14, value15)
                    if (not value15) then
                        value15 = value16
                    end
                    tmp_X = captures.committedAtCell
                    writeCell(tmp_X, 0)
                    tmp_X = captures.committedPositionCell
                    writeCell(tmp_X, value15)
                    tmp_X = captures.horizontalVectorCell
                    value1 = readCell(tmp_X)((value15 - value8))
                    value29 = (value1.Magnitude > 0.5)
                    if value29 then
                        value29 = value1.Unit
                        if (not value29) then
                            value29 = value9
                        end
                    else
                        value29 = value9
                    end
                    value3 = captures.debugState
                    if value14 then
                        value14 = "graph-los"
                    else
                        value14 = "graph"
                    end
                    value3.navMode = value14
                    if captures.showRays then
                        tmp_X = captures.drawRayCell
                        value22 = readCell(tmp_X)
                        value25 = globals.Color3.new
                        value26 = 1
                        value27 = 1
                        value28 = 1
                        value25 = value25(value26, value27, value28)
                        value26 = 0.1
                        value23 = value8
                        value24 = value15
                        value22(value23, value24, value25, value26)
                    end
                    tmp_X = captures.steerDirectionCell
                    if (readCell(tmp_X).Magnitude < 0.01) then
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value29)
                    end
                    value3 = captures.humanization.ON
                    if value3 then
                        value3 = (captures.humanization.ANTIJITTER > 0)
                        if value3 then
                            value3 = (value29.Magnitude > 0.001)
                            if value3 then
                                tmp_X = captures.steerDirectionCell
                                value3 = (readCell(tmp_X).Magnitude > 0.001)
                                value30 = 0.7
                                if value3 then
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (readCell(tmp_X).X * value29.Z)
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (value3 - (readCell(tmp_X).Z * value29.X))
                                    value9 = globals.math.abs(value3)
                                    value9 = (value9 > (0.08))
                                    if value9 then
                                        value9 = (value3 > 0)
                                        if value9 then
                                            value9 = 1
                                            if (not value9) then
                                                value9 = (- 1)
                                                if (not value9) then
                                                    value9 = 0
                                                end
                                            end
                                        else
                                            value9 = (- 1)
                                            if (not value9) then
                                                value9 = 0
                                            end
                                        end
                                    else
                                        value9 = 0
                                    end
                                    value3 = (value9 ~= (0))
                                    if value3 then
                                        value3 = (captures.humanization.lastTurnSign ~= 0)
                                        if value3 then
                                            value3 = (value9 ~= captures.humanization.lastTurnSign)
                                            if value3 then
                                                value3 = captures.humanization
                                                value26 = globals.math.min
                                                value28 = (captures.humanization.oscScore + 0.34)
                                                value27 = 1
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            else
                                                value3 = captures.humanization
                                                value26 = globals.math.max
                                                value27 = 0
                                                value28 = (captures.humanization.oscScore - 0.16)
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            end
                                        else
                                            value3 = captures.humanization
                                            value26 = globals.math.max
                                            value27 = 0
                                            value28 = (captures.humanization.oscScore - 0.16)
                                            value26 = value26(value27, value28)
                                            value3.oscScore = value26
                                        end
                                    else
                                        value3 = captures.humanization
                                        value26 = globals.math.max
                                        value27 = 0
                                        value28 = (captures.humanization.oscScore - 0.16)
                                        value26 = value26(value27, value28)
                                        value3.oscScore = value26
                                    end
                                    if (value9 ~= (0)) then
                                        captures.humanization.lastTurnSign = value9
                                    end
                                    value30 = (0.7 * ((1) - (captures.humanization.ANTIJITTER * captures.humanization.oscScore)))
                                end
                            else
                                value30 = 0.7
                            end
                        else
                            value30 = 0.7
                        end
                    else
                        value30 = 0.7
                    end
                    tmp_X = captures.steerDirectionCell
                    value28 = readCell(tmp_X)
                    value27 = value28.Lerp
                    value27 = value27(value28, value29, value30)
                    value1 = (value27.Magnitude > 0)
                    if value1 then
                        value1 = value27.Unit
                        if value1 then
                            value29 = value1
                        end
                    end
                    tmp_X = captures.steerDirectionCell
                    writeCell(tmp_X, value29)
                    tmp_X = captures.castProbeCell
                    value27 = readCell(tmp_X)
                    value30 = 12
                    value28 = value8
                    value27 = value27(value28, value29, value30)
                    value23 = globals.math.max
                    value24 = 1
                    value25 = globals.math.min
                    value27 = (value27 - (0.2))
                    value26 = 12
                    tmp_n = table.pack(value25(table.unpack({[26] = value26, [27] = value27}, 26, 27)))
                    tmp_I = tmp_n.n
                    tmp_cache_r = ((2 + tmp_I) - 1)
                    tmp_n.n = tmp_cache_r
                    table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                    table.move({[24] = value24}, 24, 24, 1, tmp_n)
                    tmp_I = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
                    value23 = rawget(tmp_I, 1)
                    value1 = captures.destinationMarker
                    value9 = (value8 + (value29 * value23))
                    value1.Position = value9
                    value22 = value5
                    value22.MoveTo(value22, (value8 + (value29 * value23)))
                end
                return sharedPath_283(...)
            end
            return
        end

        sharedPath_201 = function(...)
            value1 = globals.tick()
            tmp_X = captures.wallContactSinceCell
            value1 = (value1 - (readCell(tmp_X)))
            value1 = (value1 > (0.8))
            if value1 then
                value1 = ((globals.tick()) + 1)
                tmp_X = captures.blockedUntilCell
                writeCell(tmp_X, value1)
                tmp_X = captures.wallContactSinceCell
                writeCell(tmp_X, 0)
                value33 = false
            end
            if value33 then
                captures.debugState.navMode = "wall-tag"
                value1 = 0
                tmp_X = captures.committedAtCell
                writeCell(tmp_X, value1)
                tmp_X = captures.committedPositionCell
                writeCell(tmp_X, nil)
                tmp_X = captures.steerDirectionCell
                writeCell(tmp_X, value11)
                tmp_X = captures.castProbeCell
                value12 = readCell(tmp_X)
                value15 = 12
                value13 = value8
                value14 = value11
                value12 = value12(value13, value14, value15)
                value23 = globals.math.min
                value24 = 12
                value25 = globals.math.max
                value27 = (value12 - (0.1))
                value26 = 0.5
                tmp_n = table.pack(value25(table.unpack({[26] = value26, [27] = value27}, 26, 27)))
                tmp_I = tmp_n.n
                tmp_cache_r = ((2 + tmp_I) - 1)
                tmp_n.n = tmp_cache_r
                table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                table.move({[24] = value24}, 24, 24, 1, tmp_n)
                tmp_D = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
                value23 = rawget(tmp_D, 1)
                value1 = captures.destinationMarker
                value9 = (value8 + (value11 * value23))
                value1.Position = value9
                value22 = value5
                value22.MoveTo(value22, (value8 + (value11 * value23)))
                tmp_X = captures.lastCharacterCell
                writeCell(tmp_X, value19)
                tmp_X = captures.steeringModeCell
                writeCell(tmp_X, nil)
                if (value17 == true) then
                    value3 = true
                    value5.AutoRotate = value3
                else
                    value5.AutoRotate = false
                    value1 = globals.typeof(value17)
                    value1 = (value1 == "CFrame")
                    if value1 then
                        if (not value17) then
                            value1 = globals.CFrame.lookAt
                            value13 = (value8 + value11)
                            value11 = value1
                            value12 = value8
                            value17 = (value11(value12, value13))
                        end
                    else
                        value1 = globals.CFrame.lookAt
                        value13 = (value8 + value11)
                        value11 = value1
                        value12 = value8
                        value17 = (value11(value12, value13))
                    end
                    value7.CFrame = value17
                end
            else
                value1 = (value3 >= value10)
                if value1 then
                    if value13 then
                        captures.debugState.navMode = "direct"
                        value1 = 0
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, value1)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, nil)
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value9)
                        captures.destinationMarker.Position = value16
                        value22 = value5
                        value22.MoveTo(value22, value16)
                    else
                        captures.debugState.navMode = "around"
                        tmp_X = captures.lastCharacterCell
                        if (value19 ~= (readCell(tmp_X))) then
                            tmp_X = captures.committedAtCell
                            writeCell(tmp_X, 0)
                            tmp_X = captures.committedPositionCell
                            writeCell(tmp_X, nil)
                        end
                        tmp_X = captures.findPathCell
                        value13 = readCell(tmp_X)
                        value14 = value8
                        value15 = value16
                        value13, value14, value15 = value13(value14, value15)
                        if (not value15) then
                            value15 = value16
                        end
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, 0)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, value15)
                        tmp_X = captures.horizontalVectorCell
                        value1 = readCell(tmp_X)((value15 - value8))
                        value29 = (value1.Magnitude > 0.5)
                        if value29 then
                            value29 = value1.Unit
                            if (not value29) then
                                value29 = value9
                            end
                        else
                            value29 = value9
                        end
                        value3 = captures.debugState
                        if value14 then
                            value14 = "graph-los"
                        else
                            value14 = "graph"
                        end
                        value3.navMode = value14
                        if captures.showRays then
                            tmp_X = captures.drawRayCell
                            value22 = readCell(tmp_X)
                            value25 = globals.Color3.new
                            value26 = 1
                            value27 = 1
                            value28 = 1
                            value25 = value25(value26, value27, value28)
                            value26 = 0.1
                            value23 = value8
                            value24 = value15
                            value22(value23, value24, value25, value26)
                        end
                        tmp_X = captures.steerDirectionCell
                        if (readCell(tmp_X).Magnitude < 0.01) then
                            tmp_X = captures.steerDirectionCell
                            writeCell(tmp_X, value29)
                        end
                        value3 = captures.humanization.ON
                        if value3 then
                            value3 = (captures.humanization.ANTIJITTER > 0)
                            if value3 then
                                value3 = (value29.Magnitude > 0.001)
                                if value3 then
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (readCell(tmp_X).Magnitude > 0.001)
                                    value30 = 0.7
                                    if value3 then
                                        tmp_X = captures.steerDirectionCell
                                        value3 = (readCell(tmp_X).X * value29.Z)
                                        tmp_X = captures.steerDirectionCell
                                        value3 = (value3 - (readCell(tmp_X).Z * value29.X))
                                        value9 = globals.math.abs(value3)
                                        value9 = (value9 > (0.08))
                                        if value9 then
                                            value9 = (value3 > 0)
                                            if value9 then
                                                value9 = 1
                                                if (not value9) then
                                                    value9 = (- 1)
                                                    if (not value9) then
                                                        value9 = 0
                                                    end
                                                end
                                            else
                                                value9 = (- 1)
                                                if (not value9) then
                                                    value9 = 0
                                                end
                                            end
                                        else
                                            value9 = 0
                                        end
                                        value3 = (value9 ~= (0))
                                        if value3 then
                                            value3 = (captures.humanization.lastTurnSign ~= 0)
                                            if value3 then
                                                value3 = (value9 ~= captures.humanization.lastTurnSign)
                                                if value3 then
                                                    value3 = captures.humanization
                                                    value26 = globals.math.min
                                                    value28 = (captures.humanization.oscScore + 0.34)
                                                    value27 = 1
                                                    value26 = value26(value27, value28)
                                                    value3.oscScore = value26
                                                else
                                                    value3 = captures.humanization
                                                    value26 = globals.math.max
                                                    value27 = 0
                                                    value28 = (captures.humanization.oscScore - 0.16)
                                                    value26 = value26(value27, value28)
                                                    value3.oscScore = value26
                                                end
                                            else
                                                value3 = captures.humanization
                                                value26 = globals.math.max
                                                value27 = 0
                                                value28 = (captures.humanization.oscScore - 0.16)
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            end
                                        else
                                            value3 = captures.humanization
                                            value26 = globals.math.max
                                            value27 = 0
                                            value28 = (captures.humanization.oscScore - 0.16)
                                            value26 = value26(value27, value28)
                                            value3.oscScore = value26
                                        end
                                        if (value9 ~= (0)) then
                                            captures.humanization.lastTurnSign = value9
                                        end
                                        value30 = (0.7 * ((1) - (captures.humanization.ANTIJITTER * captures.humanization.oscScore)))
                                    end
                                else
                                    value30 = 0.7
                                end
                            else
                                value30 = 0.7
                            end
                        else
                            value30 = 0.7
                        end
                        tmp_X = captures.steerDirectionCell
                        value28 = readCell(tmp_X)
                        value27 = value28.Lerp
                        value27 = value27(value28, value29, value30)
                        value1 = (value27.Magnitude > 0)
                        if value1 then
                            value1 = value27.Unit
                            if value1 then
                                value29 = value1
                            end
                        end
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value29)
                        tmp_X = captures.castProbeCell
                        value27 = readCell(tmp_X)
                        value30 = 12
                        value28 = value8
                        value27 = value27(value28, value29, value30)
                        value23 = globals.math.max
                        value24 = 1
                        value25 = globals.math.min
                        value27 = (value27 - (0.2))
                        value26 = 12
                        tmp_n = table.pack(value25(table.unpack({[26] = value26, [27] = value27}, 26, 27)))
                        tmp_I = tmp_n.n
                        tmp_cache_r = ((2 + tmp_I) - 1)
                        tmp_n.n = tmp_cache_r
                        table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                        table.move({[24] = value24}, 24, 24, 1, tmp_n)
                        tmp_I = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
                        value23 = rawget(tmp_I, 1)
                        value1 = captures.destinationMarker
                        value9 = (value8 + (value29 * value23))
                        value1.Position = value9
                        value22 = value5
                        value22.MoveTo(value22, (value8 + (value29 * value23)))
                    end
                else
                    captures.debugState.navMode = "around"
                    tmp_X = captures.lastCharacterCell
                    if (value19 ~= (readCell(tmp_X))) then
                        tmp_X = captures.committedAtCell
                        writeCell(tmp_X, 0)
                        tmp_X = captures.committedPositionCell
                        writeCell(tmp_X, nil)
                    end
                    tmp_X = captures.findPathCell
                    value13 = readCell(tmp_X)
                    value14 = value8
                    value15 = value16
                    value13, value14, value15 = value13(value14, value15)
                    if (not value15) then
                        value15 = value16
                    end
                    tmp_X = captures.committedAtCell
                    writeCell(tmp_X, 0)
                    tmp_X = captures.committedPositionCell
                    writeCell(tmp_X, value15)
                    tmp_X = captures.horizontalVectorCell
                    value1 = readCell(tmp_X)((value15 - value8))
                    value29 = (value1.Magnitude > 0.5)
                    if value29 then
                        value29 = value1.Unit
                        if (not value29) then
                            value29 = value9
                        end
                    else
                        value29 = value9
                    end
                    value3 = captures.debugState
                    if value14 then
                        value14 = "graph-los"
                    else
                        value14 = "graph"
                    end
                    value3.navMode = value14
                    if captures.showRays then
                        tmp_X = captures.drawRayCell
                        value22 = readCell(tmp_X)
                        value25 = globals.Color3.new
                        value26 = 1
                        value27 = 1
                        value28 = 1
                        value25 = value25(value26, value27, value28)
                        value26 = 0.1
                        value23 = value8
                        value24 = value15
                        value22(value23, value24, value25, value26)
                    end
                    tmp_X = captures.steerDirectionCell
                    if (readCell(tmp_X).Magnitude < 0.01) then
                        tmp_X = captures.steerDirectionCell
                        writeCell(tmp_X, value29)
                    end
                    value3 = captures.humanization.ON
                    if value3 then
                        value3 = (captures.humanization.ANTIJITTER > 0)
                        if value3 then
                            value3 = (value29.Magnitude > 0.001)
                            if value3 then
                                tmp_X = captures.steerDirectionCell
                                value3 = (readCell(tmp_X).Magnitude > 0.001)
                                value30 = 0.7
                                if value3 then
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (readCell(tmp_X).X * value29.Z)
                                    tmp_X = captures.steerDirectionCell
                                    value3 = (value3 - (readCell(tmp_X).Z * value29.X))
                                    value9 = globals.math.abs(value3)
                                    value9 = (value9 > (0.08))
                                    if value9 then
                                        value9 = (value3 > 0)
                                        if value9 then
                                            value9 = 1
                                            if (not value9) then
                                                value9 = (- 1)
                                                if (not value9) then
                                                    value9 = 0
                                                end
                                            end
                                        else
                                            value9 = (- 1)
                                            if (not value9) then
                                                value9 = 0
                                            end
                                        end
                                    else
                                        value9 = 0
                                    end
                                    value3 = (value9 ~= (0))
                                    if value3 then
                                        value3 = (captures.humanization.lastTurnSign ~= 0)
                                        if value3 then
                                            value3 = (value9 ~= captures.humanization.lastTurnSign)
                                            if value3 then
                                                value3 = captures.humanization
                                                value26 = globals.math.min
                                                value28 = (captures.humanization.oscScore + 0.34)
                                                value27 = 1
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            else
                                                value3 = captures.humanization
                                                value26 = globals.math.max
                                                value27 = 0
                                                value28 = (captures.humanization.oscScore - 0.16)
                                                value26 = value26(value27, value28)
                                                value3.oscScore = value26
                                            end
                                        else
                                            value3 = captures.humanization
                                            value26 = globals.math.max
                                            value27 = 0
                                            value28 = (captures.humanization.oscScore - 0.16)
                                            value26 = value26(value27, value28)
                                            value3.oscScore = value26
                                        end
                                    else
                                        value3 = captures.humanization
                                        value26 = globals.math.max
                                        value27 = 0
                                        value28 = (captures.humanization.oscScore - 0.16)
                                        value26 = value26(value27, value28)
                                        value3.oscScore = value26
                                    end
                                    if (value9 ~= (0)) then
                                        captures.humanization.lastTurnSign = value9
                                    end
                                    value30 = (0.7 * ((1) - (captures.humanization.ANTIJITTER * captures.humanization.oscScore)))
                                end
                            else
                                value30 = 0.7
                            end
                        else
                            value30 = 0.7
                        end
                    else
                        value30 = 0.7
                    end
                    tmp_X = captures.steerDirectionCell
                    value28 = readCell(tmp_X)
                    value27 = value28.Lerp
                    value27 = value27(value28, value29, value30)
                    value1 = (value27.Magnitude > 0)
                    if value1 then
                        value1 = value27.Unit
                        if value1 then
                            value29 = value1
                        end
                    end
                    tmp_X = captures.steerDirectionCell
                    writeCell(tmp_X, value29)
                    tmp_X = captures.castProbeCell
                    value27 = readCell(tmp_X)
                    value30 = 12
                    value28 = value8
                    value27 = value27(value28, value29, value30)
                    value23 = globals.math.max
                    value24 = 1
                    value25 = globals.math.min
                    value27 = (value27 - (0.2))
                    value26 = 12
                    tmp_n = table.pack(value25(table.unpack({[26] = value26, [27] = value27}, 26, 27)))
                    tmp_I = tmp_n.n
                    tmp_cache_r = ((2 + tmp_I) - 1)
                    tmp_n.n = tmp_cache_r
                    table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                    table.move({[24] = value24}, 24, 24, 1, tmp_n)
                    tmp_I = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
                    value23 = rawget(tmp_I, 1)
                    value1 = captures.destinationMarker
                    value9 = (value8 + (value29 * value23))
                    value1.Position = value9
                    value22 = value5
                    value22.MoveTo(value22, (value8 + (value29 * value23)))
                end
                return sharedPath_283(...)
            end
            return
        end

        sharedPath_283 = function(...)
            tmp_X = captures.lastCharacterCell
            writeCell(tmp_X, value19)
            if value33 then
                tmp_X = captures.steeringModeCell
                writeCell(tmp_X, nil)
                if (value17 == true) then
                    value3 = true
                    value5.AutoRotate = value3
                else
                    value5.AutoRotate = false
                    value1 = globals.typeof(value17)
                    value1 = (value1 == "CFrame")
                    if value1 then
                        if (not value17) then
                            value1 = globals.CFrame.lookAt
                            value13 = (value8 + value11)
                            value11 = value1
                            value12 = value8
                            value17 = (value11(value12, value13))
                        end
                    else
                        value1 = globals.CFrame.lookAt
                        value13 = (value8 + value11)
                        value11 = value1
                        value12 = value8
                        value17 = (value11(value12, value13))
                    end
                    value7.CFrame = value17
                end
            else
                value1 = (value10 > value18)
                value14 = false
                if value1 then
                    value27 = 0
                    value28 = 337.5
                    value29 = 22.5
                    value1 = 1.25
                    value3 = nil
                    loop = {parent = loop, index = (value27 - value29), limit = value28, step = value29}
                    while true do
                        loop.index += loop.step
                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                        if loopContinues then
                            value9 = loop.index
                        end
                        if loopContinues then
                            value26 = globals.CFrame.Angles
                            value28 = globals.math.rad(value9)
                            value29 = 0
                            value27 = 0
                            value12 = (value26(value27, value28, value29)).LookVector
                            tmp_X = captures.castProbeCell
                            value10 = readCell(tmp_X)
                            value13 = 1.25
                            value11 = value8
                            value10, value11 = value10(value11, value12, value13)
                            if value11 then
                                value9 = (value10 < value1)
                                if value9 then
                                    value1 = value10
                                    value3 = value11
                                    continue
                                else
                                    continue
                                end
                            else
                                value9 = value11
                                continue
                            end
                        else
                            break
                        end
                    end
                    loop = loop.parent
                    if value3 then
                        value1 = (value20 == true)
                        value14 = false
                        if value1 then
                            captures.humanization.slideNow = true
                            value1 = captures.humanization
                            value10 = ((globals.tick()) + 0.18)
                            value1.slideUntil = value10
                            value9 = false
                            value5.AutoRotate = value9
                            value26 = globals.Vector3.new
                            value27 = value3.X
                            value29 = value3.Z
                            value28 = 0
                            value1 = (value26(value27, value28, value29)).Unit
                            value24 = globals.Vector3.new
                            value25 = (- value1.Z)
                            value27 = value1.X
                            value26 = 0
                            value1 = (value24(value25, value26, value27))
                            tmp_X = captures.steeringModeCell
                            value3 = readCell(tmp_X)
                            if (value3 == nil) then
                                value24 = value1
                                value3 = value24.Dot
                                tmp_X = captures.steerDirectionCell
                                value25 = readCell(tmp_X)
                                value23 = value3
                                value23 = value23(value24, value25)
                                value3 = (value23 > (0))
                                if value3 then
                                    value3 = 1
                                else
                                    value3 = (- 1)
                                end
                                tmp_X = captures.steeringModeCell
                                writeCell(tmp_X, value3)
                            end
                            tmp_X = captures.steeringModeCell
                            value1 = (value1 * (readCell(tmp_X)))
                            value26 = globals.Vector3.new
                            value27 = (- value1.Z)
                            value29 = value1.X
                            value28 = 0
                            value26 = value26(value27, value28, value29)
                            value9 = globals.CFrame.lookAt
                            value11 = (value8 + value26)
                            value10 = value8
                            value9 = value9(value10, value11)
                            value10 = globals.CFrame.lookAt
                            value12 = (value8 - value26)
                            value11 = value8
                            value10 = value10(value11, value12)
                            value26 = globals.Vector3.new
                            value27 = 2.5
                            value28 = 0
                            value29 = 0
                            value26 = value26(value27, value28, value29)
                            value1 = value32.Position
                            value29 = value9
                            value28 = value29.PointToWorldSpace
                            value30 = value26
                            value3 = ((value28(value29, value30)) - value1).Magnitude
                            value29 = value10
                            value28 = value29.PointToWorldSpace
                            value30 = value26
                            if (value3 > ((value28(value29, value30)) - value1).Magnitude) then
                                value7.CFrame = value9
                            else
                                value7.CFrame = value10
                            end
                            value14 = true
                        end
                    else
                        value14 = false
                    end
                end
                value1 = (not value14)
                if value1 then
                    tmp_X = captures.steeringModeCell
                    writeCell(tmp_X, nil)
                    if (value17 == true) then
                        value5.AutoRotate = true
                    else
                        value5.AutoRotate = false
                        value1 = ((globals.typeof(value17)) == "CFrame")
                        if value1 then
                            if (not value17) then
                                value1 = globals.CFrame.lookAt
                                tmp_X = captures.steerDirectionCell
                                value10 = (value8 + (readCell(tmp_X)))
                                value9 = value8
                                value8 = value1
                                value17 = (value8(value9, value10))
                            end
                        else
                            value1 = globals.CFrame.lookAt
                            tmp_X = captures.steerDirectionCell
                            value10 = (value8 + (readCell(tmp_X)))
                            value9 = value8
                            value8 = value1
                            value17 = (value8(value9, value10))
                        end
                        value7.CFrame = value17
                    end
                end
            end
            return
        end

        tmp_X = {...}
        value16, value17, value18, value19, value20, value21 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4), rawget(tmp_X, 5), rawget(tmp_X, 6)
        captures.directionMarker.Position = value16
        value3 = captures.localPlayer.Character
        if value3 then
            value23 = value3
            value1 = value23.FindFirstChild
            value24 = "HumanoidRootPart"
            value22 = value1
            value1 = (value22(value23, value24))
        else
            value1 = value3
        end
        if value3 then
            value23 = value3
            value5 = value23.FindFirstChild
            value24 = "Humanoid"
            value22 = value5
            value5 = (value22(value23, value24))
        else
            value5 = value3
        end
        if value3 then
            value23 = value3
            value7 = value23.FindFirstChild
            value24 = "Torso"
            value22 = value7
            value7 = (value22(value23, value24))
            if (not value7) then
                value23 = value3
                value8 = value23.FindFirstChild
                value24 = "UpperTorso"
                value22 = value8
                value7 = (value22(value23, value24))
            end
        else
            value7 = value3
        end
        value8 = (not value1)
        if value8 then
        else
            value8 = (not value5)
            if value8 then
            else
                value8 = (not value7)
                if value8 then
                else
                    value8 = (not value19)
                    if value8 then
                    else
                        value23 = value19
                        value3 = value23.FindFirstChild
                        value24 = "Torso"
                        value22 = value3
                        value8 = (not (value22(value23, value24)))
                        if value8 then
                        else
                            value8 = value1.Position
                            value32 = value19.Torso
                            captures.targetMarker.Position = value16
                            tmp_X = captures.horizontalVectorCell
                            value1 = readCell(tmp_X)((value16 - value8))
                            value10 = value1.Magnitude
                            value9 = (value10 > (0))
                            if value9 then
                                value9 = value1.Unit
                                if (not value9) then
                                    tmp_X = captures.horizontalVectorCell
                                    value9 = (readCell(tmp_X)(value7.CFrame.LookVector)).Unit
                                end
                            else
                                tmp_X = captures.horizontalVectorCell
                                value9 = (readCell(tmp_X)(value7.CFrame.LookVector)).Unit
                            end
                            value26 = globals.workspace
                            value25 = value26.Raycast
                            value28 = (value32.Position - value8)
                            value29 = captures.raycastParams
                            value27 = value8
                            value25 = value25(value26, value27, value28, value29)
                            if value25 then
                                value25 = value25.Instance
                            end
                            value13 = (not value25)
                            tmp_X = captures.horizontalVectorCell
                            value1 = readCell(tmp_X)((value32.Position - value8))
                            value12 = value1.Magnitude
                            value11 = (value12 > (0))
                            if value11 then
                                value11 = value1.Unit
                                if (not value11) then
                                    value11 = value9
                                end
                            else
                                value11 = value9
                            end
                            tmp_X = captures.horizontalVectorCell
                            value3 = readCell(tmp_X)(value32.Position)
                            tmp_X = captures.lastCharacterCell
                            if ((readCell(tmp_X)) ~= value19) then
                                value25 = globals.Vector3.new
                                value26 = 0
                                value27 = 0
                                value28 = 0
                                value25 = value25(value26, value27, value28)
                                tmp_X = captures.velocityCell
                                writeCell(tmp_X, value25)
                                tmp_X = captures.lastPositionCell
                                writeCell(tmp_X, nil)
                            end
                            tmp_X = captures.lastPositionCell
                            value1 = readCell(tmp_X)
                            tmp_X = captures.lastPositionCell
                            value14 = readCell(tmp_X)
                            if value1 then
                                tmp_X = captures.lastPositionAtCell
                                value14 = readCell(tmp_X)
                            end
                            return sharedPath_146(...)
                        end
                    end
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_415 = function(captures, globals)
    local function recovered(...)
        local R = {}
        local loop, loopContinues, tmp_D, tmp_X

        tmp_X = {...}
        table.move(tmp_X, 1, 2, 30, R)
        R[5] = {}
        R[6] = {}
        R[2] = 1
        R[3] = captures.slot1
        R[4] = 1
        loop = {parent = loop, index = (R[2] - R[4]), limit = R[3], step = R[4]}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                R[2] = loop.index
            end
            if loopContinues then
                R[3] = R[31][R[2]]
                if R[3] then
                    tmp_X = captures.slot2
                    R[4] = readCell(tmp_X)[R[2]]
                    R[4] = (R[4] - R[30])
                    R[3] = R[4].Magnitude
                    if (not R[3]) then
                        R[4] = globals.math
                        R[3] = R[4].huge
                    end
                else
                    R[4] = globals.math
                    R[3] = R[4].huge
                end
                R[5][R[2]] = R[3]
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[28] = 1
        R[29] = captures.slot1
        R[30] = 1
        loop = {parent = loop, index = (R[28] - R[30]), limit = R[29], step = R[30]}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                R[2] = loop.index
            end
            if loopContinues then
                R[2] = globals.math
                R[2] = R[2].huge
                R[28] = 1
                R[29] = captures.slot1
                R[30] = 1
                R[3] = R[0]
                loop = {parent = loop, index = (R[28] - R[30]), limit = R[29], step = R[30]}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        R[4] = loop.index
                    end
                    if loopContinues then
                        R[7] = R[6][R[4]]
                        R[7] = (not R[7])
                        if R[7] then
                            R[8] = R[5][R[4]]
                            R[7] = (R[8] < R[2])
                            if R[7] then
                                R[2] = R[5][R[4]]
                                R[3] = R[4]
                                continue
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                R[2] = (not R[3])
                if R[2] then
                    break
                else
                    writeCell(R, true)
                    R[2] = R[5][R[3]]
                    R[28] = 1
                    R[29] = captures.slot1
                    R[30] = 1
                    loop = {parent = loop, index = (R[28] - R[30]), limit = R[29], step = R[30]}
                    while true do
                        loop.index += loop.step
                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                        if loopContinues then
                            R[4] = loop.index
                        end
                        if loopContinues then
                            R[7] = R[6][R[4]]
                            R[7] = (not R[7])
                            if R[7] then
                                tmp_X = captures.slot3
                                R[8] = readCell(tmp_X)[R[3]]
                                R[7] = R[8][R[4]]
                                if R[7] then
                                    tmp_X = captures.slot2
                                    R[7] = readCell(tmp_X)[R[4]]
                                    tmp_X = captures.slot2
                                    R[8] = readCell(tmp_X)[R[3]]
                                    R[7] = (R[7] - R[8])
                                    R[7] = R[7].Magnitude
                                    R[7] = (R[2] + R[7])
                                    R[8] = R[5][R[4]]
                                    if (not (R[7] < R[8])) then
                                        continue
                                    else
                                        R[5][R[4]] = R[7]
                                        continue
                                    end
                                else
                                    continue
                                end
                            else
                                continue
                            end
                        else
                            break
                        end
                    end
                    loop = loop.parent
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        return R[5]
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_432 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value9

        tmp_X = captures.authReadyCell
        if (not (not (readCell(tmp_X)))) then
            tmp_X = captures.slot2
            value4 = readCell(tmp_X)()
            value9 = (not value4.autoQueue)
            value4.autoQueue = value9
            return
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.refreshNavigation = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, value1, value2, value29, value30, value31, value33

        tmp_X = {...}
        value33 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        if ((readCell(tmp_X)) == 0) then
            tmp_X = captures.slot2
            writeCell(tmp_X, false)
            tmp_X = captures.slot3
            readCell(tmp_X)(value33)
        else
            tmp_X = captures.slot2
            if ((readCell(tmp_X))) then
                tmp_X = captures.slot2
                writeCell(tmp_X, false)
                tmp_X = captures.slot3
                readCell(tmp_X)(value33)
            end
        end
        tmp_X = captures.slot4
        value1 = readCell(tmp_X)(value33)
        tmp_X = captures.slot5
        writeCell(tmp_X, value1)
        value1 = {}
        tmp_X = captures.slot6
        writeCell(tmp_X, value1)
        tmp_X = captures.slot7
        value1 = readCell(tmp_X)
        value30 = (# value1)
        value29 = 1
        value31 = 1
        loop = {parent = loop, index = (value29 - value31), limit = value30, step = value31}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value1 = loop.index
            end
            if loopContinues then
                tmp_X = captures.slot6
                value2 = readCell(tmp_X)
                tmp_X = captures.slot8
                value29 = readCell(tmp_X)
                tmp_X = captures.slot5
                value30 = readCell(tmp_X)
                tmp_X = captures.slot7
                value31 = readCell(tmp_X)[value1]
                value29 = value29(value30, value31)
                value2[value1] = value29
                continue
            else
                break
            end
        end
        loop = loop.parent
        value1 = {}
        tmp_X = captures.slot9
        writeCell(tmp_X, value1)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_468 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value4, value6, value11, value12, value13

        tmp_X = {...}
        value11, value12, value13 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value3 = value11
        value4 = value12
        value2, value3 = value2(value3, value4)
        if value3 then
            return true
        end
        value4 = (value11 - value12).Magnitude
        value6 = (value4 + (0.01))
        if (value2 <= value6) then
            value6 = false
            return value6
        end
        if (not value13) then
            value13 = captures.slot3.wallSlack
        end
        value2 = (value2 <= (value4 + value13))
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_478 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value19, value20, value21, value22, value23, value24

        tmp_X = {...}
        value20, value21, value22 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        tmp_X = captures.slot1
        value1 = ((readCell(tmp_X)) == value23)
        if value1 then
            tmp_X = captures.slot1
            writeCell(tmp_X, value20)
            tmp_X = captures.slot2
            writeCell(tmp_X, value21)
            value3 = false
            tmp_X = captures.slot4
            writeCell(tmp_X, value3)
            tmp_X = captures.slot5
            writeCell(tmp_X, false)
            tmp_X = captures.slot6
            writeCell(tmp_X, value24)
            tmp_X = captures.slot7
            writeCell(tmp_X, false)
        else
            tmp_X = captures.slot2
            value1 = (value21 ~= (readCell(tmp_X)))
            if value1 then
                tmp_X = captures.slot1
                writeCell(tmp_X, value20)
                tmp_X = captures.slot2
                writeCell(tmp_X, value21)
                value3 = false
                tmp_X = captures.slot4
                writeCell(tmp_X, value3)
                tmp_X = captures.slot5
                writeCell(tmp_X, false)
                tmp_X = captures.slot6
                writeCell(tmp_X, value24)
                tmp_X = captures.slot7
                writeCell(tmp_X, false)
            else
                value21 = globals.math.max
                value23 = 0.004166666666666667
                value22 = (40 * (value21(value22, value23)))
                tmp_X = captures.slot1
                value1 = readCell(tmp_X)
                value19 = globals.math.clamp
                tmp_X = captures.slot1
                value20 = (value20 - (readCell(tmp_X)))
                value21 = (- value22)
                value1 = (value1 + (value19(value20, value21, value22)))
                tmp_X = captures.slot1
                writeCell(tmp_X, value1)
            end
        end
        tmp_X = captures.slot1
        value1 = readCell(tmp_X)
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.wiggleAngle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value5, value34, value35

        tmp_X = {...}
        value34, value35 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if (not captures.slot1.ON) then
            return 0
        end
        if (not (captures.slot1.WIGGLEPERIOD > 0)) then
            return 0
        end
        if (not (value35 <= captures.slot1.WIGGLESTART)) then
            return 0
        end
        value1 = ((globals.tick()) - captures.slot1.wiggleAmpAt)
        if (captures.slot1.WIGGLEPERIOD <= value1) then
            value1 = captures.slot1
            value3 = captures.slot1.WIGGLEDEG
            value5 = ((globals.math.random()) * 2)
            value3 = (value3 + ((value5 - (1)) * captures.slot1.WIGGLEMARGIN))
            value1.wiggleAmpNow = value3
            value1 = captures.slot1
            value3 = globals.tick()
            value1.wiggleAmpAt = value3
        end
        value1 = captures.slot1.wiggleAmpNow
        value1 = (value1 > (0))
        if value1 then
            value1 = captures.slot1.wiggleAmpNow
            if (not value1) then
                value1 = captures.slot1.WIGGLEDEG
            end
        else
            value1 = captures.slot1.WIGGLEDEG
        end
        value2 = (6.283185307179586 / captures.slot1.WIGGLEPERIOD)
        value2 = globals.math.sin((((globals.tick()) - value34) * value2))
        value3 = globals.math.rad
        value1 = (value2 * (value3((value1 * (0.5)))))
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.horizontalVector = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value24, value25, value26, value27, value28

        tmp_X = {...}
        value28 = rawget(tmp_X, 1)
        value24 = globals.Vector3.new
        value25 = value28.X
        value26 = 0
        value27 = value28.Z
        return value24(table.unpack({[25] = value25, [26] = value26, [27] = value27}, 25, 27))
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_504 = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local loop, loopContinues, tmp_D, tmp_I, tmp_X, tmp_Y, tmp_cache_r, tmp_key, tmp_n, tmp_value, loopExit_225, loopExit_228, loopExit_256, loopExit_608, value2, value3, value6, value7, value8, value10, value12, value13, value14, value15, value16, value17, value18, value19, value20, value21, value22, value23, value24, value25, value26, value29

        tmp_X = {...}
        value12, value13, value14, value15 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        value2 = captures.slot1
        R[4] = false
        value2.goodWindow = R[4]
        tmp_X = captures.slot3
        writeCell(tmp_X, true)
        value7 = captures.slot4.Torso.Position
        value8 = value12.Torso.Position
        value6 = Functions.helper_1132({slot1 = captures.slot5}, globals)
        value2 = (value7 - value8)
        value15 = globals.Vector3.new
        value16 = value2.X
        value18 = value2.Z
        value17 = 0
        value18 = (value15(value16, value17, value18)).Unit
        value16 = value6
        value17 = value7
        value24 = ((value7 + (value18 * (value16(value17, value18)))) - value8).Magnitude
        if (not (value24 < value13)) then
            value15 = value18
        else
            tmp_X = captures.authAliveCell
            if (not (readCell(tmp_X))) then
                closeCaptures(cells, R)
                return
            end
            tmp_X = captures.slot7
            value15 = readCell(tmp_X)
            value16 = value7
            value17 = value8
            value19 = value12
            value15 = value15(value16, value17, value18, value19)
            if value15 then
                value2 = captures.slot1
                R[4] = "flee-graph"
                if (not R[4]) then
                    R[4] = "flee-fan"
                end
            else
                value15 = value29
                value2 = captures.slot1
                if value15 then
                    R[4] = "flee-graph"
                    if (not R[4]) then
                        R[4] = "flee-fan"
                    end
                else
                    R[4] = value15
                    R[4] = "flee-fan"
                end
            end
            value2.navMode = R[4]
            if (not value15) then
                value3 = 180
                value2 = 2.5
                R[4] = 2.5
                value16 = false
                loop = {parent = loop, index = (value2 - R[4]), limit = value3, step = R[4]}
                value17 = value18
                value15 = value18
                loop.index += loop.step
                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                if loopContinues then
                    value2 = loop.index
                end
                if loopContinues then
                    value19 = globals.CFrame.Angles
                    value21 = globals.math.rad(value2)
                    value20 = 0
                    value22 = 0
                    value20 = (value19(value20, value21, value22))
                    value19 = value20.VectorToWorldSpace
                    value21 = value18
                    value19 = value19(value20, value21)
                    value20 = globals.CFrame.Angles
                    value22 = globals.math.rad((- value2))
                    value21 = 0
                    value23 = 0
                    value21 = (value20(value21, value22, value23))
                    value20 = value21.VectorToWorldSpace
                    value22 = value18
                    value20 = value20(value21, value22)
                    value10 = globals.ipairs
                    value2 = {}
                    value21 = value20
                    value20 = value19
                    tmp_Y = value2
                    table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                    value3 = value2
                    value2 = value10
                    value2, value3, R[4] = value2(value3)
                    loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                    while true do
                        loopContinues, tmp_key, tmp_value = loop.iterator()
                        if loopContinues then
                            value3, R[4] = tmp_key, tmp_value
                        end
                        if loopContinues then
                            while true do
                                value20 = value6
                                value21 = value7
                                value22 = R[4]
                                value20 = value20(value21, value22)
                                value10 = ((value7 + (R[4] * value20)) - value8).Magnitude
                                value19 = (value10 >= (value13 + (4)))
                                if value19 then
                                    value16 = true
                                    value17 = R[4]
                                    loop = loop.parent
                                    if value16 then
                                        loopExit_228 = 255
                                        break
                                    else
                                        while true do
                                            loop.index += loop.step
                                            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                            if loopContinues then
                                                value2 = loop.index
                                            end
                                            if loopContinues then
                                                value19 = globals.CFrame.Angles
                                                value21 = globals.math.rad(value2)
                                                value20 = 0
                                                value22 = 0
                                                value20 = (value19(value20, value21, value22))
                                                value19 = value20.VectorToWorldSpace
                                                value21 = value18
                                                value19 = value19(value20, value21)
                                                value20 = globals.CFrame.Angles
                                                value22 = globals.math.rad((- value2))
                                                value21 = 0
                                                value23 = 0
                                                value21 = (value20(value21, value22, value23))
                                                value20 = value21.VectorToWorldSpace
                                                value22 = value18
                                                value20 = value20(value21, value22)
                                                value10 = globals.ipairs
                                                value2 = {}
                                                value21 = value20
                                                value20 = value19
                                                tmp_Y = value2
                                                table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                                                value3 = value2
                                                value2 = value10
                                                value2, value3, R[4] = value2(value3)
                                                loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                                                loopContinues, tmp_key, tmp_value = loop.iterator()
                                                if loopContinues then
                                                    value3, R[4] = tmp_key, tmp_value
                                                end
                                                if loopContinues then
                                                    loopExit_256 = 228
                                                    break
                                                else
                                                    loop = loop.parent
                                                    continue
                                                end
                                            else
                                                loopExit_256 = 261
                                                break
                                            end
                                        end
                                        if (loopExit_256 == 228) then
                                            continue
                                        elseif (loopExit_256 == 261) then
                                            loopExit_228 = 261
                                            break
                                        end
                                    end
                                else
                                    loopExit_228 = 284
                                    break
                                end
                            end
                            if (loopExit_228 == 255) then
                                loopExit_225 = 255
                                break
                            elseif (loopExit_228 == 261) then
                                loopExit_225 = 261
                                break
                            elseif (loopExit_228 == 284) then
                                if (value10 > value24) then
                                    value24 = value10
                                    value15 = R[4]
                                    continue
                                else
                                    continue
                                end
                            end
                        else
                            loop = loop.parent
                            if value16 then
                                loopExit_225 = 255
                                break
                            else
                                loop.index += loop.step
                                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                if loopContinues then
                                    value2 = loop.index
                                end
                                if loopContinues then
                                    value19 = globals.CFrame.Angles
                                    value21 = globals.math.rad(value2)
                                    value20 = 0
                                    value22 = 0
                                    value20 = (value19(value20, value21, value22))
                                    value19 = value20.VectorToWorldSpace
                                    value21 = value18
                                    value19 = value19(value20, value21)
                                    value20 = globals.CFrame.Angles
                                    value22 = globals.math.rad((- value2))
                                    value21 = 0
                                    value23 = 0
                                    value21 = (value20(value21, value22, value23))
                                    value20 = value21.VectorToWorldSpace
                                    value22 = value18
                                    value20 = value20(value21, value22)
                                    value10 = globals.ipairs
                                    value2 = {}
                                    value21 = value20
                                    value20 = value19
                                    tmp_Y = value2
                                    table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                                    value3 = value2
                                    value2 = value10
                                    value2, value3, R[4] = value2(value3)
                                    loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                                    loopContinues, tmp_key, tmp_value = loop.iterator()
                                    if loopContinues then
                                        value3, R[4] = tmp_key, tmp_value
                                    end
                                    if loopContinues then
                                        while true do
                                            value20 = value6
                                            value21 = value7
                                            value22 = R[4]
                                            value20 = value20(value21, value22)
                                            value10 = ((value7 + (R[4] * value20)) - value8).Magnitude
                                            value19 = (value10 >= (value13 + (4)))
                                            if value19 then
                                                value16 = true
                                                value17 = R[4]
                                                loop = loop.parent
                                                if value16 then
                                                    loopExit_228 = 255
                                                    break
                                                else
                                                    while true do
                                                        loop.index += loop.step
                                                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                                        if loopContinues then
                                                            value2 = loop.index
                                                        end
                                                        if loopContinues then
                                                            value19 = globals.CFrame.Angles
                                                            value21 = globals.math.rad(value2)
                                                            value20 = 0
                                                            value22 = 0
                                                            value20 = (value19(value20, value21, value22))
                                                            value19 = value20.VectorToWorldSpace
                                                            value21 = value18
                                                            value19 = value19(value20, value21)
                                                            value20 = globals.CFrame.Angles
                                                            value22 = globals.math.rad((- value2))
                                                            value21 = 0
                                                            value23 = 0
                                                            value21 = (value20(value21, value22, value23))
                                                            value20 = value21.VectorToWorldSpace
                                                            value22 = value18
                                                            value20 = value20(value21, value22)
                                                            value10 = globals.ipairs
                                                            value2 = {}
                                                            value21 = value20
                                                            value20 = value19
                                                            tmp_Y = value2
                                                            table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                                                            value3 = value2
                                                            value2 = value10
                                                            value2, value3, R[4] = value2(value3)
                                                            loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                                                            loopContinues, tmp_key, tmp_value = loop.iterator()
                                                            if loopContinues then
                                                                value3, R[4] = tmp_key, tmp_value
                                                            end
                                                            if loopContinues then
                                                                loopExit_256 = 228
                                                                break
                                                            else
                                                                loop = loop.parent
                                                                continue
                                                            end
                                                        else
                                                            loopExit_256 = 261
                                                            break
                                                        end
                                                    end
                                                    if (loopExit_256 == 228) then
                                                        continue
                                                    elseif (loopExit_256 == 261) then
                                                        loopExit_228 = 261
                                                        break
                                                    end
                                                end
                                            else
                                                loopExit_228 = 284
                                                break
                                            end
                                        end
                                        if (loopExit_228 == 255) then
                                            loopExit_225 = 255
                                            break
                                        elseif (loopExit_228 == 261) then
                                            loopExit_225 = 261
                                            break
                                        elseif (loopExit_228 == 284) then
                                            if (value10 > value24) then
                                                value24 = value10
                                                value15 = R[4]
                                                continue
                                            else
                                                continue
                                            end
                                        end
                                    else
                                        while true do
                                            loop = loop.parent
                                            loop.index += loop.step
                                            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                            if loopContinues then
                                                value2 = loop.index
                                            end
                                            if loopContinues then
                                                value19 = globals.CFrame.Angles
                                                value21 = globals.math.rad(value2)
                                                value20 = 0
                                                value22 = 0
                                                value20 = (value19(value20, value21, value22))
                                                value19 = value20.VectorToWorldSpace
                                                value21 = value18
                                                value19 = value19(value20, value21)
                                                value20 = globals.CFrame.Angles
                                                value22 = globals.math.rad((- value2))
                                                value21 = 0
                                                value23 = 0
                                                value21 = (value20(value21, value22, value23))
                                                value20 = value21.VectorToWorldSpace
                                                value22 = value18
                                                value20 = value20(value21, value22)
                                                value10 = globals.ipairs
                                                value2 = {}
                                                value21 = value20
                                                value20 = value19
                                                tmp_Y = value2
                                                table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                                                value3 = value2
                                                value2 = value10
                                                value2, value3, R[4] = value2(value3)
                                                loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                                                loopContinues, tmp_key, tmp_value = loop.iterator()
                                                if loopContinues then
                                                    value3, R[4] = tmp_key, tmp_value
                                                end
                                                if loopContinues then
                                                    loopExit_608 = 228
                                                    break
                                                else
                                                    continue
                                                end
                                            else
                                                loopExit_608 = 261
                                                break
                                            end
                                        end
                                        if (loopExit_608 == 228) then
                                            while true do
                                                value20 = value6
                                                value21 = value7
                                                value22 = R[4]
                                                value20 = value20(value21, value22)
                                                value10 = ((value7 + (R[4] * value20)) - value8).Magnitude
                                                value19 = (value10 >= (value13 + (4)))
                                                if value19 then
                                                    value16 = true
                                                    value17 = R[4]
                                                    loop = loop.parent
                                                    if value16 then
                                                        loopExit_228 = 255
                                                        break
                                                    else
                                                        while true do
                                                            loop.index += loop.step
                                                            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                                                            if loopContinues then
                                                                value2 = loop.index
                                                            end
                                                            if loopContinues then
                                                                value19 = globals.CFrame.Angles
                                                                value21 = globals.math.rad(value2)
                                                                value20 = 0
                                                                value22 = 0
                                                                value20 = (value19(value20, value21, value22))
                                                                value19 = value20.VectorToWorldSpace
                                                                value21 = value18
                                                                value19 = value19(value20, value21)
                                                                value20 = globals.CFrame.Angles
                                                                value22 = globals.math.rad((- value2))
                                                                value21 = 0
                                                                value23 = 0
                                                                value21 = (value20(value21, value22, value23))
                                                                value20 = value21.VectorToWorldSpace
                                                                value22 = value18
                                                                value20 = value20(value21, value22)
                                                                value10 = globals.ipairs
                                                                value2 = {}
                                                                value21 = value20
                                                                value20 = value19
                                                                tmp_Y = value2
                                                                table.move({[20] = value20, [21] = value21}, 20, 21, 1, tmp_Y)
                                                                value3 = value2
                                                                value2 = value10
                                                                value2, value3, R[4] = value2(value3)
                                                                loop = {parent = loop, iterator = iterateValues(value2, value3, R[4])}
                                                                loopContinues, tmp_key, tmp_value = loop.iterator()
                                                                if loopContinues then
                                                                    value3, R[4] = tmp_key, tmp_value
                                                                end
                                                                if loopContinues then
                                                                    loopExit_256 = 228
                                                                    break
                                                                else
                                                                    loop = loop.parent
                                                                    continue
                                                                end
                                                            else
                                                                loopExit_256 = 261
                                                                break
                                                            end
                                                        end
                                                        if (loopExit_256 == 228) then
                                                            continue
                                                        elseif (loopExit_256 == 261) then
                                                            loopExit_228 = 261
                                                            break
                                                        end
                                                    end
                                                else
                                                    loopExit_228 = 284
                                                    break
                                                end
                                            end
                                            if (loopExit_228 == 255) then
                                                loopExit_225 = 255
                                                break
                                            elseif (loopExit_228 == 261) then
                                                loopExit_225 = 261
                                                break
                                            elseif (loopExit_228 == 284) then
                                                if (value10 > value24) then
                                                    value24 = value10
                                                    value15 = R[4]
                                                    continue
                                                else
                                                    continue
                                                end
                                            end
                                        elseif (loopExit_608 == 261) then
                                            loopExit_225 = 261
                                            break
                                        end
                                    end
                                else
                                    loopExit_225 = 261
                                    break
                                end
                            end
                        end
                    end
                    if (loopExit_225 == 255) then
                        loop = loop.parent
                        value15 = value17
                    elseif (loopExit_225 == 261) then
                        loop = loop.parent
                    end
                else
                    loop = loop.parent
                    if (not (not value16)) then
                        value15 = value17
                    end
                end
            end
        end
        tmp_X = captures.slot8
        value3 = readCell(tmp_X)((value7 - value8))
        value2 = value3.Magnitude
        R[4] = 0.01
        value2 = (value2 > R[4])
        if value2 then
            value2 = value3.Unit
            if (not value2) then
                value2 = value18
            end
        else
            value2 = value18
        end
        tmp_X = captures.slot9
        value3 = readCell(tmp_X)
        if (value12 ~= value3) then
            tmp_X = captures.slot9
            writeCell(tmp_X, value12)
            value3 = false
            tmp_X = captures.slot10
            writeCell(tmp_X, value3)
        end
        value18 = value12
        value17 = value18.FindFirstChild
        value19 = "Torso"
        value17 = value17(value18, value19)
        if value17 then
            value22 = globals.workspace
            value21 = value22.Raycast
            value24 = (value17.Position - value7)
            value25 = captures.slot5
            value23 = value7
            value17 = ((value21(value22, value23, value24, value25)) ~= nil)
            tmp_X = captures.slot8
            value3 = readCell(tmp_X)(value7)
            tmp_X = captures.slot8
            R[4] = readCell(tmp_X)
            R[4] = R[4](value8)
            value3 = (value3 - R[4]).Magnitude
            R[4] = 0.05
            value10 = globals.pcall
            value13 = Functions.helper_150({authAliveCell = captures.authAliveCell, slot2 = captures.slot11, slot3 = captureShared(cells, R, 4)}, globals)
            value10(value13)
            value21 = globals.math.clamp
            value22 = (R[4] + 0.1)
            value23 = 0
            value24 = 0.35
            value21 = value21(value22, value23, value24)
            value22 = globals.math.clamp
            tmp_X = captures.slot12
            value24 = readCell(tmp_X)
            value23 = value24.Dot
            value25 = value2
            value23 = value23(value24, value25)
            value25 = 24
            value24 = 0
            value22 = value22(value23, value24, value25)
            tmp_X = captures.slot13
            value10 = (((readCell(tmp_X)(value12.Name)) + 2) + (value22 * value21))
            if value17 then
                value12 = (value3 < value10)
                if value12 then
                    tmp_X = captures.slot10
                    writeCell(tmp_X, true)
                else
                    value12 = (not value17)
                    if value12 then
                        value3 = false
                        tmp_X = captures.slot10
                        writeCell(tmp_X, value3)
                    else
                        value12 = (value3 > (value10 + (1.5)))
                        if value12 then
                            value3 = false
                            tmp_X = captures.slot10
                            writeCell(tmp_X, value3)
                        end
                    end
                end
            else
                value12 = (not value17)
                if value12 then
                    value3 = false
                    tmp_X = captures.slot10
                    writeCell(tmp_X, value3)
                else
                    value12 = (value3 > (value10 + (1.5)))
                    if value12 then
                        value3 = false
                        tmp_X = captures.slot10
                        writeCell(tmp_X, value3)
                    end
                end
            end
        else
            tmp_X = captures.slot8
            value3 = readCell(tmp_X)(value7)
            tmp_X = captures.slot8
            R[4] = readCell(tmp_X)
            R[4] = R[4](value8)
            value3 = (value3 - R[4]).Magnitude
            R[4] = 0.05
            value10 = globals.pcall
            value13 = Functions.helper_150({authAliveCell = captures.authAliveCell, slot2 = captures.slot11, slot3 = captureShared(cells, R, 4)}, globals)
            value10(value13)
            value21 = globals.math.clamp
            value22 = (R[4] + 0.1)
            value23 = 0
            value24 = 0.35
            value21 = value21(value22, value23, value24)
            value22 = globals.math.clamp
            tmp_X = captures.slot12
            value24 = readCell(tmp_X)
            value23 = value24.Dot
            value25 = value2
            value23 = value23(value24, value25)
            value25 = 24
            value24 = 0
            value22 = value22(value23, value24, value25)
            tmp_X = captures.slot13
            value10 = (((readCell(tmp_X)(value12.Name)) + 2) + (value22 * value21))
            value12 = (not value17)
            if value12 then
                value3 = false
                tmp_X = captures.slot10
                writeCell(tmp_X, value3)
            else
                value12 = (value3 > (value10 + (1.5)))
                if value12 then
                    value3 = false
                    tmp_X = captures.slot10
                    writeCell(tmp_X, value3)
                end
            end
        end
        tmp_X = captures.slot10
        value3 = readCell(tmp_X)
        value10 = false
        if value3 then
            captures.slot1.navMode = "anti-walltag"
            value16 = value6
            value17 = value7
            value18 = value2
            value16 = value16(value17, value18)
            value10 = true
            value13 = true
            if (not (3 <= value16)) then
                value10 = value13
            else
                value15 = value2
            end
        end
        closeCapture(cells, R, 4)
        value3 = {}
        value22 = 0
        value23 = 355
        value24 = 5
        R[4] = false
        loop = {parent = loop, index = (value22 - value24), limit = value23, step = value24}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value12 = loop.index
            end
            if loopContinues then
                value21 = globals.CFrame.Angles
                value23 = globals.math.rad(value12)
                value22 = 0
                value24 = 0
                value21 = value21(value22, value23, value24)
                value20 = value21.VectorToWorldSpace
                value22 = globals.Vector3.new
                value23 = 0
                value24 = 0
                value25 = (- 1)
                value22 = table.pack(value22(table.unpack({[23] = value23, [24] = value24, [25] = value25}, 23, 25)))
                tmp_n = value22
                tmp_I = tmp_n.n
                tmp_cache_r = ((2 + tmp_I) - 1)
                tmp_n.n = tmp_cache_r
                table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                table.move({[21] = value21}, 21, 21, 1, tmp_n)
                tmp_I = table.pack(value20(table.unpack(tmp_n, 1, tmp_n.n)))
                value20 = rawget(tmp_I, 1)
                value18 = value6
                value19 = value7
                value18, value19 = value18(value19, value20)
                value12 = (value18 < (1.1))
                if value12 then
                    value12 = value19
                    if value12 then
                        R[4] = true
                        value12 = globals.table.insert
                        value12(value3, value19)
                        continue
                    else
                        continue
                    end
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        if R[4] then
            value3 = (# value3)
            value12 = 0
            R[4] = (value3 > value12)
        end
        value3 = captures.slot14.ON
        if value3 then
            value3 = (captures.slot14.PATHERR > 0)
            if value3 then
                value3 = (not R[4])
                if value3 then
                    value3 = (((globals.tick()) - captures.slot14.fleeJitterAt) > 0.6)
                    if value3 then
                        value3 = captures.slot14
                        value13 = ((globals.math.random()) * 2)
                        value13 = (((value13 - (1)) * captures.slot14.PATHERR) * 0.6108652381980153)
                        value3.fleeJitterTarget = value13
                        value3 = captures.slot14
                        value13 = globals.tick()
                        value3.fleeJitterAt = value13
                    end
                    value3 = captures.slot14
                    value13 = (captures.slot14.fleeJitter + ((captures.slot14.fleeJitterTarget - captures.slot14.fleeJitter) * 0.06))
                    value3.fleeJitter = value13
                    value21 = globals.CFrame.Angles
                    value23 = captures.slot14.fleeJitter
                    value24 = 0
                    value22 = 0
                    value21 = value21(value22, value23, value24)
                    value20 = value21.VectorToWorldSpace
                    value22 = value15
                    value20 = value20(value21, value22)
                else
                    value20 = value15
                end
            else
                value20 = value15
            end
        else
            value20 = value15
        end
        value24 = captures.slot4.Humanoid
        value24.MoveTo(value24, (value7 + (value20 * 18)))
        if value10 then
            value3 = captures.slot4.Humanoid
            value3.AutoRotate = false
            value3 = captures.slot4.Torso
            value15 = globals.CFrame.lookAt
            value17 = (value7 + value2)
            value16 = value7
            value15 = value15(value16, value17)
            value3.CFrame = value15
        else
            if R[4] then
                value2 = captures.slot4.Humanoid
                value2.AutoRotate = false
                value2 = 1.1
                value22 = 0
                value23 = 355
                value24 = 5
                value3 = nil
                loop = {parent = loop, index = (value22 - value24), limit = value23, step = value24}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        R[4] = loop.index
                    end
                    if loopContinues then
                        value21 = globals.CFrame.Angles
                        value23 = globals.math.rad(R[4])
                        value24 = 0
                        value22 = 0
                        value22 = (value21(value22, value23, value24))
                        value21 = value22.VectorToWorldSpace
                        R[4] = globals.Vector3
                        value23 = R[4].new
                        R[4] = 1
                        value26 = (- R[4])
                        value24 = 0
                        value25 = 0
                        value23 = table.pack(value23(table.unpack({[24] = value24, [25] = value25, [26] = value26}, 24, 26)))
                        tmp_n = value23
                        tmp_I = tmp_n.n
                        tmp_cache_r = ((2 + tmp_I) - 1)
                        tmp_n.n = tmp_cache_r
                        table.move(tmp_n, 1, tmp_I, 2, tmp_n)
                        table.move({[22] = value22}, 22, 22, 1, tmp_n)
                        tmp_D = table.pack(value21(table.unpack(tmp_n, 1, tmp_n.n)))
                        value21 = rawget(tmp_D, 1)
                        value15 = value6
                        value16 = value7
                        value17 = value21
                        value15, value16 = value15(value16, value17)
                        if value16 then
                            R[4] = (value15 < value2)
                            if R[4] then
                                value2 = value15
                                value3 = value16
                                continue
                            else
                                continue
                            end
                        else
                            R[4] = value16
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                if value3 then
                    value22 = globals.Vector3.new
                    value23 = value3.X
                    value25 = value3.Z
                    value24 = 0
                    value22 = value22(value23, value24, value25)
                    value2 = value22.Magnitude
                    if (0 < value2) then
                        value2 = value22.Unit
                        value16 = globals.Vector3.new
                        value17 = (- value2.Z)
                        value19 = value2.X
                        value18 = 0
                        value2 = (value16(value17, value18, value19))
                        tmp_X = captures.slot15
                        value3 = readCell(tmp_X)
                        if (value3 == nil) then
                            value3 = (value8 - value7)
                            R[4] = globals.Vector3
                            value22 = R[4].new
                            value23 = value3.X
                            value25 = value3.Z
                            value24 = 0
                            value22 = value22(value23, value24, value25)
                            value3 = value22.Magnitude
                            if (0 < value3) then
                                value17 = value22.Unit
                                value16 = value2
                                value15 = value16.Dot
                                value3 = ((value15(value16, value17)) > 0)
                                if value3 then
                                    value3 = (- 1)
                                    if (not value3) then
                                        value3 = 1
                                    end
                                else
                                    value3 = 1
                                end
                                tmp_X = captures.slot15
                                writeCell(tmp_X, value3)
                            else
                                tmp_X = captures.slot15
                                writeCell(tmp_X, 1)
                            end
                        end
                        tmp_X = captures.slot15
                        value3 = (value2 * (readCell(tmp_X)))
                        if (not (value14 <= 0.5)) then
                            value2 = globals.Vector3.new
                            R[4] = value3.Z
                            value22 = (- R[4])
                            value24 = value3.X
                            value23 = 0
                            value21 = value2
                            value20 = (value21(value22, value23, value24))
                        end
                        value2 = captures.slot4.Torso
                        R[4] = globals.CFrame
                        value6 = R[4].lookAt
                        value8 = (value7 + value20)
                        value6 = value6(value7, value8)
                        value2.CFrame = value6
                        captures.slot14.slideNow = true
                        value2 = captures.slot14
                        R[4] = globals.tick
                        R[4] = R[4]()
                        value6 = 0.18
                        R[4] = (R[4] + value6)
                        value2.slideUntil = R[4]
                    end
                end
            else
                tmp_X = captures.slot15
                writeCell(tmp_X, nil)
                value2 = captures.slot4.Humanoid
                value2.AutoRotate = true
            end
        end
        closeCaptures(cells, R)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_540 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value25

        tmp_X = {...}
        value25 = rawget(tmp_X, 1)
        value1 = captures.slot1
        if (value25 == value1) then
            value1 = captures.slot2
            return value1
        end
        if (not (value25 == captures.slot3)) then
            tmp_X = captures.slot5
            value3 = readCell(tmp_X)[value25]
            return value3
        end
        value1 = captures.slot4
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_553 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value8

        tmp_X = captures.slot1
        value4 = readCell(tmp_X)()
        value8 = captures.slot2
        value4.defaultAggroStyle = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_591 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X

        tmp_X = {...}
        if ((rawget(tmp_X, 1)) <= 0) then
            captures.slot1.markDeath()
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_598 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value8

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value8 = (not value2.randomiseAggro)
        value2.randomiseAggro = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_623 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value4, value5, value6, value8, value15, value16, value17, value18, value19

        tmp_X = {...}
        value19 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value3 = "TextButton"
        value4 = {}
        value16 = globals.UDim2.fromOffset
        value17 = 56
        value18 = 20
        value16 = value16(value17, value18)
        value4.Size = value16
        value17 = globals.UDim2.fromOffset
        value18 = 10
        value17 = value17(value18, value19)
        value4.Position = value17
        value6 = captures.slot3.accent
        value4.BackgroundColor3 = value6
        value4.Text = "\226\128\148"
        value6 = globals.Enum.Font.GothamBold
        value4.Font = value6
        value15 = globals.Color3.new
        value16 = 1
        value17 = 1
        value18 = 1
        value15 = value15(value16, value17, value18)
        value4.TextColor3 = value15
        value4.TextSize = 11
        value4.AutoButtonColor = true
        value4.BorderSizePixel = 0
        value18 = captures.slot4
        value15 = value2
        value16 = value3
        value17 = value4
        value15 = value15(value16, value17, value18)
        tmp_X = captures.slot5
        readCell(tmp_X)(value15, 6)
        tmp_X = captures.slot1
        value16 = readCell(tmp_X)
        value8 = {}
        value2 = globals.UDim2.new
        value4 = (- (78))
        value3 = 1
        value5 = 0
        value6 = 20
        value2 = value2(value3, value4, value5, value6)
        value8.Size = value2
        value17 = globals.UDim2.fromOffset
        value18 = 72
        value17 = value17(value18, value19)
        value8.Position = value17
        value8.BackgroundTransparency = 1
        value3 = globals.Enum.Font.Gotham
        value8.Font = value3
        value8.Text = "\226\128\148"
        value3 = captures.slot3.subtext
        value8.TextColor3 = value3
        value3 = 11
        value8.TextSize = value3
        value3 = globals.Enum.TextXAlignment.Left
        value8.TextXAlignment = value3
        value17 = "TextLabel"
        value19 = captures.slot4
        value18 = value8
        value16 = value16(value17, value18, value19)
        return value15, value16
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_626 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value6

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        if value2 then
            if ((globals.type(value2.select)) == "function") then
                tmp_X = captures.slot2
                if ((readCell(tmp_X)(captures.slot3.id))) then
                    value2.select(captures.slot3.id)
                else
                    if value2 then
                        tmp_X = captures.slot2
                        if ((readCell(tmp_X)(captures.slot3.id))) then
                            value6 = captures.slot3.id
                            value2.selected = value6
                        end
                    else
        
                    end
                end
            else
                if value2 then
                    tmp_X = captures.slot2
                    if ((readCell(tmp_X)(captures.slot3.id))) then
                        value6 = captures.slot3.id
                        value2.selected = value6
                    end
                else
        
                end
            end
        else
            if value2 then
                tmp_X = captures.slot2
                if ((readCell(tmp_X)(captures.slot3.id))) then
                    value6 = captures.slot3.id
                    value2.selected = value6
                end
            else
        
            end
        end
        tmp_X = captures.slot4
        readCell(tmp_X)()
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.moveToArenaApproach = function(captures, globals)
    local function recovered(...)
        local value2, value3, value4, value5, value8, value12

        value8 = captures.slot1
        value12 = captures.slot2[("Arena" .. captures.slot3)].Teleport.CFrame
        value2 = globals.Vector3.new
        value4 = 3
        value5 = 0
        value3 = 0
        value2 = (value12 + (value2(value3, value4, value5)))
        value8.CFrame = value2
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.handleKevinKeyUp = function(captures, globals)
    return function(input)
        if input.UserInputType ~= globals.Enum.UserInputType.Keyboard then return end
        if input.KeyCode == globals.Enum.KeyCode.P then writeCell(captures.teleportHeldCell, false) end
        if input.KeyCode == globals.Enum.KeyCode.V then writeCell(captures.enabledCell, false) end
    end
end

Functions.formatAggression = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value22

        tmp_X = {...}
        value22 = rawget(tmp_X, 1)
        value2 = (value22 == "corner")
        if value2 then
            value2 = "Corner"
        else
            value2 = (value22 == "charge")
            if value2 then
                value2 = "Charge"
            else
                value2 = "\226\128\148"
            end
        end
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_737 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value12, value13, value14, value15, value16, value17, value18, value19

        tmp_X = {...}
        value12, value13 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value14 = globals.Vector3.new
        value15 = value12.X
        tmp_X = captures.slot1
        value16 = readCell(tmp_X)
        value17 = value12.Z
        value14 = value14(value15, value16, value17)
        value15 = globals.Vector3.new
        value16 = value13.X
        tmp_X = captures.slot1
        value17 = readCell(tmp_X)
        value18 = value13.Z
        value16 = ((value15(value16, value17, value18)) - value14)
        value2 = value16.Magnitude
        if (not (value2 < (0.05))) then
            value13 = globals.workspace
            value2 = value13.Spherecast
            value15 = 0.48
            value17 = captures.slot3
            value12 = value2
            value2 = ((value12(value13, value14, value15, value16, value17)) == value19)
            return value2
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_758 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, tmp_Y, value2, value4, value5, value6, value7, value8, value10, value11, value13

        tmp_X = {...}
        value2 = rawget(tmp_X, 1)
        value11 = value2.CFrame
        tmp_X = captures.slot1
        value5 = readCell(tmp_X)(value11.RightVector)
        value4 = (value5.Magnitude > 0)
        if value4 then
            value4 = value5.Unit
            if (not value4) then
                value8 = globals.Vector3.new
                value5 = 1
                value6 = 0
                value7 = 0
                value4 = value8
                value4 = value4(value5, value6, value7)
            end
        else
            value8 = globals.Vector3.new
            value5 = 1
            value6 = 0
            value7 = 0
            value4 = value8
            value4 = value4(value5, value6, value7)
        end
        tmp_X = captures.slot1
        value6 = readCell(tmp_X)(value11.LookVector)
        value5 = (value6.Magnitude > 0)
        if value5 then
            value5 = value6.Unit
            if (not value5) then
                value10 = globals.Vector3.new
                value6 = 0
                value7 = 0
                value8 = 1
                value5 = value10
                value5 = value5(value6, value7, value8)
            end
        else
            value10 = globals.Vector3.new
            value6 = 0
            value7 = 0
            value8 = 1
            value5 = value10
            value5 = value5(value6, value7, value8)
        end
        tmp_X = captures.slot1
        value8 = readCell(tmp_X)(value11.Position)
        value11 = ((value2.Size.X * 0.5) + 0.7)
        value13 = ((value2.Size.Z * 0.5) + 0.7)
        value2 = {}
        value10 = ((value8 + (value4 * value11)) + (value5 * value13))
        value6 = ((value8 + (value4 * value11)) - (value5 * value13))
        value7 = ((value8 - (value4 * value11)) + (value5 * value13))
        value8 = ((value8 - (value4 * value11)) - (value5 * value13))
        value4 = value2
        value5 = value10
        tmp_Y = value4
        table.move({[5] = value5, [6] = value6, [7] = value7, [8] = value8}, 5, 8, 1, tmp_Y)
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_763 = function(captures, globals)
    local function recovered(...)
        local value6

        value6 = captures.slot1.FANAKA_UI
        value6.Destroy(value6)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_797 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value2, value3, value4, value6, value8, value13

        value6 = globals.math.huge
        value2 = globals.ipairs
        value3 = captures.slot1
        value2, value3, value4 = value2(value3)
        value8 = value13
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                if (value4 ~= captures.slot2) then
                    tmp_X = captures.slot3
                    if ((readCell(tmp_X)(value4)) < value6) then
                        tmp_X = captures.slot3
                        value6 = readCell(tmp_X)(value4)
                        value8 = value4
                        continue
                    else
                        continue
                    end
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        if value8 then
            captures.slot4.style = value8
            captures.slot4.streak = 0
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.registerProfile = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value26, value27

        tmp_X = {...}
        value26, value27 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.numericCCell
        if ((readCell(tmp_X)(2947)) <= 904) then
            value1 = ((globals.type(value26)) ~= "string")
            if value1 then
                tmp_X = captures.slot2
                value1 = readCell(tmp_X)
                return value1
            else
                value1 = (value26 == "")
                if value1 then
                    tmp_X = captures.slot2
                    value1 = readCell(tmp_X)
                    return value1
                else
                    tmp_X = captures.slot2
                    value1 = readCell(tmp_X).brains
                    if value27 then
                        value1[value26] = value27
                        tmp_X = captures.slot2
                        value1 = readCell(tmp_X).selected
                        if (value1 ~= nil) then
                            tmp_X = captures.slot2
                            value1 = readCell(tmp_X)
                            return value1
                        else
                            tmp_X = captures.slot2
                            readCell(tmp_X).selected = value26
                            tmp_X = captures.slot2
                            value1 = readCell(tmp_X)
                            return value1
                        end
                    else
                        tmp_X = captures.slot2
                        value27 = readCell(tmp_X).brains[value26]
                        if value27 then
                            value1[value26] = value27
                            tmp_X = captures.slot2
                            value1 = readCell(tmp_X).selected
                            if (value1 ~= nil) then
                                tmp_X = captures.slot2
                                value1 = readCell(tmp_X)
                                return value1
                            else
                                tmp_X = captures.slot2
                                readCell(tmp_X).selected = value26
                                tmp_X = captures.slot2
                                value1 = readCell(tmp_X)
                                return value1
                            end
                        else
                            value27 = {}
                            value1[value26] = value27
                            tmp_X = captures.slot2
                            value1 = readCell(tmp_X).selected
                            if (value1 ~= nil) then
                                tmp_X = captures.slot2
                                value1 = readCell(tmp_X)
                                return value1
                            else
                                tmp_X = captures.slot2
                                readCell(tmp_X).selected = value26
                                tmp_X = captures.slot2
                                value1 = readCell(tmp_X)
                                return value1
                            end
                        end
                    end
                end
            end
        end
        while true do
            tmp_X = captures.registryCell
            if readCell(tmp_X)[181] then
                continue
            else
                break
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.watchOpeningDeaths = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value11, value12, value13, value14

        tmp_X = {...}
        value11 = rawget(tmp_X, 1)
        if value11 then
            value13 = value11
            value1 = value13.FindFirstChildOfClass
            value14 = "Humanoid"
            value12 = value1
            value11 = (value12(value13, value14))
            if value11 then
                value13 = value11.HealthChanged
                lifecycle.connect(value13, (Functions.helper_591({slot1 = captures.slot1}, globals)))
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_888 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value8

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value8 = captures.slot2
        value2.defaultOpeningStyle = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_892 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value8

        tmp_X = captures.slot1
        value4 = readCell(tmp_X)()
        value8 = (not value4.randomiseLoseLose)
        value4.randomiseLoseLose = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.refreshQueueControls = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value16

        tmp_X = captures.numericCCell
        value2 = ((readCell(tmp_X)(2648)) <= 2727)
        if value2 then
            tmp_X = captures.slot2
            value16 = readCell(tmp_X)()
            tmp_X = captures.slot3
            value2 = readCell(tmp_X)
            value4 = value16.autoQueue
            if value4 then
                value4 = "ON"
            else
                value4 = "OFF"
            end
            value2.Text = value4
            tmp_X = captures.slot3
            value2 = readCell(tmp_X)
            value4 = value16.autoQueue
            if value4 then
                value4 = captures.slot5.accent
                if (not value4) then
                    value4 = captures.slot5.panel
                end
            else
                value4 = captures.slot5.panel
            end
            value2.BackgroundColor3 = value4
            tmp_X = captures.slot3
            value7 = readCell(tmp_X)
            value3 = value16.autoQueue
            if value3 then
                value2 = globals.Color3.new
                value6 = 1
                value4 = 1
                value5 = 1
                value3 = value2
                value3 = value3(value4, value5, value6)
                if (not value3) then
                    value3 = captures.slot5.subtext
                end
            else
                value3 = captures.slot5.subtext
            end
            value7.TextColor3 = value3
            tmp_X = captures.slot6
            value2 = readCell(tmp_X)
            value4 = value16.autoQueueFind
            if value4 then
                value4 = "ON"
            else
                value4 = "OFF"
            end
            value2.Text = value4
            tmp_X = captures.slot6
            value2 = readCell(tmp_X)
            value4 = value16.autoQueueFind
            if value4 then
                value4 = captures.slot5.accent
                if (not value4) then
                    value4 = captures.slot5.panel
                end
            else
                value4 = captures.slot5.panel
            end
            value2.BackgroundColor3 = value4
            tmp_X = captures.slot6
            value7 = readCell(tmp_X)
            value3 = value16.autoQueueFind
            if value3 then
                value2 = globals.Color3.new
                value6 = 1
                value4 = 1
                value5 = 1
                value3 = value2
                value3 = value3(value4, value5, value6)
                if (not value3) then
                    value3 = captures.slot5.subtext
                end
            else
                value3 = captures.slot5.subtext
            end
            value7.TextColor3 = value3
            value2 = globals.pairs
            tmp_X = captures.slot7
            value3 = readCell(tmp_X)
            value2, value3, value4 = value2(value3)
            loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value3, value4 = tmp_key, tmp_value
                end
                if loopContinues then
                    value5 = (value16.autoQueueArena == value3)
                    if value5 then
                        value7 = captures.slot5.accent
                        if (not value7) then
                            value7 = captures.slot5.panel
                        end
                    else
                        value7 = captures.slot5.panel
                    end
                    value4.BackgroundColor3 = value7
                    if value5 then
                        value9 = globals.Color3.new
                        value6 = 1
                        value7 = 1
                        value8 = 1
                        value5 = value9
                        value5 = value5(value6, value7, value8)
                        if (not value5) then
                            value5 = captures.slot5.subtext
                        end
                    else
                        value5 = captures.slot5.subtext
                    end
                    value4.TextColor3 = value5
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            value5 = globals.pairs
            tmp_X = captures.slot8
            value6 = readCell(tmp_X)
            value5, value6, value7 = value5(value6)
            loop = {parent = loop, iterator = iterateValues(value5, value6, value7)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value6, value7 = tmp_key, tmp_value
                end
                if loopContinues then
                    value8 = (value16.autoQueueSide == value6)
                    if value8 then
                        value3 = captures.slot5.accent
                        if (not value3) then
                            value3 = captures.slot5.panel
                        end
                    else
                        value3 = captures.slot5.panel
                    end
                    value7.BackgroundColor3 = value3
                    if value8 then
                        value2 = globals.Color3.new
                        value9 = 1
                        value10 = 1
                        value11 = 1
                        value8 = value2
                        value8 = value8(value9, value10, value11)
                        if (not value8) then
                            value8 = captures.slot5.subtext
                        end
                    else
                        value8 = captures.slot5.subtext
                    end
                    value7.TextColor3 = value8
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            tmp_X = captures.slot9
            value2 = readCell(tmp_X)
            value5 = globals.tostring
            value6 = captures.slot10.FANAKA_DEBUG
            if value6 then
                value6 = captures.slot10.FANAKA_DEBUG.autoQueueState
                if (not value6) then
                    value6 = "-"
                end
            else
                value6 = "-"
            end
            value4 = ("Status: " .. (value5(value6)))
            value2.Text = value4
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_904 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, loopExit_17, value2, value3, value4, value5, value6, value10, value11, value12, value14, value16

        tmp_X = {...}
        value4, value5, value6 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value14 = Functions.helper_1166({slot1 = value4, catalogCell = captures.catalogCell, slot3 = value5}, globals)
        tmp_X = captures.slot2
        value2 = readCell(tmp_X)
        value3 = value14(value6)
        if (((value2(value3, value4)))) then
            value2 = value14(value6)
            return value2, true
        end
        value2 = globals.math.rad
        value3 = captures.slot3.sweepStep
        value16 = value2(value3)
        value11 = captures.slot3.sweepMax
        value10 = 1
        value12 = 1
        loop = {parent = loop, index = (value10 - value12), limit = value11, step = value12}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value10 = loop.index
            end
            if loopContinues then
                value3 = value14((value6 + (value10 * value16)))
                tmp_X = captures.slot2
                value2 = readCell(tmp_X)
                value2 = value2(value3, value4)
                if value2 then
                    loopExit_17 = 28
                    break
                else
                    value3 = value14((value6 - (value10 * value16)))
                    tmp_X = captures.slot2
                    value2 = readCell(tmp_X)
                    if ((value2(value3, value4))) then
                        loopExit_17 = 28
                        break
                    else
                        continue
                    end
                end
            else
                loopExit_17 = 22
                break
            end
        end
        if (loopExit_17 == 22) then
            loop = loop.parent
            value2 = value14(value6)
            return value2, false
        elseif (loopExit_17 == 28) then
        
        end
        return value3, true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_941 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value8

        value2 = (captures.slot1.Data.ActiveArena.Value ~= value8)
        tmp_X = captures.slot2
        writeCell(tmp_X, value2)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_947 = function(captures, globals)
    local function recovered(...)
        local tmp_X

        tmp_X = captures.slot1
        if ((readCell(tmp_X)) == "Settings") then
            tmp_X = captures.slot2
            readCell(tmp_X)()
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_948 = function(captures, globals)
    local function recovered(...)
        local value5

        value5 = globals.gethui
        if value5 then
            value5 = globals.gethui()
        end
        return value5
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.recordReachSample = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value3, value5, value7, value13, value14, value15, value16

        tmp_X = {...}
        value15, value16 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if (not (not value15)) then
            if (not (value16 < 3.5)) then
                if (not (value16 > (11))) then
                    value3 = captures.slot2[value15]
                    if (not value3) then
                        value3 = {}
                        value7 = {}
                        value3.samples = value7
                        value3.i = 0
                        value3.n = 0
                        captures.slot2[value15] = value3
                    end
                    value7 = (value3.i % 12)
                    value7 = (value7 + (1))
                    value3.i = value7
                    value5 = value3.samples
                    value7 = value3.i
                    value5[value7] = value16
                    value13 = globals.math.min
                    value7 = value3.n
                    value14 = (value7 + (1))
                    value15 = 12
                    value13 = value13(value14, value15)
                    value3.n = value13
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.deathRatioForAggression = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value22, value23

        tmp_X = {...}
        value22, value23 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value1 = value22.stats[value23]
        value2 = (value1.kills + value1.deaths)
        if (not (value2 == 0)) then
            value1 = (value1.deaths / value2)
            return value1
        end
        return -1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.watchEncounterDeaths = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value9, value11, value12, value13

        tmp_X = {...}
        value9 = rawget(tmp_X, 1)
        if value9 then
            value12 = value9
            value2 = value12.FindFirstChildOfClass
            value13 = "Humanoid"
            value11 = value2
            value9 = (value11(value12, value13))
            if value9 then
                value12 = value9.HealthChanged
                lifecycle.connect(value12, (Functions.helper_1600({catalogCell = captures.catalogCell, slot2 = captures.slot2}, globals)))
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1001 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value31

        tmp_X = {...}
        value31 = rawget(tmp_X, 1)
        value2 = (captures.slot1.stats[value31].kills + captures.slot1.stats[value31].deaths)
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.sendQueueReady = function(captures, globals)
    local function recovered(...)
        local value5, value6, value7, value9

        value6 = globals.game
        value9 = value6.GetService
        value7 = "ReplicatedStorage"
        value5 = value9
        value7 = (value5(value6, value7)).Remotes.Arena.Ready
        value7.FireServer(value7, true)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.buildNavigationGraph = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_I, tmp_X, tmp_cache_r, tmp_key, tmp_n, tmp_value, loopExit_188, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value12, value13, value23, value24, value25, value26, value27, value28, value29

        tmp_X = {...}
        value29 = rawget(tmp_X, 1)
        value2 = value29.Y
        tmp_X = captures.slot1
        writeCell(tmp_X, value2)
        value2 = {}
        tmp_X = captures.slot2
        writeCell(tmp_X, value2)
        value2 = {}
        tmp_X = captures.slot3
        writeCell(tmp_X, value2)
        value11 = {}
        tmp_X = captures.slot4
        value12 = readCell(tmp_X)(value29)
        value2 = globals.ipairs
        tmp_X = captures.slot5
        value3 = readCell(tmp_X)
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                if value4 then
                    value5 = value4.Parent
                    if value5 then
                        value26 = globals.math.max
                        value27 = value4.Size.X
                        value28 = value4.Size.Z
                        value5 = ((value26(value27, value28)) * 0.5)
                        value6 = globals.math.abs((value4.Position.Y - value29.Y))
                        value7 = value4.Size.Y
                        value6 = (value6 <= ((value7 * (0.5)) + 3))
                        if value6 then
                            tmp_X = captures.slot4
                            value5 = (((readCell(tmp_X)(value4.Position)) - value12).Magnitude - value5)
                            value6 = (value5 <= 50)
                            if value6 then
                                globals.table.insert(value11, value4)
                                value5 = globals.ipairs
                                tmp_X = captures.slot7
                                value6 = readCell(tmp_X)
                                tmp_n = table.pack(value6(value4))
                                tmp_I = tmp_n.n
                                tmp_cache_r = table.pack(value5(table.unpack(tmp_n, 1, tmp_n.n)))
                                value5, value6, value7 = rawget(tmp_cache_r, 1), rawget(tmp_cache_r, 2), rawget(tmp_cache_r, 3)
                                loop = {parent = loop, iterator = iterateValues(value5, value6, value7)}
                                while true do
                                    loopContinues, tmp_key, tmp_value = loop.iterator()
                                    if loopContinues then
                                        value6, value7 = tmp_key, tmp_value
                                    end
                                    if loopContinues then
                                        value25 = globals.Vector3.new
                                        value26 = value7.X
                                        tmp_X = captures.slot1
                                        value27 = readCell(tmp_X)
                                        value28 = value7.Z
                                        value25 = value25(value26, value27, value28)
                                        value28 = globals.workspace
                                        value27 = value28.GetPartBoundsInRadius
                                        value26 = 0.45
                                        value8 = captures.slot8
                                        value23 = value27
                                        value24 = value28
                                        value27 = value8
                                        value8 = (# (value23(value24, value25, value26, value27)))
                                        if (0 < value8) then
                                            value8 = globals.table.insert
                                            tmp_X = captures.slot3
                                            value8((readCell(tmp_X)), value7)
                                            continue
                                        else
                                            value8 = globals.ipairs
                                            tmp_X = captures.slot2
                                            value9 = readCell(tmp_X)
                                            value8, value9, value10 = value8(value9)
                                            loop = {parent = loop, iterator = iterateValues(value8, value9, value10)}
                                            while true do
                                                value13 = false
                                                loopContinues, tmp_key, tmp_value = loop.iterator()
                                                if loopContinues then
                                                    value9, value10 = tmp_key, tmp_value
                                                end
                                                if loopContinues then
                                                    if ((value10 - value7).Magnitude < 1) then
                                                        loopExit_188 = 194
                                                        break
                                                    else
                                                        continue
                                                    end
                                                else
                                                    loopExit_188 = 191
                                                    break
                                                end
                                            end
                                            if (loopExit_188 == 191) then
        
                                            elseif (loopExit_188 == 194) then
                                                value13 = true
                                            end
                                            loop = loop.parent
                                            if (not value13) then
                                                value9 = globals.table.insert
                                                tmp_X = captures.slot2
                                                value9((readCell(tmp_X)), value7)
                                                continue
                                            else
                                                continue
                                            end
                                        end
                                    else
                                        break
                                    end
                                end
                                loop = loop.parent
                                continue
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        continue
                    end
                else
                    value5 = value4
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        captures.slot9.FilterDescendantsInstances = value11
        tmp_X = captures.slot2
        value28 = (# (readCell(tmp_X)))
        value2 = {}
        tmp_X = captures.slot10
        writeCell(tmp_X, value2)
        value27 = 1
        value29 = 1
        loop = {parent = loop, index = (value27 - value29), limit = value28, step = value29}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value2 = loop.index
            end
            if loopContinues then
                value4 = {}
                tmp_X = captures.slot10
                readCell(tmp_X)[value2] = value4
                continue
            else
                break
            end
        end
        loop = loop.parent
        value27 = 1
        value29 = 1
        loop = {parent = loop, index = (value27 - value29), limit = value28, step = value29}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value5 = loop.index
            end
            if loopContinues then
                value27 = (value5 + 1)
                value29 = 1
                loop = {parent = loop, index = (value27 - value29), limit = value28, step = value29}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value6 = loop.index
                    end
                    if loopContinues then
                        tmp_X = captures.slot11
                        value2 = readCell(tmp_X)
                        tmp_X = captures.slot2
                        value3 = readCell(tmp_X)[value5]
                        tmp_X = captures.slot2
                        value4 = readCell(tmp_X)[value6]
                        value2 = value2(value3, value4)
                        tmp_X = captures.slot10
                        value3 = readCell(tmp_X)[value5]
                        value3[value6] = value2
                        tmp_X = captures.slot10
                        value3 = readCell(tmp_X)[value6]
                        value3[value5] = value2
                        continue
                    else
                        break
                    end
                end
                loop = loop.parent
                continue
            else
                break
            end
        end
        loop = loop.parent
        value2 = {}
        tmp_X = captures.slot12
        writeCell(tmp_X, value2)
        value27 = 1
        value29 = 1
        loop = {parent = loop, index = (value27 - value29), limit = value28, step = value29}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value2 = loop.index
            end
            if loopContinues then
                value3 = 0
                value27 = 337.5
                value26 = 0
                value28 = 22.5
                loop = {parent = loop, index = (value26 - value28), limit = value27, step = value28}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value4 = loop.index
                    end
                    if loopContinues then
                        value25 = globals.CFrame.Angles
                        value27 = globals.math.rad(value4)
                        value26 = 0
                        value28 = 0
                        value27 = (value25(value26, value27, value28)).LookVector
                        tmp_X = captures.slot13
                        value25 = readCell(tmp_X)
                        tmp_X = captures.slot2
                        value26 = readCell(tmp_X)[value2]
                        value28 = captures.slot14.PROBE
                        value4 = ((value25(value26, value27, value28)) >= captures.slot14.ESCAPE)
                        if value4 then
                            value4 = 1
                            value3 = (value3 + value4)
                            continue
                        else
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                tmp_X = captures.slot12
                readCell(tmp_X)[value2] = value3
                continue
            else
                break
            end
        end
        loop = loop.parent
        value2 = globals.tick()
        tmp_X = captures.slot15
        writeCell(tmp_X, value2)
        tmp_X = captures.slot16
        readCell(tmp_X)()
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.steerAroundTarget = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value6, value7, value8, value10, value11, value12, value13, value14, value15, value16, value18, value19, value20, value21, value22, value23

        tmp_X = {...}
        value6, value7, value8 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value2 = captures.slot1
        value10 = false
        value2.goodWindow = value10
        tmp_X = captures.slot3
        writeCell(tmp_X, true)
        tmp_X = captures.slot4
        writeCell(tmp_X, true)
        value18 = globals.Vector3.new
        value20 = 0
        value19 = 2.5
        value21 = (- 2.5)
        value18 = value18(value19, value20, value21)
        value19 = globals.Vector3.new
        value20 = value6.Torso.Position.X
        value21 = captures.slot5.Torso.Position.Y
        value22 = value6.Torso.Position.Z
        value19 = value19(value20, value21, value22)
        value2 = (captures.slot5.Torso.Position - value19)
        value19 = globals.Vector3.new
        value20 = value2.X
        value22 = value2.Z
        value21 = 0
        value22 = (value19(value20, value21, value22)).Unit
        value19 = globals.CFrame.lookAt
        value20 = captures.slot5.Torso.Position
        value21 = (captures.slot5.Torso.Position + value22)
        value19 = value19(value20, value21)
        value21 = value19
        value20 = value21.VectorToObjectSpace
        value20 = value20(value21, value22)
        value10 = globals.Vector3.new
        value11 = value18.X
        value13 = value18.Z
        value12 = 0
        value4 = (value10(value11, value12, value13)).Unit
        value2 = globals.math.atan2
        value21 = ((value4.X * value20.Z) - (value4.Z * value20.X))
        value22 = ((value4.X * value20.X) + (value4.Z * value20.Z))
        value20 = value2
        value20 = value20(value21, value22)
        value2 = globals.CFrame.Angles
        value21 = 0
        value22 = (- value20)
        value23 = 0
        value20 = value2
        value18 = (value19 * (value20(value21, value22, value23)))
        tmp_X = captures.slot6
        value4 = readCell(tmp_X)(value6.Torso.AssemblyLinearVelocity)
        tmp_X = captures.slot6
        value2 = readCell(tmp_X)((value6.Torso.Position - captures.slot5.Torso.Position))
        value19 = (value2.Magnitude > 0)
        if value19 then
            value19 = value2.Unit
            if (not value19) then
                value2 = globals.Vector3.new
                value20 = 0
                value22 = 1
                value21 = 0
                value19 = value2
                value19 = value19(value20, value21, value22)
            end
        else
            value2 = globals.Vector3.new
            value20 = 0
            value22 = 1
            value21 = 0
            value19 = value2
            value19 = value19(value20, value21, value22)
        end
        value22 = value4
        value21 = value22.Dot
        value23 = value19
        value21 = value21(value22, value23)
        tmp_X = captures.slot7
        if ((readCell(tmp_X))) then
            value4 = (value21 > (0.5))
            if value4 then
                value4 = false
                tmp_X = captures.slot7
                writeCell(tmp_X, value4)
            end
        else
            if (value21 < (- 1)) then
                tmp_X = captures.slot7
                writeCell(tmp_X, true)
            end
        end
        tmp_X = captures.slot8
        if ((readCell(tmp_X)) == nil) then
            tmp_X = captures.slot8
            writeCell(tmp_X, value21)
        end
        tmp_X = captures.slot8
        value2 = readCell(tmp_X)
        tmp_X = captures.slot8
        value2 = (value2 + ((value21 - (readCell(tmp_X))) * captures.slot9.chaseSmooth))
        tmp_X = captures.slot8
        writeCell(tmp_X, value2)
        tmp_X = captures.slot10
        value2 = readCell(tmp_X)
        if value2 then
            tmp_X = captures.slot8
            if ((readCell(tmp_X)) < captures.slot9.chaseExit) then
                tmp_X = captures.slot10
                writeCell(tmp_X, false)
            end
        else
            tmp_X = captures.slot8
            value2 = readCell(tmp_X)
            if (captures.slot9.chaseEnter < value2) then
                tmp_X = captures.slot10
                writeCell(tmp_X, true)
            end
        end
        value2 = 3.7
        tmp_X = captures.slot7
        value4 = readCell(tmp_X)
        tmp_X = captures.slot7
        value10 = readCell(tmp_X)
        if value4 then
            value10 = 0.5
        end
        if (not value10) then
            value10 = 0
        end
        value2 = (value2 + value10)
        if (value7 < 0.5) then
            value7 = 0
        end
        value2 = ((value2 + (2 * value7)) + captures.slot11.WAVEROUT)
        if captures.slot11.ON then
            value13 = globals.math.max
            value15 = (value2 + captures.slot11.waverJitter)
            value14 = 1.5
            value2 = (value13(value14, value15))
        end
        value4 = captures.slot5.Humanoid
        value10 = false
        value4.AutoRotate = value10
        value4 = captures.slot5.Torso.Position
        value7 = value6.Torso.Position
        value14 = value7.Y
        value12 = globals.Vector3.new
        value13 = value4.X
        value15 = value4.Z
        value4 = (value12(value13, value14, value15))
        value12 = globals.Vector3.new
        value13 = value7.X
        value15 = value7.Z
        value12 = value12(value13, value14, value15)
        value7 = (value4 - value12)
        if (not value8) then
            tmp_X = captures.slot12
            value10 = readCell(tmp_X)
            value11 = value4
            value8 = (value10(value11, value12))
        end
        value10 = value7.Magnitude
        if (not (value8 == 0)) then
            tmp_X = captures.slot13
            value4 = readCell(tmp_X)
            if value4 then
                if (value8 <= (value2 - 0.5)) then
                    tmp_X = captures.slot13
                    writeCell(tmp_X, false)
                end
            else
                value4 = (value8 > (value2 + 1.5))
                if value4 then
                    value4 = true
                    tmp_X = captures.slot13
                    writeCell(tmp_X, value4)
                end
            end
            value19 = (value10 > (0.01))
            if value19 then
                value19 = (value7 / value10)
                if (not value19) then
                    value4 = globals.Vector3.new
                    value20 = 0
                    value21 = 0
                    value22 = 1
                    value19 = value4
                    value19 = value19(value20, value21, value22)
                end
            else
                value4 = globals.Vector3.new
                value20 = 0
                value21 = 0
                value22 = 1
                value19 = value4
                value19 = value19(value20, value21, value22)
            end
            tmp_X = captures.slot13
            value4 = readCell(tmp_X)
            tmp_X = captures.slot13
            value7 = readCell(tmp_X)
            if (not value4) then
                tmp_X = captures.slot10
                value4 = readCell(tmp_X)
                tmp_X = captures.slot10
                value7 = readCell(tmp_X)
                if value4 then
                    value7 = (value8 > (value2 + captures.slot9.chaseBand))
                end
            end
            value4 = captures.slot1
            if value7 then
                tmp_X = captures.slot13
                value13 = readCell(tmp_X)
                tmp_X = captures.slot13
                value14 = readCell(tmp_X)
                if value13 then
                    value14 = "charge"
                end
                if (not value14) then
                    value14 = "chase"
                end
            else
                value14 = "hold"
            end
            value4.waverMode = value14
            if value7 then
                captures.slot11.waverSteer = nil
                if captures.slot9.chargeAtVictim then
                    value11 = value12
                else
                    value11 = (value12 + (value19 * value2))
                end
                value4 = 2334
                tmp_X = captures.sentinelACell
                if value7 then
                    value15 = value7
                else
                    value15 = (value8 > (4.2))
                end
                if captures.slot11.ON then
                    if value7 then
                        value18 = true
                    else
                        if (value10 > captures.slot11.WAVERFACE) then
                            value18 = true
                        end
                    end
                end
                tmp_X = captures.slot19
                value10 = readCell(tmp_X)
                value13 = (value2 + 0.5)
                value12 = value18
                value14 = value6
                value10(value11, value12, value13, value14, value15)
                tmp_X = captures.slot20
                value2 = readCell(tmp_X)
                if (value2 == true) then
                    value2 = captures.slot5.Torso.CFrame.LookVector
                    value4 = captures.slot5.Torso
                    value19 = globals.CFrame.new
                    value22 = 34
                    value20 = 117
                    value21 = 49.5
                    value19 = value19(value20, value21, value22)
                    value4.CFrame = value19
                    value4 = captures.slot5.Torso
                    value20 = globals.CFrame.lookAt
                    value21 = captures.slot5.Torso.Position
                    value22 = (captures.slot5.Torso.Position + value2)
                    value20 = value20(value21, value22)
                    value4.CFrame = value20
                end
            else
                value4 = (value19 * ((- (value8 - value2)) * captures.slot9.orbitCorrect))
                tmp_X = captures.sentinelBCell
                value20 = globals.Vector3.new
                value21 = (- value19.Z)
                value22 = 0
                value23 = value19.X
                value13 = ((value20(value21, value22, value23)) * (globals.math.sin(((globals.tick()) * captures.slot9.orbitRate))))
                value4 = (value4 + (value13 * captures.slot9.orbitSpeed))
                value13 = value4.Magnitude
                value21 = (value13 > (0))
                if value21 then
                    value21 = value4.Unit
                    if (not value21) then
                        value21 = value19
                    end
                else
                    value21 = value19
                end
                value4 = captures.slot11.ON
                if value4 then
                    value4 = (captures.slot11.WAVERSMOOTH > 0)
                    if value4 then
                        value4 = captures.slot11.waverSteer
                        if value4 then
                            value4 = (captures.slot11.waverSteer.Magnitude > 0.001)
                            if value4 then
                                value20 = captures.slot11.waverSteer
                                value4 = value20.Lerp
                                value22 = captures.slot11.WAVERSMOOTH
                                value19 = value4
                                value19 = value19(value20, value21, value22)
                                value4 = value19.Magnitude
                                if (not (0.001 < value4)) then
                                    captures.slot11.waverSteer = value21
                                    value14 = globals.math.atan2
                                    value15 = value21.X
                                    value16 = value21.Z
                                    value14 = value14(value15, value16)
                                    tmp_X = captures.slot18
                                    value11 = (readCell(tmp_X))
                                    value13 = value2
                                    value11 = value11(value12, value13, value14)
                                    if value7 then
                                        value15 = value7
                                    else
                                        value15 = (value8 > (4.2))
                                    end
                                    if captures.slot11.ON then
                                        if value7 then
                                            value18 = true
                                        else
                                            if (value10 > captures.slot11.WAVERFACE) then
                                                value18 = true
                                            end
                                        end
                                    end
                                    tmp_X = captures.slot19
                                    value10 = readCell(tmp_X)
                                    value13 = (value2 + 0.5)
                                    value12 = value18
                                    value14 = value6
                                    value10(value11, value12, value13, value14, value15)
                                    tmp_X = captures.slot20
                                    value2 = readCell(tmp_X)
                                    if (value2 == true) then
                                        value2 = captures.slot5.Torso.CFrame.LookVector
                                        value4 = captures.slot5.Torso
                                        value19 = globals.CFrame.new
                                        value22 = 34
                                        value20 = 117
                                        value21 = 49.5
                                        value19 = value19(value20, value21, value22)
                                        value4.CFrame = value19
                                        value4 = captures.slot5.Torso
                                        value20 = globals.CFrame.lookAt
                                        value21 = captures.slot5.Torso.Position
                                        value22 = (captures.slot5.Torso.Position + value2)
                                        value20 = value20(value21, value22)
                                        value4.CFrame = value20
                                    end
                                else
                                    value21 = value19.Unit
                                    tmp_X = captures.authAliveCell
                                    value4 = (not (readCell(tmp_X)))
                                    if (not value4) then
                                        captures.slot11.waverSteer = value21
                                        value14 = globals.math.atan2
                                        value15 = value21.X
                                        value16 = value21.Z
                                        value14 = value14(value15, value16)
                                        tmp_X = captures.slot18
                                        value11 = (readCell(tmp_X))
                                        value13 = value2
                                        value11 = value11(value12, value13, value14)
                                        if value7 then
                                            value15 = value7
                                        else
                                            value15 = (value8 > (4.2))
                                        end
                                        if captures.slot11.ON then
                                            if value7 then
                                                value18 = true
                                            else
                                                if (value10 > captures.slot11.WAVERFACE) then
                                                    value18 = true
                                                end
                                            end
                                        end
                                        tmp_X = captures.slot19
                                        value10 = readCell(tmp_X)
                                        value13 = (value2 + 0.5)
                                        value12 = value18
                                        value14 = value6
                                        value10(value11, value12, value13, value14, value15)
                                        tmp_X = captures.slot20
                                        value2 = readCell(tmp_X)
                                        if (value2 == true) then
                                            value2 = captures.slot5.Torso.CFrame.LookVector
                                            value4 = captures.slot5.Torso
                                            value19 = globals.CFrame.new
                                            value22 = 34
                                            value20 = 117
                                            value21 = 49.5
                                            value19 = value19(value20, value21, value22)
                                            value4.CFrame = value19
                                            value4 = captures.slot5.Torso
                                            value20 = globals.CFrame.lookAt
                                            value21 = captures.slot5.Torso.Position
                                            value22 = (captures.slot5.Torso.Position + value2)
                                            value20 = value20(value21, value22)
                                            value4.CFrame = value20
                                        end
                                    end
                                end
                            else
                                captures.slot11.waverSteer = value21
                                value14 = globals.math.atan2
                                value15 = value21.X
                                value16 = value21.Z
                                value14 = value14(value15, value16)
                                tmp_X = captures.slot18
                                value11 = (readCell(tmp_X))
                                value13 = value2
                                value11 = value11(value12, value13, value14)
                                if value7 then
                                    value15 = value7
                                else
                                    value15 = (value8 > (4.2))
                                end
                                if captures.slot11.ON then
                                    if value7 then
                                        value18 = true
                                    else
                                        if (value10 > captures.slot11.WAVERFACE) then
                                            value18 = true
                                        end
                                    end
                                end
                                tmp_X = captures.slot19
                                value10 = readCell(tmp_X)
                                value13 = (value2 + 0.5)
                                value12 = value18
                                value14 = value6
                                value10(value11, value12, value13, value14, value15)
                                tmp_X = captures.slot20
                                value2 = readCell(tmp_X)
                                if (value2 == true) then
                                    value2 = captures.slot5.Torso.CFrame.LookVector
                                    value4 = captures.slot5.Torso
                                    value19 = globals.CFrame.new
                                    value22 = 34
                                    value20 = 117
                                    value21 = 49.5
                                    value19 = value19(value20, value21, value22)
                                    value4.CFrame = value19
                                    value4 = captures.slot5.Torso
                                    value20 = globals.CFrame.lookAt
                                    value21 = captures.slot5.Torso.Position
                                    value22 = (captures.slot5.Torso.Position + value2)
                                    value20 = value20(value21, value22)
                                    value4.CFrame = value20
                                end
                            end
                        else
                            captures.slot11.waverSteer = value21
                            value14 = globals.math.atan2
                            value15 = value21.X
                            value16 = value21.Z
                            value14 = value14(value15, value16)
                            tmp_X = captures.slot18
                            value11 = (readCell(tmp_X))
                            value13 = value2
                            value11 = value11(value12, value13, value14)
                            if value7 then
                                value15 = value7
                            else
                                value15 = (value8 > (4.2))
                            end
                            if captures.slot11.ON then
                                if value7 then
                                    value18 = true
                                else
                                    if (value10 > captures.slot11.WAVERFACE) then
                                        value18 = true
                                    end
                                end
                            end
                            tmp_X = captures.slot19
                            value10 = readCell(tmp_X)
                            value13 = (value2 + 0.5)
                            value12 = value18
                            value14 = value6
                            value10(value11, value12, value13, value14, value15)
                            tmp_X = captures.slot20
                            value2 = readCell(tmp_X)
                            if (value2 == true) then
                                value2 = captures.slot5.Torso.CFrame.LookVector
                                value4 = captures.slot5.Torso
                                value19 = globals.CFrame.new
                                value22 = 34
                                value20 = 117
                                value21 = 49.5
                                value19 = value19(value20, value21, value22)
                                value4.CFrame = value19
                                value4 = captures.slot5.Torso
                                value20 = globals.CFrame.lookAt
                                value21 = captures.slot5.Torso.Position
                                value22 = (captures.slot5.Torso.Position + value2)
                                value20 = value20(value21, value22)
                                value4.CFrame = value20
                            end
                        end
                    else
                        captures.slot11.waverSteer = value21
                        value14 = globals.math.atan2
                        value15 = value21.X
                        value16 = value21.Z
                        value14 = value14(value15, value16)
                        tmp_X = captures.slot18
                        value11 = (readCell(tmp_X))
                        value13 = value2
                        value11 = value11(value12, value13, value14)
                        if value7 then
                            value15 = value7
                        else
                            value15 = (value8 > (4.2))
                        end
                        if captures.slot11.ON then
                            if value7 then
                                value18 = true
                            else
                                if (value10 > captures.slot11.WAVERFACE) then
                                    value18 = true
                                end
                            end
                        end
                        tmp_X = captures.slot19
                        value10 = readCell(tmp_X)
                        value13 = (value2 + 0.5)
                        value12 = value18
                        value14 = value6
                        value10(value11, value12, value13, value14, value15)
                        tmp_X = captures.slot20
                        value2 = readCell(tmp_X)
                        if (value2 == true) then
                            value2 = captures.slot5.Torso.CFrame.LookVector
                            value4 = captures.slot5.Torso
                            value19 = globals.CFrame.new
                            value22 = 34
                            value20 = 117
                            value21 = 49.5
                            value19 = value19(value20, value21, value22)
                            value4.CFrame = value19
                            value4 = captures.slot5.Torso
                            value20 = globals.CFrame.lookAt
                            value21 = captures.slot5.Torso.Position
                            value22 = (captures.slot5.Torso.Position + value2)
                            value20 = value20(value21, value22)
                            value4.CFrame = value20
                        end
                    end
                else
                    captures.slot11.waverSteer = value21
                    value14 = globals.math.atan2
                    value15 = value21.X
                    value16 = value21.Z
                    value14 = value14(value15, value16)
                    tmp_X = captures.slot18
                    value11 = (readCell(tmp_X))
                    value13 = value2
                    value11 = value11(value12, value13, value14)
                    if value7 then
                        value15 = value7
                    else
                        value15 = (value8 > (4.2))
                    end
                    if captures.slot11.ON then
                        if value7 then
                            value18 = true
                        else
                            if (value10 > captures.slot11.WAVERFACE) then
                                value18 = true
                            end
                        end
                    end
                    tmp_X = captures.slot19
                    value10 = readCell(tmp_X)
                    value13 = (value2 + 0.5)
                    value12 = value18
                    value14 = value6
                    value10(value11, value12, value13, value14, value15)
                    tmp_X = captures.slot20
                    value2 = readCell(tmp_X)
                    if (value2 == true) then
                        value2 = captures.slot5.Torso.CFrame.LookVector
                        value4 = captures.slot5.Torso
                        value19 = globals.CFrame.new
                        value22 = 34
                        value20 = 117
                        value21 = 49.5
                        value19 = value19(value20, value21, value22)
                        value4.CFrame = value19
                        value4 = captures.slot5.Torso
                        value20 = globals.CFrame.lookAt
                        value21 = captures.slot5.Torso.Position
                        value22 = (captures.slot5.Torso.Position + value2)
                        value20 = value20(value21, value22)
                        value4.CFrame = value20
                    end
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1073 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value4, value8, value9

        tmp_X = {...}
        value8, value9 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value4 = (value8.dist < value9.dist)
        return value4
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1076 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value15, value16, value17, value18

        tmp_X = {...}
        value17 = rawget(tmp_X, 1)
        value2 = globals.math.max
        tmp_X = captures.slot1
        value15 = readCell(tmp_X)
        value18 = captures.slot3.SIDE_STEP
        value16 = captures.slot2
        value4 = ((value15(value16, value17, value18)) - captures.slot3.WALL_BUFFER)
        return value2(0, value4)
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.selectProfile = function(captures, globals)
    return function(profileName)
        local registry = readCell(captures.registryCell)
        if globals.type(profileName) == "string" and registry.brains[profileName] then
            registry.selected = profileName
        end
        return registry.selected
    end
end

Functions.helper_1111 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value25, value26, value27, value28, value29, value31

        tmp_X = {...}
        value26, value27, value28 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        tmp_X = captures.slot1
        value1 = ((readCell(tmp_X)) == value31)
        if value1 then
            tmp_X = captures.slot1
            writeCell(tmp_X, value26)
            tmp_X = captures.slot2
            writeCell(tmp_X, value27)
        else
            tmp_X = captures.slot2
            value1 = (value27 ~= (readCell(tmp_X)))
            if value1 then
                tmp_X = captures.slot1
                writeCell(tmp_X, value26)
                tmp_X = captures.slot2
                writeCell(tmp_X, value27)
            else
                value27 = globals.math.max
                value29 = 0.004166666666666667
                value28 = (40 * (value27(value28, value29)))
                tmp_X = captures.slot1
                value1 = readCell(tmp_X)
                value25 = globals.math.clamp
                tmp_X = captures.slot1
                value26 = (value26 - (readCell(tmp_X)))
                value27 = (- value28)
                value1 = (value1 + (value25(value26, value27, value28)))
                tmp_X = captures.slot1
                writeCell(tmp_X, value1)
            end
        end
        tmp_X = captures.slot1
        value1 = readCell(tmp_X)
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1121 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, loopExit_35, value2, value3, value4, value6, value10

        value6 = captures.slot1.FANAKA_DEBUG
        if value6 then
            value6 = captures.slot1.FANAKA_DEBUG[captures.slot2]
            if value6 then
                value6 = value6[captures.slot3]
                if value6 then
                    if (not value6.locked) then
                        value2 = captures.slot4[1]
                    else
                        value2 = globals.ipairs
                        value3 = captures.slot4
                        value2, value3, value4 = value2(value3)
                        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
                        while true do
                            value10 = 1
                            loopContinues, tmp_key, tmp_value = loop.iterator()
                            if loopContinues then
                                value3, value4 = tmp_key, tmp_value
                            end
                            if loopContinues then
                                if (value4 == value6.style) then
                                    loopExit_35 = 40
                                    break
                                else
                                    continue
                                end
                            else
                                loopExit_35 = 38
                                break
                            end
                        end
                        if (loopExit_35 == 38) then
        
                        elseif (loopExit_35 == 40) then
                            value10 = value3
                        end
                        loop = loop.parent
                        value2 = (value10 >= (# captures.slot4))
                        if value2 then
                            value2 = "auto"
                        else
                            value2 = captures.slot4[(value10 + 1)]
                        end
                    end
                else
                    value2 = captures.slot4[1]
                end
            else
                value2 = captures.slot4[1]
            end
        else
            value2 = captures.slot4[1]
        end
        tmp_X = captures.slot5
        value3 = (readCell(tmp_X)())[captures.slot6]
        value4 = captures.slot3
        value3[value4] = value2
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.getSettings = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value5, value6, value8, value12

        value8 = captures.slot1.FANAKA_CONFIG
        if ((globals.type(value8)) ~= "table") then
            value8 = {}
            captures.slot1.FANAKA_CONFIG = value8
        end
        if (value8.randomiseLoseLose == value12) then
            value5 = true
            value8.randomiseLoseLose = value5
        end
        if (value8.defaultLoseLoseStyle ~= "grab") then
            if (value8.defaultLoseLoseStyle ~= "run") then
                value8.defaultLoseLoseStyle = "run"
            end
        end
        if ((globals.type(value8.loseLoseStyleOverride)) ~= "table") then
            value5 = {}
            value8.loseLoseStyleOverride = value5
        end
        if ((globals.type(value8.reachAdjust)) ~= "table") then
            value6 = {}
            value8.reachAdjust = value6
        end
        if (value8.randomiseAggro == nil) then
            value8.randomiseAggro = false
        end
        tmp_X = captures.slot3
        value4 = readCell(tmp_X)
        value6 = value8.defaultAggroStyle
        value5 = captures.slot4
        if (not (value4(value5, value6))) then
            value5 = "aggressive"
            value8.defaultAggroStyle = value5
        end
        value4 = globals.type(value8.aggroStyleOverride)
        value5 = "table"
        if (value4 ~= value5) then
            value5 = {}
            value8.aggroStyleOverride = value5
        end
        if (value8.randomiseOpening == nil) then
            value8.randomiseOpening = true
        end
        tmp_X = captures.slot3
        value4 = readCell(tmp_X)
        value6 = value8.defaultOpeningStyle
        value5 = captures.slot5
        if (not (value4(value5, value6))) then
            value8.defaultOpeningStyle = "corner"
        end
        if ((globals.type(value8.openingStyleOverride)) ~= "table") then
            value5 = {}
            value8.openingStyleOverride = value5
        end
        if (value8.engine == nil) then
            value5 = "maximum"
            value8.engine = value5
        end
        if (value8.autoQueue == nil) then
            tmp_X = captures.sentinelACell
            value8.autoQueue = false
        end
        if (value8.autoQueueFind == nil) then
            value8.autoQueueFind = true
        end
        if (value8.autoQueueArena ~= "2") then
            if (value8.autoQueueArena ~= "4") then
                if (value8.autoQueueArena ~= "6") then
                    if (value8.autoQueueArena ~= "none") then
                        value5 = "none"
                        value8.autoQueueArena = value5
                    end
                end
            end
        end
        value4 = value8.autoQueueSide
        if (value4 ~= "either") then
            if (value8.autoQueueSide ~= "left") then
                if (value8.autoQueueSide ~= "right") then
                    value5 = "either"
                    value8.autoQueueSide = value5
                end
            end
        end
        return value8
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1132 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value27, value28, value29, value30, value31, value32

        tmp_X = {...}
        value29, value30 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value28 = globals.workspace
        value1 = value28.Spherecast
        value31 = (value30 * 200)
        value30 = 0.5
        value32 = captures.slot1
        value27 = value1
        value27 = value27(value28, value29, value30, value31, value32)
        if value27 then
            value1 = value27.Distance
            value3 = value27.Normal
            return value1, value3
        end
        return 200, nil
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.countQueueSide = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, value1, value2, value3, value5, value19, value20, value21, value22, value23

        tmp_X = {...}
        value20, value21, value22 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value1 = 1
        value2 = 4
        value3 = 1
        value5 = 0
        loop = {parent = loop, index = (value1 - value3), limit = value2, step = value3}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value23 = loop.index
            end
            if loopContinues then
                value1 = captures.slot2.slotPlayer
                value19 = captures.slot2.slotPad
                value19 = table.pack(value19(table.unpack({[20] = value20, [21] = value21, [22] = value22, [23] = value23}, 20, 23)))
                if ((value1(table.unpack(value19, 1, value19.n))) ~= nil) then
                    value5 = (value5 + 1)
                    continue
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        return value5
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1150 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, value2, value3, value4, value5, value6, value8, value9, value10, value11, value12, value13, value14, value15, value16, value29, value30, value31, value32, value33

        tmp_X = {...}
        value31, value32, value33 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        tmp_X = captures.slot1
        value8 = readCell(tmp_X)
        value9 = {}
        value2 = globals.UDim2.new
        value3 = 1
        value4 = 0
        value5 = 0
        value6 = 28
        value2 = value2(value3, value4, value5, value6)
        value9.Size = value2
        value29 = globals.UDim2.fromOffset
        value30 = 0
        value29 = value29(value30, value31)
        value9.Position = value29
        value3 = captures.slot2.panel2
        value9.BackgroundColor3 = value3
        value3 = 0
        value9.BorderSizePixel = value3
        value3 = "Frame"
        value5 = captures.slot4
        value2 = value8
        value4 = value9
        value6 = (value2(value3, value4, value5))
        tmp_X = captures.slot5
        readCell(tmp_X)(value6, 6)
        tmp_X = captures.slot1
        value13 = readCell(tmp_X)
        value14 = "TextLabel"
        value5 = {}
        value8 = globals.UDim2.new
        value10 = (- (10))
        value9 = 0.36
        value11 = 1
        value12 = 0
        value8 = value8(value9, value10, value11, value12)
        value5.Size = value8
        value2 = globals.UDim2.fromOffset
        value3 = 10
        value4 = 0
        value2 = value2(value3, value4)
        value5.Position = value2
        value5.BackgroundTransparency = 1
        value3 = globals.Enum.Font.GothamMedium
        value5.Font = value3
        value5.Text = value32
        value3 = captures.slot2.subtext
        value5.TextColor3 = value3
        value5.TextSize = 12
        value3 = globals.Enum.TextXAlignment.Left
        value5.TextXAlignment = value3
        value3 = value13
        value4 = value14
        value3(value4, value5, value6)
        value14 = {}
        value15 = (# value33)
        value31 = (value15 >= 4)
        if value31 then
            value31 = 52
            if (not value31) then
                value31 = 66
            end
        else
            value31 = 66
        end
        value16 = (value31 + 4)
        value2 = globals.ipairs
        value3 = value33
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                tmp_X = captures.slot1
                value5 = readCell(tmp_X)
                value13 = {}
                value30 = globals.UDim2.fromOffset
                value32 = 22
                value30 = value30(value31, value32)
                value13.Size = value30
                value8 = globals.UDim2.new
                value9 = 1
                value10 = ((- (value15 * value16)) + ((value3 - 1) * value16))
                value11 = 0.5
                value12 = (- 11)
                value8 = value8(value9, value10, value11, value12)
                value13.Position = value8
                value9 = captures.slot2.panel
                value13.BackgroundColor3 = value9
                value9 = value4.label
                value13.Text = value9
                value9 = globals.Enum.Font.GothamBold
                value13.Font = value9
                value9 = captures.slot2.subtext
                value13.TextColor3 = value9
                value9 = 12
                value13.TextSize = value9
                value13.AutoButtonColor = true
                value13.BorderSizePixel = 0
                value9 = "TextButton"
                value8 = value5
                value10 = value13
                value11 = value6
                value8 = value8(value9, value10, value11)
                tmp_X = captures.slot5
                readCell(tmp_X)(value8, 6)
                value5 = value4.id
                value14[value5] = value8
                continue
            else
                break
            end
        end
        loop = loop.parent
        return value14
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.queueArenaInProgress = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_Y, tmp_key, tmp_value, loopExit_11, value1, value3, value4, value5, value6, value25, value26, value27, value28, value29

        tmp_X = {...}
        value26, value27 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value3 = globals.ipairs
        value1 = {}
        value6 = "Right"
        value5 = "Left"
        tmp_Y = value1
        table.move({[5] = value5, [6] = value6}, 5, 6, 1, tmp_Y)
        value4 = value1
        value3, value4, value5 = value3(value4)
        loop = {parent = loop, iterator = iterateValues(value3, value4, value5)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value4, value5 = tmp_key, tmp_value
            end
            if loopContinues then
                value1 = captures.slot2.slotPlayer
                value25 = captures.slot2.slotPad
                value29 = 1
                value28 = value5
                value25 = table.pack(value25(table.unpack({[26] = value26, [27] = value27, [28] = value28, [29] = value29}, 26, 29)))
                value1 = value1(table.unpack(value25, 1, value25.n))
                if value1 then
                    if ((captures.slot2.playerActiveArena(value1)) ~= nil) then
                        loopExit_11 = 25
                        break
                    else
                        continue
                    end
                else
                    continue
                end
            else
                loopExit_11 = 18
                break
            end
        end
        if (loopExit_11 == 18) then
            loop = loop.parent
            return false
        elseif (loopExit_11 == 25) then
        
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1166 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_I, tmp_X, tmp_cache_r, tmp_n, value1, value2, value23, value24, value25, value27

        tmp_X = {...}
        value27 = rawget(tmp_X, 1)
        value1 = captures.slot1
        value23 = globals.Vector3.new
        value24 = globals.math.sin(value27)
        value25 = 0
        value2 = globals.math.cos
        tmp_n = table.pack(value2(value27))
        tmp_I = tmp_n.n
        tmp_cache_r = ((3 + tmp_I) - 1)
        tmp_n.n = tmp_cache_r
        table.move(tmp_n, 1, tmp_I, 3, tmp_n)
        table.move({[24] = value24, [25] = value25}, 24, 25, 1, tmp_n)
        tmp_D = table.pack(value23(table.unpack(tmp_n, 1, tmp_n.n)))
        value1 = (value1 + ((rawget(tmp_D, 1)) * captures.slot3))
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.castMovementProbe = function(captures, globals)
    return function(origin, direction, maxDistance)
        maxDistance = maxDistance or (30)
        local hit = globals.workspace:Spherecast(origin, 0.5, direction * maxDistance, captures.raycastParams)
        if not hit then return maxDistance, nil, nil, origin + direction * maxDistance end
        return hit.Distance, hit.Normal, hit.Instance, hit.Position
    end
end

Functions.formatWindowTitle = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value4, value7

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        if value2 then
            value4 = value2.selected
            value7 = value2.brains
            if value7 then
                value7 = value4
                if value7 then
                    value7 = value2.brains[value4]
                    if value7 then
                        value7 = value7.name
                        if (not value7) then
                            value7 = "\226\128\166"
                        end
                    else
                        value7 = "\226\128\166"
                    end
                else
                    value7 = "\226\128\166"
                end
            else
                value7 = "\226\128\166"
            end
        else
            value4 = value2
            if value2 then
                value7 = value2.brains
                if value7 then
                    value7 = value4
                    if value7 then
                        value7 = value2.brains[value4]
                        if value7 then
                            value7 = value7.name
                            if (not value7) then
                                value7 = "\226\128\166"
                            end
                        else
                            value7 = "\226\128\166"
                        end
                    else
                        value7 = "\226\128\166"
                    end
                else
                    value7 = "\226\128\166"
                end
            else
                value7 = "\226\128\166"
            end
        end
        value2 = ("Dracoware Bot " .. (value7 .. " v1.6"))
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1183 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value8

        tmp_X = captures.slot1
        value4 = readCell(tmp_X)()
        value8 = captures.slot2
        value4.autoQueueArena = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1189 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, loopExit_6, value2, value3, value4, value17, value18

        tmp_X = {...}
        value17, value18 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = globals.ipairs
        value3 = value17
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                if (value4 == value18) then
                    loopExit_6 = 9
                    break
                else
                    continue
                end
            else
                loopExit_6 = 10
                break
            end
        end
        if (loopExit_6 == 9) then
        
        elseif (loopExit_6 == 10) then
            loop = loop.parent
            return false
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.handleRespawnDelay = function(captures, globals)
    local function recovered(...)
        local tmp_X

        globals.task.wait(0.5)
        tmp_X = captures.slot1
        writeCell(tmp_X, true)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.queuePadOccupant = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local tmp_D, tmp_X, value5, value22

        tmp_X = {...}
        value22 = rawget(tmp_X, 1)
        R[2] = value5
        globals.pcall((Functions.helper_1984({slot1 = value22, slot2 = captureShared(cells, R, 2)}, globals)))
        closeCaptures(cells, R)
        return R[2]
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.createInterface = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local loop, loopContinues, tmp_I, tmp_Y, tmp_cache_r, tmp_key, tmp_n, tmp_value, value15, value16, value17, value18, value19, value21, value22, value23, value24, value25, value26, value27, value31, value32, value33, value36, value37, value38, value40, value41, value42, value43, value45, value47, value48, value52, value53, value54, value55, value56, value61, value63, value64, value66, value69, value70, value73, value76, value78, value79

        value21 = globals.game
        R[20] = value21.GetService
        R[1] = R[20]
        value22 = "Players"
        R[20] = R[1]
        R[20] = R[20](value21, value22)
        value24 = globals.game
        value23 = value24.GetService
        R[1] = value23
        value25 = "UserInputService"
        value23 = R[1]
        value23 = value23(value24, value25)
        value25 = globals.game
        value24 = value25.GetService
        R[1] = value24
        value26 = "RunService"
        value24 = R[1]
        value24 = value24(value25, value26)
        value55 = R[20].LocalPlayer
        R[1] = globals.getgenv
        if R[1] then
            R[2] = globals.getgenv
            R[1] = R[2]()
            if (not R[1]) then
                R[1] = globals._G
            end
        else
            R[1] = globals._G
        end
        value56 = R[1]
        R[57] = nil
        R[57] = Functions.getRegistry({slot1 = value56}, globals)
        R[58] = nil
        R[58] = Functions.formatWindowTitle({slot1 = captureShared(cells, R, 57)}, globals)
        value25 = {}
        R[20] = "run"
        value19 = "grab"
        tmp_Y = value25
        table.move({[19] = value19, [20] = R[20]}, 19, 20, 1, tmp_Y)
        value26 = {}
        value19 = "aggressive"
        R[20] = "patient"
        tmp_Y = value26
        table.move({[19] = value19, [20] = R[20]}, 19, 20, 1, tmp_Y)
        value27 = {}
        R[20] = "charge"
        value19 = "corner"
        tmp_Y = value27
        table.move({[19] = value19, [20] = R[20]}, 19, 20, 1, tmp_Y)
        R[59] = nil
        R[59] = Functions.helper_1189({}, globals)
        R[60] = nil
        R[60] = Functions.getSettings({slot1 = value56, catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 59), slot4 = value26, slot5 = value27, sentinelACell = captures.sentinelACell}, globals)
        R[29] = nil
        R[29] = Functions.formatStyle({catalogCell = captures.catalogCell}, globals)
        R[28] = nil
        R[28] = Functions.formatOpeningStyle({catalogCell = captures.catalogCell}, globals)
        R[30] = nil
        R[30] = Functions.formatAggression({}, globals)
        value61 = 0.85
        value63 = 3
        value64 = 11
        R[65] = nil
        R[65] = Functions.helper_1716({slot1 = captureShared(cells, R, 60), slot2 = value56, slot3 = value63, slot4 = value61, slot5 = value64, catalogCell = captures.catalogCell}, globals)
        value66 = {}
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 24
        value36 = 24
        value37 = 29
        R[34] = R[34](R[35], value36, value37)
        value66.bg = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 32
        value36 = 33
        value37 = 39
        R[34] = R[34](R[35], value36, value37)
        value66.panel = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 40
        value36 = 41
        value37 = 48
        R[34] = R[34](R[35], value36, value37)
        value66.panel2 = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 88
        value36 = 101
        value37 = 242
        R[34] = R[34](R[35], value36, value37)
        value66.accent = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        value36 = 235
        value37 = 240
        R[35] = 235
        R[34] = R[34](R[35], value36, value37)
        value66.text = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 150
        value36 = 150
        value37 = 162
        R[34] = R[34](R[35], value36, value37)
        value66.subtext = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 80
        value36 = 220
        value37 = 120
        R[34] = R[34](R[35], value36, value37)
        value66.good = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 240
        value36 = 90
        value37 = 90
        R[34] = R[34](R[35], value36, value37)
        value66.bad = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        R[35] = 120
        value36 = 122
        value37 = 132
        R[34] = R[34](R[35], value36, value37)
        value66.idle = R[34]
        R[2] = globals.Color3
        R[34] = R[2].fromRGB
        value36 = 170
        value37 = 60
        R[35] = 230
        R[34] = R[34](R[35], value36, value37)
        value66.lock = R[34]
        R[67] = nil
        R[67] = Functions.roundCorners({}, globals)
        R[68] = nil
        R[68] = Functions.addUIStroke({catalogCell = captures.catalogCell}, globals)
        R[39] = nil
        R[39] = Functions.createUIInstance({}, globals)
        R[1] = Functions.helper_1933({catalogCell = captures.catalogCell, sentinelBCell = captures.sentinelBCell, slot3 = value55}, globals)
        R[2] = value56.FANAKA_UI
        if R[2] then
            R[2] = globals.pcall
            R[3] = Functions.helper_763({slot1 = value56}, globals)
            R[2](R[3])
        end
        R[35] = "ScreenGui"
        value36 = {}
        R[3] = "FanakaBotUI"
        value36.Name = R[3]
        value36.ResetOnSpawn = false
        R[3] = globals.Enum
        R[3] = R[3].ZIndexBehavior
        R[3] = R[3].Sibling
        value36.ZIndexBehavior = R[3]
        value36.DisplayOrder = 9999
        value37 = table.pack(R[1]())
        R[34] = R[39]
        tmp_n = value37
        tmp_I = tmp_n.n
        tmp_n.n = ((3 + tmp_I) - 1)
        table.move(tmp_n, 1, tmp_I, 3, tmp_n)
        table.move({[35] = R[35], [36] = value36}, 35, 36, 1, tmp_n)
        tmp_cache_r = table.pack(R[34](table.unpack(tmp_n, 1, tmp_n.n)))
        R[34] = rawget(tmp_cache_r, 1)
        value56.FANAKA_UI = R[34]
        value32 = "Frame"
        value33 = {}
        value33.Name = "Window"
        R[2] = globals.UDim2
        value36 = R[2].fromOffset
        value37 = 440
        value38 = 524
        value36 = value36(value37, value38)
        value33.Size = value36
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 220
        R[3] = (- R[2])
        R[4] = 0.5
        R[2] = 0.5
        R[5] = (- 262)
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Position = R[1]
        R[2] = value66.bg
        value33.BackgroundColor3 = R[2]
        value33.BorderSizePixel = 0
        value31 = R[39]
        value40 = (value31(value32, value33, R[34]))
        R[1] = 10
        R[67](value40, R[1])
        value33 = {}
        R[2] = value66.panel2
        value33.Color = R[2]
        value33.Thickness = 1
        value33.Transparency = 0.2
        value32 = "UIStroke"
        value31 = R[39]
        R[34] = value40
        value31(value32, value33, R[34])
        value33 = {}
        value33.Name = "TitleBar"
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 1
        R[3] = 0
        R[4] = 0
        R[5] = 36
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Size = R[1]
        R[2] = value66.panel
        value33.BackgroundColor3 = R[2]
        value33.BorderSizePixel = 0
        value32 = "Frame"
        value31 = R[39]
        R[34] = value40
        value41 = (value31(value32, value33, R[34]))
        R[1] = 10
        R[67](value41, R[1])
        value33 = {}
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[4] = 0
        R[2] = 1
        R[3] = 0
        R[5] = 12
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Size = R[1]
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 0
        R[3] = 0
        R[4] = 1
        R[5] = (- 12)
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Position = R[1]
        R[2] = value66.panel
        value33.BackgroundColor3 = R[2]
        value33.BorderSizePixel = 0
        value32 = "Frame"
        value31 = R[39]
        R[34] = value41
        value31(value32, value33, R[34])
        value33 = {}
        R[2] = "Title"
        value33.Name = R[2]
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 1
        R[3] = (- 80)
        R[4] = 1
        R[5] = 0
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Size = R[1]
        R[1] = globals.UDim2
        R[1] = R[1].fromOffset
        R[2] = 14
        R[3] = 0
        R[1] = R[1](R[2], R[3])
        value33.Position = R[1]
        R[2] = 1
        value33.BackgroundTransparency = R[2]
        R[2] = globals.Enum
        R[2] = R[2].Font
        R[2] = R[2].GothamBold
        value33.Font = R[2]
        R[2] = R[58]()
        value33.Text = R[2]
        R[2] = value66.text
        value33.TextColor3 = R[2]
        R[2] = 15
        value33.TextSize = R[2]
        R[2] = globals.Enum
        R[2] = R[2].TextXAlignment
        R[2] = R[2].Left
        value33.TextXAlignment = R[2]
        value32 = "TextLabel"
        value31 = R[39]
        R[34] = value41
        value42 = (value31(value32, value33, R[34]))
        value32 = "TextButton"
        value33 = {}
        value33.Name = "Min"
        R[1] = globals.UDim2
        R[1] = R[1].fromOffset
        R[2] = 28
        R[3] = 24
        R[1] = R[1](R[2], R[3])
        value33.Size = R[1]
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 12
        R[5] = (- R[2])
        R[2] = 1
        R[3] = (- 36)
        R[4] = 0.5
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Position = R[1]
        R[2] = value66.panel2
        value33.BackgroundColor3 = R[2]
        value33.Text = "-"
        R[2] = globals.Enum
        R[2] = R[2].Font
        R[2] = R[2].GothamBold
        value33.Font = R[2]
        R[2] = value66.text
        value33.TextColor3 = R[2]
        R[2] = 16
        value33.TextSize = R[2]
        R[2] = true
        value33.AutoButtonColor = R[2]
        value33.BorderSizePixel = 0
        value31 = R[39]
        R[34] = value41
        value43 = (value31(value32, value33, R[34]))
        R[67](value43, 6)
        value32 = "Frame"
        value33 = {}
        R[2] = "TabBar"
        value33.Name = R[2]
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 1
        R[3] = (- 20)
        R[4] = 0
        R[5] = 30
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Size = R[1]
        R[1] = globals.UDim2
        R[1] = R[1].fromOffset
        R[2] = 10
        R[3] = 44
        R[1] = R[1](R[2], R[3])
        value33.Position = R[1]
        R[2] = 1
        value33.BackgroundTransparency = R[2]
        value31 = R[39]
        R[34] = value40
        value45 = (value31(value32, value33, R[34]))
        value32 = "UIListLayout"
        value33 = {}
        R[2] = globals.Enum
        R[2] = R[2].FillDirection
        R[2] = R[2].Horizontal
        value33.FillDirection = R[2]
        R[1] = globals.UDim
        R[1] = R[1].new
        R[2] = 0
        R[3] = 6
        R[1] = R[1](R[2], R[3])
        value33.Padding = R[1]
        R[2] = globals.Enum
        R[2] = R[2].HorizontalAlignment
        R[2] = R[2].Left
        value33.HorizontalAlignment = R[2]
        R[2] = globals.Enum
        R[2] = R[2].VerticalAlignment
        R[2] = R[2].Center
        value33.VerticalAlignment = R[2]
        value31 = R[39]
        R[34] = value45
        value31(value32, value33, R[34])
        value33 = {}
        value33.Name = "Content"
        R[1] = globals.UDim2
        R[1] = R[1].new
        R[2] = 20
        R[3] = (- R[2])
        R[2] = 1
        R[4] = 1
        R[5] = (- 90)
        R[1] = R[1](R[2], R[3], R[4], R[5])
        value33.Size = R[1]
        R[1] = globals.UDim2
        R[1] = R[1].fromOffset
        R[2] = 10
        R[3] = 80
        R[1] = R[1](R[2], R[3])
        value33.Position = R[1]
        R[2] = value66.panel
        value33.BackgroundColor3 = R[2]
        R[2] = 0
        value33.BorderSizePixel = R[2]
        value32 = "Frame"
        value31 = R[39]
        R[34] = value40
        value47 = (value31(value32, value33, R[34]))
        R[67](value47, 8)
        value69 = {}
        value70 = {}
        R[71] = nil
        R[72] = nil
        R[72] = Functions.selectUITab({slot1 = captureShared(cells, R, 71), slot2 = value69, slot3 = value70, slot4 = value66, catalogCell = captures.catalogCell}, globals)
        R[1] = Functions.helper_167({slot1 = captureShared(cells, R, 39), slot2 = value66, slot3 = value45, slot4 = captureShared(cells, R, 67), catalogCell = captures.catalogCell, slot6 = value47, slot7 = captureShared(cells, R, 68), slot8 = value70, slot9 = value69, authReadyCell = captures.authReadyCell, slot11 = captureShared(cells, R, 72)}, globals)
        R[2] = "Bots"
        R[34] = R[1](R[2])
        value48 = R[1]("Configurables")
        value52 = R[1]("Settings")
        value53 = R[1]("Debug")
        R[2] = "Credits"
        value54 = R[1](R[2])
        R[1] = globals.ipairs
        R[5] = {}
        R[3] = "Configurables"
        R[4] = "Debug"
        R[2] = R[5]
        tmp_Y = R[2]
        table.move({[3] = R[3], [4] = R[4]}, 3, 4, 1, tmp_Y)
        R[2] = R[5]
        R[1], R[2], R[3] = R[1](R[2])
        loop = {parent = loop, iterator = iterateValues(R[1], R[2], R[3])}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                R[2], R[3] = tmp_key, tmp_value
            end
            if loopContinues then
                R[4] = value70[R[3]]
                if R[4] then
                    R[4] = value70[R[3]]
                    R[4].Visible = false
                    continue
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        R[1] = {}
        R[6] = {}
        R[6].id = "maximum"
        R[6].name = "Maximum Engine"
        R[3] = 2000
        R[6].elo = R[3]
        R[6].desc = "The best timebomb duels engine, DESTROY EVERYONE"
        R[7] = {}
        R[7].id = "elite"
        R[7].name = "Elite Engine"
        R[7].elo = 1760
        R[7].desc = "No Top Player can beat this engine on their first attempt"
        R[8] = {}
        R[8].id = "master"
        R[8].name = "Master Engine"
        R[8].elo = 1600
        R[8].desc = "Plays like a Top Player"
        R[9] = {}
        R[9].id = "kevin"
        R[9].name = "Kevin"
        R[3] = 1485
        R[9].elo = R[3]
        R[9].desc = "The most humanlike and realistic engine yet. Plays like someone with thousands of wins."
        R[5] = R[1]
        tmp_Y = R[5]
        table.move({[6] = R[6], [7] = R[7], [8] = R[8], [9] = R[9]}, 6, 9, 1, tmp_Y)
        value73 = {}
        R[74] = nil
        R[74] = Functions.helper_173({slot1 = captureShared(cells, R, 57), catalogCell = captures.catalogCell}, globals)
        R[75] = nil
        R[75] = Functions.helper_1985({slot1 = captureShared(cells, R, 57), slot2 = value73, slot3 = captureShared(cells, R, 74), slot4 = value66, catalogCell = captures.catalogCell}, globals)
        value33 = {}
        R[2] = globals.UDim2
        R[2] = R[2].new
        R[3] = 1
        R[4] = 0
        R[5] = 0
        R[6] = 22
        R[2] = R[2](R[3], R[4], R[5], R[6])
        value33.Size = R[2]
        value33.BackgroundTransparency = 1
        R[3] = globals.Enum
        R[3] = R[3].Font
        R[3] = R[3].GothamBold
        value33.Font = R[3]
        value33.Text = "Bots"
        R[3] = value66.text
        value33.TextColor3 = R[3]
        value33.TextSize = 15
        R[3] = globals.Enum
        R[3] = R[3].TextXAlignment
        R[3] = R[3].Left
        value33.TextXAlignment = R[3]
        value32 = "TextLabel"
        value31 = R[39]
        value31(value32, value33, R[34])
        value32 = "ScrollingFrame"
        value33 = {}
        R[2] = globals.UDim2
        R[2] = R[2].new
        R[3] = 30
        R[6] = (- R[3])
        R[3] = 1
        R[4] = 0
        R[5] = 1
        R[2] = R[2](R[3], R[4], R[5], R[6])
        value33.Size = R[2]
        R[2] = globals.UDim2
        R[2] = R[2].fromOffset
        R[3] = 0
        R[4] = 30
        R[2] = R[2](R[3], R[4])
        value33.Position = R[2]
        value33.BackgroundTransparency = 1
        R[3] = 0
        value33.BorderSizePixel = R[3]
        R[3] = 4
        value33.ScrollBarThickness = R[3]
        R[3] = globals.UDim2
        R[3] = R[3].new
        R[3] = R[3]()
        value33.CanvasSize = R[3]
        R[3] = globals.Enum
        R[3] = R[3].AutomaticSize
        R[3] = R[3].Y
        value33.AutomaticCanvasSize = R[3]
        R[3] = value66.panel2
        value33.ScrollBarImageColor3 = R[3]
        value31 = R[39]
        value31 = value31(value32, value33, R[34])
        R[2] = globals.Instance
        R[2] = R[2].new
        R[5] = R[2]("UIListLayout")
        R[2] = globals.UDim
        R[2] = R[2].new
        R[3] = 0
        R[4] = 8
        R[2] = R[2](R[3], R[4])
        R[5].Padding = R[2]
        R[3] = globals.Enum
        R[3] = R[3].SortOrder
        R[3] = R[3].LayoutOrder
        R[5].SortOrder = R[3]
        R[5].Parent = value31
        R[4] = globals.ipairs
        R[5] = R[1]
        R[4], R[5], R[6] = R[4](R[5])
        loop = {parent = loop, iterator = iterateValues(R[4], R[5], R[6])}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                R[5], R[6] = tmp_key, tmp_value
            end
            if loopContinues then
                R[34] = {}
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[8] = 1
                R[9] = 0
                R[10] = 0
                R[11] = 0
                R[7] = R[7](R[8], R[9], R[10], R[11])
                R[34].Size = R[7]
                R[2] = globals.Enum
                R[2] = R[2].AutomaticSize
                R[2] = R[2].Y
                R[34].AutomaticSize = R[2]
                R[2] = value66.panel
                R[34].BackgroundColor3 = R[2]
                R[34].AutoButtonColor = true
                R[34].Text = ""
                R[34].BorderSizePixel = 0
                R[34].LayoutOrder = R[5]
                value33 = "TextButton"
                value32 = R[39]
                R[35] = value31
                value32 = value32(value33, R[34], R[35])
                R[67](value32, 8)
                R[34] = "UIPadding"
                R[35] = {}
                R[1] = globals.UDim
                R[1] = R[1].new
                R[2] = 0
                R[3] = 10
                R[1] = R[1](R[2], R[3])
                R[35].PaddingTop = R[1]
                R[1] = globals.UDim
                R[1] = R[1].new
                R[2] = 0
                R[3] = 10
                R[1] = R[1](R[2], R[3])
                R[35].PaddingBottom = R[1]
                R[1] = globals.UDim
                R[1] = R[1].new
                R[2] = 0
                R[3] = 12
                R[1] = R[1](R[2], R[3])
                R[35].PaddingLeft = R[1]
                R[1] = globals.UDim
                R[1] = R[1].new
                R[2] = 0
                R[3] = 12
                R[1] = R[1](R[2], R[3])
                R[35].PaddingRight = R[1]
                value33 = R[39]
                value36 = value32
                value33(R[34], R[35], value36)
                R[35] = {}
                R[2] = globals.Enum
                R[2] = R[2].FillDirection
                R[2] = R[2].Vertical
                R[35].FillDirection = R[2]
                R[2] = globals.Enum
                R[2] = R[2].SortOrder
                R[2] = R[2].LayoutOrder
                R[35].SortOrder = R[2]
                R[1] = globals.UDim
                R[1] = R[1].new
                R[2] = 0
                R[3] = 4
                R[1] = R[1](R[2], R[3])
                R[35].Padding = R[1]
                R[2] = globals.Enum
                R[2] = R[2].HorizontalAlignment
                R[2] = R[2].Left
                R[35].HorizontalAlignment = R[2]
                R[34] = "UIListLayout"
                value33 = R[39]
                value36 = value32
                value33(R[34], R[35], value36)
                R[35] = {}
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[8] = 1
                R[9] = 0
                R[10] = 0
                R[11] = 20
                R[7] = R[7](R[8], R[9], R[10], R[11])
                R[35].Size = R[7]
                R[2] = 1
                R[35].BackgroundTransparency = R[2]
                R[2] = 1
                R[35].LayoutOrder = R[2]
                R[34] = "Frame"
                value33 = R[39]
                value36 = value32
                value33 = value33(R[34], R[35], value36)
                R[35] = "TextLabel"
                value36 = {}
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[2] = 62
                R[9] = (- R[2])
                R[10] = 1
                R[8] = 1
                R[11] = 0
                R[7] = R[7](R[8], R[9], R[10], R[11])
                value36.Size = R[7]
                value36.BackgroundTransparency = 1
                R[2] = globals.Enum
                R[2] = R[2].Font
                R[2] = R[2].GothamBold
                value36.Font = R[2]
                R[2] = R[6].name
                value36.Text = R[2]
                R[2] = value66.text
                value36.TextColor3 = R[2]
                value36.TextSize = 14
                R[2] = globals.Enum
                R[2] = R[2].TextXAlignment
                R[2] = R[2].Left
                value36.TextXAlignment = R[2]
                R[34] = R[39]
                value37 = value33
                R[34] = R[34](R[35], value36, value37)
                value37 = {}
                R[1] = globals.UDim2
                R[1] = R[1].fromOffset
                R[3] = 20
                R[2] = 56
                R[1] = R[1](R[2], R[3])
                value37.Size = R[1]
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[11] = 0
                R[8] = 1
                R[9] = (- 56)
                R[10] = 0
                R[7] = R[7](R[8], R[9], R[10], R[11])
                value37.Position = R[7]
                value37.BackgroundTransparency = 1
                R[2] = globals.Enum
                R[2] = R[2].Font
                R[2] = R[2].GothamBold
                value37.Font = R[2]
                R[2] = "ELO "
                R[3] = R[6].elo
                R[2] = (R[2] .. R[3])
                value37.Text = R[2]
                R[2] = value66.subtext
                value37.TextColor3 = R[2]
                value37.TextSize = 12
                R[2] = globals.Enum
                R[2] = R[2].TextXAlignment
                R[2] = R[2].Right
                value37.TextXAlignment = R[2]
                value36 = "TextLabel"
                R[35] = R[39]
                value38 = value33
                R[35](value36, value37, value38)
                value37 = {}
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[9] = 0
                R[8] = 1
                R[10] = 0
                R[11] = 0
                R[7] = R[7](R[8], R[9], R[10], R[11])
                value37.Size = R[7]
                R[2] = globals.Enum
                R[2] = R[2].AutomaticSize
                R[2] = R[2].Y
                value37.AutomaticSize = R[2]
                value37.BackgroundTransparency = 1
                R[2] = globals.Enum
                R[2] = R[2].Font
                R[2] = R[2].Gotham
                value37.Font = R[2]
                R[2] = R[6].desc
                value37.Text = R[2]
                R[2] = value66.subtext
                value37.TextColor3 = R[2]
                value37.TextSize = 12
                R[2] = globals.Enum
                R[2] = R[2].TextXAlignment
                R[2] = R[2].Left
                value37.TextXAlignment = R[2]
                R[2] = globals.Enum
                R[2] = R[2].TextYAlignment
                R[2] = R[2].Top
                value37.TextYAlignment = R[2]
                value37.TextWrapped = true
                value37.LayoutOrder = 2
                value36 = "TextLabel"
                R[35] = R[39]
                value38 = value32
                R[35](value36, value37, value38)
                value36 = "Frame"
                value37 = {}
                R[2] = globals.UDim2
                R[7] = R[2].new
                R[8] = 1
                R[9] = 0
                R[10] = 0
                R[11] = 16
                R[7] = R[7](R[8], R[9], R[10], R[11])
                value37.Size = R[7]
                R[2] = 1
                value37.BackgroundTransparency = R[2]
                value37.LayoutOrder = 3
                R[35] = R[39]
                value38 = value32
                R[35] = R[35](value36, value37, value38)
                R[1] = {}
                R[3] = globals.UDim2
                R[7] = R[3].new
                R[9] = 0
                R[8] = 0.5
                R[10] = 1
                R[11] = 0
                R[7] = R[7](R[8], R[9], R[10], R[11])
                R[1].Size = R[7]
                R[1].BackgroundTransparency = 1
                R[3] = globals.Enum
                R[3] = R[3].Font
                R[3] = R[3].GothamBold
                R[1].Font = R[3]
                R[1].Text = "\226\156\147 selected"
                R[3] = globals.Color3
                R[7] = R[3].new
                R[9] = 1
                R[8] = 1
                R[10] = 1
                R[7] = R[7](R[8], R[9], R[10])
                R[1].TextColor3 = R[7]
                R[1].TextSize = 12
                R[3] = globals.Enum
                R[3] = R[3].TextXAlignment
                R[3] = R[3].Left
                R[1].TextXAlignment = R[3]
                R[1].Visible = false
                R[8] = "TextLabel"
                R[7] = R[39]
                R[9] = R[1]
                R[10] = R[35]
                R[7] = R[7](R[8], R[9], R[10])
                R[1] = {}
                R[3] = globals.UDim2
                R[8] = R[3].new
                R[9] = 1
                R[12] = 0
                R[10] = 0
                R[11] = 1
                R[8] = R[8](R[9], R[10], R[11], R[12])
                R[1].Size = R[8]
                R[3] = 1
                R[1].BackgroundTransparency = R[3]
                R[3] = globals.Enum
                R[3] = R[3].Font
                R[3] = R[3].GothamMedium
                R[1].Font = R[3]
                R[1].Text = ""
                R[3] = value66.idle
                R[1].TextColor3 = R[3]
                R[1].TextSize = 11
                R[3] = globals.Enum
                R[3] = R[3].TextXAlignment
                R[3] = R[3].Right
                R[1].TextXAlignment = R[3]
                R[9] = "TextLabel"
                R[8] = R[39]
                R[10] = R[1]
                R[11] = R[35]
                R[8] = R[8](R[9], R[10], R[11])
                R[1] = R[6].id
                R[2] = {}
                R[2].card = value32
                R[2].nameL = R[34]
                R[2].check = R[7]
                R[2].note = R[8]
                value73[R[1]] = R[2]
                R[2] = value32.MouseButton1Click
                R[1] = lifecycle.connect
                R[3] = Functions.helper_626({slot1 = captureShared(cells, R, 57), slot2 = captureShared(cells, R, 74), slot3 = R[6], slot4 = captureShared(cells, R, 75)}, globals)
                R[1](R[2], R[3])
                closeCapture(cells, R, 6)
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[75]()
        R[34] = nil
        R[3] = {}
        R[5] = nil
        R[1] = {}
        R[35] = nil
        R[4] = {}
        R[49] = nil
        value76 = {}
        R[6] = Functions.helper_1631({slot1 = captureShared(cells, R, 39), slot2 = value66, catalogCell = captures.catalogCell, slot4 = value48, slot5 = captureShared(cells, R, 67)}, globals)
        R[2] = Functions.helper_366({slot1 = captureShared(cells, R, 39), catalogCell = captures.catalogCell, slot3 = value66, slot4 = value48, slot5 = captureShared(cells, R, 67)}, globals)
        R[20] = Functions.helper_1877({slot1 = captureShared(cells, R, 39), catalogCell = captures.catalogCell, slot3 = value66, slot4 = value48}, globals)
        R[7] = 0
        R[20](R[7], "Aggression (Press / Patient)")
        value33 = "Randomise per new player"
        value32 = 22
        value31 = R[6]
        value31 = value31(value32, value33)
        R[5] = value31
        R[8] = R[5].MouseButton1Click
        R[7] = lifecycle.connect
        R[9] = Functions.helper_598({slot1 = captureShared(cells, R, 60)}, globals)
        R[7](R[8], R[9])
        value16 = 54
        value17 = "Default style"
        value15 = R[2]
        value18 = value26
        value19 = R[28]
        value15 = value15(value16, value17, value18, value19)
        R[1] = value15
        R[14] = globals.pairs
        value15 = R[1]
        R[14], value15, value16 = R[14](value15)
        R[7] = R[14]
        R[8] = value15
        R[9] = value16
        loop = {parent = loop, iterator = iterateValues(R[7], R[8], R[9])}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                R[8], R[9] = tmp_key, tmp_value
            end
            if loopContinues then
                R[11] = R[9].MouseButton1Click
                R[10] = lifecycle.connect
                R[12] = Functions.helper_553({slot1 = captureShared(cells, R, 60), slot2 = R[8]}, globals)
                R[10](R[11], R[12])
                closeCapture(cells, R, 8)
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[20](90, "Receive playstyle (Grab / Run)")
        value32 = 112
        value33 = "Randomise per new player"
        value31 = R[6]
        value31 = value31(value32, value33)
        R[34] = value31
        R[8] = R[34].MouseButton1Click
        R[7] = lifecycle.connect
        R[9] = Functions.helper_892({slot1 = captureShared(cells, R, 60)}, globals)
        R[7](R[8], R[9])
        value17 = "Default style"
        value16 = 144
        value15 = R[2]
        value18 = value25
        value19 = R[29]
        value15 = value15(value16, value17, value18, value19)
        R[3] = value15
        R[14] = globals.pairs
        value15 = R[3]
        R[14], value15, value16 = R[14](value15)
        R[10] = R[14]
        R[11] = value15
        R[12] = value16
        loop = {parent = loop, iterator = iterateValues(R[10], R[11], R[12])}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                R[11], R[12] = tmp_key, tmp_value
            end
            if loopContinues then
                R[8] = R[12].MouseButton1Click
                R[7] = lifecycle.connect
                R[9] = Functions.helper_1901({slot1 = captureShared(cells, R, 60), slot2 = R[11]}, globals)
                R[7](R[8], R[9])
                closeCapture(cells, R, 11)
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[20](180, "Opening (Corner / Charge)")
        value32 = 202
        value33 = "Randomise per new player"
        value31 = R[6]
        value31 = value31(value32, value33)
        R[35] = value31
        R[7] = R[35].MouseButton1Click
        R[6] = lifecycle.connect
        R[8] = Functions.helper_1812({slot1 = captureShared(cells, R, 60)}, globals)
        R[6](R[7], R[8])
        value16 = 234
        value17 = "Default style"
        value15 = R[2]
        value18 = value27
        value19 = R[30]
        value15 = value15(value16, value17, value18, value19)
        R[4] = value15
        R[14] = globals.pairs
        value15 = R[4]
        R[14], value15, value16 = R[14](value15)
        loop = {parent = loop, iterator = iterateValues(R[14], value15, value16)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value15, value16 = tmp_key, tmp_value
            end
            if loopContinues then
                R[7] = value16.MouseButton1Click
                R[6] = lifecycle.connect
                R[2] = Functions.helper_888({slot1 = captureShared(cells, R, 60), slot2 = value15}, globals)
                R[6](R[7], R[2])
                closeCapture(cells, R, 15)
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[2] = {}
        R[6] = globals.UDim2
        R[6] = R[6].new
        R[8] = 0
        R[7] = 1
        R[9] = 0
        R[10] = 18
        R[6] = R[6](R[7], R[8], R[9], R[10])
        R[2].Size = R[6]
        R[6] = globals.UDim2
        R[6] = R[6].fromOffset
        R[7] = 0
        R[8] = 270
        R[6] = R[6](R[7], R[8])
        R[2].Position = R[6]
        R[2].BackgroundTransparency = 1
        R[7] = globals.Enum
        R[7] = R[7].Font
        R[7] = R[7].GothamMedium
        R[2].Font = R[7]
        R[2].Text = "Per-opponent \226\128\148 \226\150\186 active \194\183 amber = PINNED \194\183 click a pill to cycle style \226\134\146 auto (unpin)"
        R[7] = value66.subtext
        R[2].TextColor3 = R[7]
        R[2].TextSize = 11
        R[7] = globals.Enum
        R[7] = R[7].TextXAlignment
        R[7] = R[7].Left
        R[2].TextXAlignment = R[7]
        R[7] = "TextLabel"
        R[6] = R[39]
        R[8] = R[2]
        R[9] = value48
        R[6](R[7], R[8], R[9])
        R[2] = {}
        R[6] = globals.UDim2
        R[6] = R[6].new
        R[7] = 1
        R[8] = 0
        R[9] = 1
        R[10] = (- 292)
        R[6] = R[6](R[7], R[8], R[9], R[10])
        R[2].Size = R[6]
        R[6] = globals.UDim2
        R[6] = R[6].fromOffset
        R[7] = 0
        R[8] = 290
        R[6] = R[6](R[7], R[8])
        R[2].Position = R[6]
        R[2].BackgroundTransparency = 1
        R[2].BorderSizePixel = 0
        R[2].ScrollBarThickness = 4
        R[7] = globals.UDim2
        R[7] = R[7].new
        R[7] = R[7]()
        R[2].CanvasSize = R[7]
        R[7] = globals.Enum
        R[7] = R[7].AutomaticSize
        R[7] = R[7].Y
        R[2].AutomaticCanvasSize = R[7]
        R[7] = value66.panel2
        R[2].ScrollBarImageColor3 = R[7]
        R[7] = "ScrollingFrame"
        R[6] = R[39]
        R[8] = R[2]
        R[9] = value48
        R[6] = R[6](R[7], R[8], R[9])
        R[49] = R[6]
        R[2] = {}
        R[7] = globals.Enum
        R[7] = R[7].FillDirection
        R[7] = R[7].Vertical
        R[2].FillDirection = R[7]
        R[6] = globals.UDim
        R[6] = R[6].new
        R[7] = 0
        R[8] = 6
        R[6] = R[6](R[7], R[8])
        R[2].Padding = R[6]
        R[7] = globals.Enum
        R[7] = R[7].SortOrder
        R[7] = R[7].Name
        R[2].SortOrder = R[7]
        R[7] = "UIListLayout"
        R[6] = R[39]
        R[8] = R[2]
        R[9] = R[49]
        R[6](R[7], R[8], R[9])
        R[2] = nil
        R[7] = nil
        R[14] = {}
        R[50] = {}
        R[51] = nil
        value78 = Functions.helper_281({slot1 = captureShared(cells, R, 39), catalogCell = captures.catalogCell, slot3 = value66, slot4 = value52}, globals)
        value15 = Functions.helper_1150({slot1 = captureShared(cells, R, 39), slot2 = value66, catalogCell = captures.catalogCell, slot4 = value52, slot5 = captureShared(cells, R, 67)}, globals)
        R[6] = Functions.helper_1964({slot1 = captureShared(cells, R, 39), catalogCell = captures.catalogCell, slot3 = value66, slot4 = value52, slot5 = captureShared(cells, R, 67)}, globals)
        R[8] = 0
        value78(R[8], "AutoQueue")
        value37 = 22
        value38 = "Enabled"
        value36 = R[6]
        value36 = value36(value37, value38)
        R[2] = value36
        R[9] = R[2].MouseButton1Click
        R[8] = lifecycle.connect
        R[10] = Functions.helper_432({authReadyCell = captures.authReadyCell, slot2 = captureShared(cells, R, 60)}, globals)
        R[8](R[9], R[10])
        value37 = 54
        value38 = "Find a queuing arena"
        value36 = R[6]
        value36 = value36(value37, value38)
        R[7] = value36
        R[9] = R[7].MouseButton1Click
        R[8] = lifecycle.connect
        R[6] = Functions.toggleQueueSearch({catalogCell = captures.catalogCell, numericCCell = captures.numericCCell, slot3 = captureShared(cells, R, 60)}, globals)
        R[8](R[9], R[6])
        R[8] = {}
        R[9] = {}
        R[9].id = "none"
        R[9].label = "None"
        R[10] = {}
        R[10].id = "2"
        R[10].label = "2"
        R[11] = {}
        R[12] = "4"
        R[11].id = R[12]
        R[11].label = "4"
        R[12] = {}
        R[12].id = "6"
        R[12].label = "6"
        tmp_Y = R[8]
        table.move({[9] = R[9], [10] = R[10], [11] = R[11], [12] = R[12]}, 9, 12, 1, tmp_Y)
        R[9] = 86
        R[10] = "Arena"
        R[11] = R[8]
        R[8] = value15
        R[8] = R[8](R[9], R[10], R[11])
        R[14] = R[8]
        value17 = globals.pairs
        value18 = R[14]
        value17, value18, value19 = value17(value18)
        loop = {parent = loop, iterator = iterateValues(value17, value18, value19)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value18, value19 = tmp_key, tmp_value
            end
            if loopContinues then
                R[9] = value19.MouseButton1Click
                R[8] = lifecycle.connect
                R[6] = Functions.helper_1183({slot1 = captureShared(cells, R, 60), slot2 = value18}, globals)
                R[8](R[9], R[6])
                closeCapture(cells, R, 18)
                continue
            else
                break
            end
        end
        loop = loop.parent
        value16 = 118
        R[8] = {}
        R[9] = {}
        R[10] = "either"
        R[9].id = R[10]
        R[9].label = "Either"
        R[10] = {}
        R[10].id = "left"
        R[10].label = "Left"
        R[11] = {}
        R[11].id = "right"
        R[11].label = "Right"
        tmp_Y = R[8]
        table.move({[9] = R[9], [10] = R[10], [11] = R[11]}, 9, 11, 1, tmp_Y)
        value17 = "Side"
        value18 = R[8]
        value15 = value15(value16, value17, value18)
        R[50] = value15
        R[20] = globals.pairs
        value21 = R[50]
        R[20], value21, value22 = R[20](value21)
        loop = {parent = loop, iterator = iterateValues(R[20], value21, value22)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value21, value22 = tmp_key, tmp_value
            end
            if loopContinues then
                R[9] = value22.MouseButton1Click
                R[8] = lifecycle.connect
                R[6] = Functions.helper_1710({slot1 = captureShared(cells, R, 60), slot2 = value21}, globals)
                R[8](R[9], R[6])
                closeCapture(cells, R, 21)
                continue
            else
                break
            end
        end
        loop = loop.parent
        R[6] = {}
        R[8] = globals.UDim2
        R[8] = R[8].new
        R[11] = 0
        R[9] = 1
        R[10] = 0
        R[12] = 18
        R[8] = R[8](R[9], R[10], R[11], R[12])
        R[6].Size = R[8]
        R[8] = globals.UDim2
        R[8] = R[8].fromOffset
        R[9] = 0
        R[10] = 154
        R[8] = R[8](R[9], R[10])
        R[6].Position = R[8]
        R[6].BackgroundTransparency = 1
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].Gotham
        R[6].Font = R[9]
        R[6].Text = "Status: -"
        R[9] = value66.subtext
        R[6].TextColor3 = R[9]
        R[9] = 12
        R[6].TextSize = R[9]
        R[9] = globals.Enum
        R[9] = R[9].TextXAlignment
        R[9] = R[9].Left
        R[6].TextXAlignment = R[9]
        R[9] = "TextLabel"
        R[8] = R[39]
        R[10] = R[6]
        R[11] = value52
        R[8] = R[8](R[9], R[10], R[11])
        R[51] = R[8]
        R[6] = 182
        value78(R[6], "Controls")
        R[6] = {}
        R[8] = globals.UDim2
        R[8] = R[8].new
        R[9] = 1
        R[10] = 0
        R[11] = 0
        R[12] = 100
        R[8] = R[8](R[9], R[10], R[11], R[12])
        R[6].Size = R[8]
        R[8] = globals.UDim2
        R[8] = R[8].fromOffset
        R[9] = 0
        R[10] = 204
        R[8] = R[8](R[9], R[10])
        R[6].Position = R[8]
        R[6].BackgroundTransparency = 1
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].Gotham
        R[6].Font = R[9]
        R[6].Text = "Hold V to turn the bot on temporarily (release to stop).\nPress B to keep the bot on constantly.\nPress N to turn the bot off.\nHold P to activate Teleport Kill."
        R[9] = value66.subtext
        R[6].TextColor3 = R[9]
        R[6].TextSize = 12
        R[9] = true
        R[6].TextWrapped = R[9]
        R[6].LineHeight = 1.25
        R[9] = globals.Enum
        R[9] = R[9].TextXAlignment
        R[9] = R[9].Left
        R[6].TextXAlignment = R[9]
        R[9] = globals.Enum
        R[9] = R[9].TextYAlignment
        R[9] = R[9].Top
        R[6].TextYAlignment = R[9]
        R[9] = "TextLabel"
        R[8] = R[39]
        R[10] = R[6]
        R[11] = value52
        R[8](R[9], R[10], R[11])
        R[20] = nil
        R[20] = Functions.refreshQueueControls({numericCCell = captures.numericCCell, slot2 = captureShared(cells, R, 60), slot3 = captureShared(cells, R, 2), catalogCell = captures.catalogCell, slot5 = value66, slot6 = captureShared(cells, R, 7), slot7 = captureShared(cells, R, 14), slot8 = captureShared(cells, R, 50), slot9 = captureShared(cells, R, 51), slot10 = value56}, globals)
        R[9] = value24.RenderStepped
        R[8] = lifecycle.connect
        R[6] = Functions.helper_947({slot1 = captureShared(cells, R, 71), slot2 = captureShared(cells, R, 20)}, globals)
        R[8](R[9], R[6])
        value21 = {}
        R[6] = {}
        R[6].Name = "Header"
        R[8] = globals.UDim2
        R[8] = R[8].new
        R[9] = 1
        R[10] = 0
        R[11] = 0
        R[12] = 20
        R[8] = R[8](R[9], R[10], R[11], R[12])
        R[6].Size = R[8]
        R[6].BackgroundTransparency = 1
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].GothamBold
        R[6].Font = R[9]
        R[6].Text = "Prediction \226\128\148 waiting for bot\226\128\166"
        R[9] = value66.subtext
        R[6].TextColor3 = R[9]
        R[9] = 13
        R[6].TextSize = R[9]
        R[9] = globals.Enum
        R[9] = R[9].TextXAlignment
        R[9] = R[9].Left
        R[6].TextXAlignment = R[9]
        R[9] = "TextLabel"
        R[8] = R[39]
        R[10] = R[6]
        R[11] = value53
        R[8] = R[8](R[9], R[10], R[11])
        R[6] = {}
        R[10] = "Rows"
        R[6].Name = R[10]
        R[10] = globals.UDim2
        value15 = R[10].new
        value18 = 1
        R[10] = 28
        value19 = (- R[10])
        value16 = 1
        value17 = 0
        value15 = value15(value16, value17, value18, value19)
        R[6].Size = value15
        R[9] = globals.UDim2
        R[9] = R[9].fromOffset
        R[10] = 0
        R[11] = 26
        R[9] = R[9](R[10], R[11])
        R[6].Position = R[9]
        R[6].BackgroundTransparency = 1
        R[10] = "Frame"
        R[9] = R[39]
        R[11] = R[6]
        R[12] = value53
        R[9] = R[9](R[10], R[11], R[12])
        value17 = {}
        R[10] = globals.Enum
        R[10] = R[10].FillDirection
        R[10] = R[10].Vertical
        value17.FillDirection = R[10]
        R[10] = globals.UDim
        R[10] = R[10].new
        R[11] = 0
        R[12] = 6
        R[10] = R[10](R[11], R[12])
        value17.Padding = R[10]
        R[10] = globals.Enum
        R[10] = R[10].SortOrder
        R[10] = R[10].LayoutOrder
        value17.SortOrder = R[10]
        value16 = "UIListLayout"
        value15 = R[39]
        value18 = R[9]
        value15(value16, value17, value18)
        R[6] = 0
        R[10] = Functions.helper_2352({slot1 = captureShared(cells, R, 6), catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 39), slot4 = value66, slot5 = R[9], slot6 = captureShared(cells, R, 67), slot7 = value21}, globals)
        value21.__header = R[8]
        R[8] = "Mode"
        R[10]("mode", R[8])
        R[10]("bombTime", "Bomb time")
        R[10]("nearest", "Nearest player")
        R[8] = "second"
        R[10](R[8], "2nd nearest")
        R[10]("tagTime", "Tag prediction")
        R[10]("contactBomb", "Bomb time at tag")
        R[8] = "Aggression"
        R[10]("aggro", R[8])
        R[10]("waverMode", "Waver mode")
        R[10]("reach", "Victim reach")
        R[10]("llStyle", "Grab/Run style")
        R[8] = "Opening"
        R[10]("opening", R[8])
        R[10]("navMode", "Nav mode")
        R[10]("navSide", "Side commit / new")
        R[10]("navRoute", "Route R / L (edge)")
        R[10]("vizGraph", "Graph lines  [Y]")
        R[10]("vizRays", "Pathfind rays  [T]")
        R[10]("vizBeams", "Target beams  [I]")
        closeCapture(cells, R, 9)
        closeCapture(cells, R, 6)
        R[6] = {}
        R[8] = globals.UDim2
        R[8] = R[8].new
        R[12] = 22
        R[9] = 1
        R[10] = 0
        R[11] = 0
        R[8] = R[8](R[9], R[10], R[11], R[12])
        R[6].Size = R[8]
        R[6].BackgroundTransparency = 1
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].GothamBold
        R[6].Font = R[9]
        R[6].Text = "Dracoware Bot v1.6"
        R[9] = value66.text
        R[6].TextColor3 = R[9]
        R[9] = 15
        R[6].TextSize = R[9]
        R[9] = globals.Enum
        R[9] = R[9].TextXAlignment
        R[9] = R[9].Left
        R[6].TextXAlignment = R[9]
        R[9] = "TextLabel"
        R[8] = R[39]
        R[10] = R[6]
        R[11] = value54
        R[8](R[9], R[10], R[11])
        R[6] = {}
        R[8] = globals.UDim2
        R[8] = R[8].new
        R[9] = 1
        R[10] = 0
        R[11] = 0
        R[12] = 40
        R[8] = R[8](R[9], R[10], R[11], R[12])
        R[6].Size = R[8]
        R[8] = globals.UDim2
        R[8] = R[8].fromOffset
        R[9] = 0
        R[10] = 28
        R[8] = R[8](R[9], R[10])
        R[6].Position = R[8]
        R[6].BackgroundTransparency = 1
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].Gotham
        R[6].Font = R[9]
        R[6].Text = "Created by Syzematic10\nYouTube: https://www.youtube.com/@fanaka09"
        R[9] = value66.subtext
        R[6].TextColor3 = R[9]
        R[6].TextSize = 13
        R[6].TextWrapped = true
        R[9] = globals.Enum
        R[9] = R[9].TextXAlignment
        R[9] = R[9].Left
        R[6].TextXAlignment = R[9]
        R[9] = globals.Enum
        R[9] = R[9].TextYAlignment
        R[9] = R[9].Top
        R[6].TextYAlignment = R[9]
        R[9] = "TextLabel"
        R[8] = R[39]
        R[10] = R[6]
        R[11] = value54
        R[8](R[9], R[10], R[11])
        R[6] = "TextButton"
        R[12] = {}
        R[8] = globals.UDim2
        R[8] = R[8].fromOffset
        R[10] = 26
        R[9] = 150
        R[8] = R[8](R[9], R[10])
        R[12].Size = R[8]
        R[8] = globals.UDim2
        R[8] = R[8].fromOffset
        R[9] = 0
        R[10] = 74
        R[8] = R[8](R[9], R[10])
        R[12].Position = R[8]
        R[9] = value66.accent
        R[12].BackgroundColor3 = R[9]
        R[12].Text = "Copy YouTube link"
        R[9] = globals.Enum
        R[9] = R[9].Font
        R[9] = R[9].GothamMedium
        R[12].Font = R[9]
        R[8] = globals.Color3
        R[8] = R[8].new
        R[10] = 1
        R[9] = 1
        R[11] = 1
        R[8] = R[8](R[9], R[10], R[11])
        R[12].TextColor3 = R[8]
        R[12].TextSize = 12
        R[12].AutoButtonColor = true
        R[12].BorderSizePixel = 0
        R[8] = R[39]
        R[9] = R[6]
        R[10] = R[12]
        R[11] = value54
        R[8] = R[8](R[9], R[10], R[11])
        R[67](R[8], 6)
        R[10] = R[8].MouseButton1Click
        R[9] = lifecycle.connect
        R[6] = Functions.copyCreatorLink({slot1 = R[8], catalogCell = captures.catalogCell}, globals)
        R[9](R[10], R[6])
        R[6] = {}
        R[10] = globals.UDim2
        value15 = R[10].new
        value16 = 1
        value17 = 0
        value18 = 1
        value19 = (- 112)
        value15 = value15(value16, value17, value18, value19)
        R[6].Size = value15
        R[9] = globals.UDim2
        R[9] = R[9].fromOffset
        R[10] = 0
        R[11] = 110
        R[9] = R[9](R[10], R[11])
        R[6].Position = R[9]
        R[6].BackgroundTransparency = 1
        R[10] = globals.Enum
        R[10] = R[10].Font
        R[10] = R[10].Gotham
        R[6].Font = R[10]
        R[6].Text = "Changelog\n\226\128\162 v1.9: Bot roster in the Bots tab, AutoQueue in Settings, and interface improvements."
        R[10] = value66.subtext
        R[6].TextColor3 = R[10]
        R[6].TextSize = 12
        R[6].TextWrapped = true
        R[10] = globals.Enum
        R[10] = R[10].TextXAlignment
        R[10] = R[10].Left
        R[6].TextXAlignment = R[10]
        R[10] = globals.Enum
        R[10] = R[10].TextYAlignment
        R[10] = R[10].Top
        R[6].TextYAlignment = R[10]
        R[10] = "TextLabel"
        R[9] = R[39]
        R[11] = R[6]
        R[12] = value54
        R[9](R[10], R[11], R[12])
        closeCapture(cells, R, 8)
        R[72]("Bots")
        R[6] = false
        value54 = value43.MouseButton1Click
        value53 = lifecycle.connect
        R[8] = Functions.toggleMinimized({slot1 = captureShared(cells, R, 6), slot2 = value45, slot3 = value47, slot4 = value40, catalogCell = captures.catalogCell, slot6 = value43}, globals)
        value53(value54, R[8])
        R[8] = nil
        R[9] = nil
        R[10] = nil
        value54 = value41.InputBegan
        value53 = lifecycle.connect
        R[11] = Functions.beginWindowDrag({slot1 = captureShared(cells, R, 8), slot2 = captureShared(cells, R, 9), slot3 = value40, slot4 = captureShared(cells, R, 10), catalogCell = captures.catalogCell}, globals)
        value53(value54, R[11])
        value54 = value23.InputChanged
        value53 = lifecycle.connect
        R[11] = Functions.updateWindowDrag({slot1 = captureShared(cells, R, 8), slot2 = captureShared(cells, R, 9), slot3 = value40, slot4 = captureShared(cells, R, 10)}, globals)
        value53(value54, R[11])
        closeCapture(cells, R, 8)
        closeCapture(cells, R, 9)
        closeCapture(cells, R, 10)
        value54 = value23.InputBegan
        value53 = lifecycle.connect
        R[8] = Functions.toggleInterfaceVisible({slot1 = value40}, globals)
        value53(value54, R[8])
        R[8] = nil
        R[8] = Functions.helper_1915({}, globals)
        R[9] = nil
        R[9] = Functions.helper_1845({}, globals)
        R[10] = nil
        R[10] = Functions.helper_1602({}, globals)
        value54 = value24.RenderStepped
        value53 = lifecycle.connect
        R[11] = Functions.updateDebugInterface({slot1 = value42, slot2 = captureShared(cells, R, 58), slot3 = captureShared(cells, R, 71), catalogCell = captures.catalogCell, slot5 = captureShared(cells, R, 75), numericCCell = captures.numericCCell, slot7 = value56, slot8 = value21, slot9 = value66, slot10 = captureShared(cells, R, 8), slot11 = captureShared(cells, R, 9), slot12 = captureShared(cells, R, 10)}, globals)
        value53(value54, R[11])
        R[11] = nil
        R[11] = Functions.helper_1995({slot1 = captureShared(cells, R, 39), slot2 = value66, slot3 = captureShared(cells, R, 49), slot4 = captureShared(cells, R, 67), catalogCell = captures.catalogCell, slot6 = captureShared(cells, R, 60), slot7 = value56, slot8 = value26, slot9 = value25, slot10 = value27, slot11 = value76}, globals)
        R[12] = nil
        R[12] = Functions.helper_1341({slot1 = value66, catalogCell = captures.catalogCell}, globals)
        value54 = value24.RenderStepped
        value53 = lifecycle.connect
        value79 = Functions.helper_379({slot1 = captureShared(cells, R, 71), catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 60), slot4 = value56, slot5 = captureShared(cells, R, 5), slot6 = value66, slot7 = captureShared(cells, R, 1), slot8 = captureShared(cells, R, 34), slot9 = captureShared(cells, R, 3), slot10 = captureShared(cells, R, 35), slot11 = captureShared(cells, R, 4), slot12 = value76, slot13 = captureShared(cells, R, 11), slot14 = captureShared(cells, R, 12), slot15 = value26, slot16 = captureShared(cells, R, 28), slot17 = value25, slot18 = captureShared(cells, R, 29), slot19 = value27, slot20 = captureShared(cells, R, 30), slot21 = captureShared(cells, R, 65)}, globals)
        value53(value54, value79)
        closeCaptures(cells, R)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1341 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, value2, value4, value5, value6, value7, value8, value10, value11, value12, value13, value14, value15, value16, value17, value18, value20

        tmp_X = {...}
        value4, value5, value6, value7, value8 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4), rawget(tmp_X, 5)
        if value6 then
            if (not value6.stats) then
                value4.Text = "\226\128\148"
                value5.Text = "\226\128\148"
                value5 = captures.slot1.accent
                value4.BackgroundColor3 = value5
            else
                value10 = value8(value6.style)
                value4.Text = value10
                value10 = value6.locked
                if value10 then
                    value10 = captures.slot1.lock
                    if (not value10) then
                        value10 = captures.slot1.accent
                    end
                else
                    value10 = captures.slot1.accent
                end
                value4.BackgroundColor3 = value10
                value20 = {}
                value10 = globals.ipairs
                value11 = value7
                value10, value11, value12 = value10(value11)
                loop = {parent = loop, iterator = iterateValues(value10, value11, value12)}
                while true do
                    loopContinues, tmp_key, tmp_value = loop.iterator()
                    if loopContinues then
                        value11, value12 = tmp_key, tmp_value
                    end
                    if loopContinues then
                        value2 = value6.stats[value12]
                        value15 = (value6.style == value12)
                        if value15 then
                            value15 = "\226\150\186"
                        else
                            value15 = ""
                        end
                        if value2 then
                            value7 = ((# value20) + 1)
                            value13 = globals.string.format
                            value16 = value8(value12)
                            value17 = value2.kills
                            value18 = value2.deaths
                            value14 = "%s%s %dK %dD"
                            value13 = value13(value14, value15, value16, value17, value18)
                            value20[value7] = value13
                            continue
                        else
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
                value2 = (# value20)
                value15 = (value2 > (0))
                if value15 then
                    value2 = globals.table.concat
                    value17 = "  "
                    value15 = value2
                    value16 = value20
                    value15 = value15(value16, value17)
                    if (not value15) then
                        value15 = "\226\128\148"
                    end
                else
                    value15 = "\226\128\148"
                end
                value2 = value6.locked
                if value2 then
                    value2 = "   \194\183 PINNED"
                else
                    value2 = ""
                end
                value2 = (value15 .. value2)
                value5.Text = value2
            end
        else
            value4.Text = "\226\128\148"
            value5.Text = "\226\128\148"
            value5 = captures.slot1.accent
            value4.BackgroundColor3 = value5
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1357 = function(captures, globals)
    local function recovered(...)
        local value4, value5, value7

        value5 = globals.game
        value4 = value5.GetService
        value7 = "CoreGui"
        return value4(value5, value7)
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1366 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, value1, value2, value3, value18

        tmp_X = {...}
        value18 = rawget(tmp_X, 1)
        if ((globals.type(value18)) == "table") then
            value1 = globals.pairs
            value2 = value18
            value1, value2, value3 = value1(value2)
            loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value2, value3 = tmp_key, tmp_value
                end
                if loopContinues then
                    captures.slot1[value2] = true
                    continue
                else
                    break
                end
            end
            loop = loop.parent
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.drawDebugLine = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value4, value5, value6, value7, value8, value32, value33, value34, value35, value36

        tmp_X = {...}
        value33, value34, value35, value36 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        value8 = (value34 - value33).Magnitude
        if (not (value8 < 0.1)) then
            value2 = globals.Instance.new("Part")
            value2.Anchored = true
            value2.CanCollide = false
            value4 = globals.Enum.Material.Neon
            value2.Material = value4
            if (not value35) then
                value7 = globals.Color3.new
                value4 = 1
                value5 = 0
                value6 = 0
                value3 = value7
                value35 = (value3(value4, value5, value6))
            end
            value2.Color = value35
            value3 = globals.Vector3.new
            value4 = 0.1
            value5 = 0.1
            value6 = value8
            value3 = value3(value4, value5, value6)
            value2.Size = value3
            value32 = globals.CFrame.lookAt
            value32 = value32(value33, value34)
            value3 = globals.CFrame.new
            value6 = ((- value8) / 2)
            value4 = 0
            value5 = 0
            value3 = (value32 * (value3(value4, value5, value6)))
            value2.CFrame = value3
            value4 = globals.workspace
            value2.Parent = value4
            value34 = captures.slot2
            value33 = value34.AddItem
            if (not value36) then
                value36 = 0.1
            end
            value35 = value2
            value33(value34, value35, value36)
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseAggressionStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value6, value7, value8, value11, value15, value16, value17, value18

        tmp_X = {...}
        value18 = rawget(tmp_X, 1)
        value2 = captures.slot1[value18]
        if (not value2) then
            tmp_X = captures.slot2
            if readCell(tmp_X).randomiseAggro then
                value6 = captures.slot3
                value15 = globals.math.random
                value17 = (# captures.slot3)
                value16 = 1
                value6 = value6[(value15(value16, value17))]
            else
                tmp_X = captures.slot2
                value6 = readCell(tmp_X).defaultAggroStyle
                if (not value6) then
                    value6 = "aggressive"
                end
            end
            value2 = {}
            value2.style = value6
            value6 = {}
            value7 = "aggressive"
            value8 = {}
            value11 = 0
            value8.kills = value11
            value8.deaths = 0
            value6[value7] = value8
            value8 = {}
            value8.kills = 0
            value11 = 0
            value8.deaths = value11
            value6.patient = value8
            value2.stats = value6
            captures.slot1[value18] = value2
        end
        tmp_X = captures.slot2
        value4 = readCell(tmp_X).aggroStyleOverride[value18]
        value6 = "auto"
        if (value4 == value6) then
            value2.locked = false
            tmp_X = captures.slot2
            value6 = readCell(tmp_X).aggroStyleOverride
            value6[value18] = nil
        else
            value6 = (value4 == "aggressive")
            if value6 then
                value2.style = value4
                value6 = true
                value2.locked = value6
                tmp_X = captures.slot2
                value4 = readCell(tmp_X).aggroStyleOverride
                value4[value18] = nil
            else
                value6 = (value4 == "patient")
                if value6 then
                    value2.style = value4
                    value6 = true
                    value2.locked = value6
                    tmp_X = captures.slot2
                    value4 = readCell(tmp_X).aggroStyleOverride
                    value4[value18] = nil
                end
            end
        end
        value2 = value2.style
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1391 = function(captures, globals)
    local function recovered(...)

        captures.slot1.Text = "Copy YouTube link"
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1395 = function(captures, globals)
    local function recovered(...)
        local value2, value3

        value3 = captures.slot1
        value2 = value3.GetPivot
        return value2(value3)
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.toggleQueueSearch = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value4, value7

        value2 = 1001
        tmp_X = captures.numericCCell
        value4 = readCell(tmp_X)
        value2 = (value2 < (value4((2167))))
        if value2 then
            tmp_X = captures.slot3
            value2 = readCell(tmp_X)()
            value7 = (not value2.autoQueueFind)
            value2.autoQueueFind = value7
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1440 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value3, value9, value10

        tmp_X = {...}
        value9, value10 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value3 = readCell(tmp_X)
        return value3(value9, value10)
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1477 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value3, value5, value7

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value3 = value2.reachAdjust
        value5 = captures.slot2
        value7 = globals.math.floor
        value2 = value2.reachAdjust[captures.slot2]
        if (not value2) then
            value2 = 0
        end
        value2 = ((value2 - (0.1)) * 100)
        value2 = value7((value2 + (0.5)))
        value2 = (value2 / (100))
        value3[value5] = value2
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1503 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value5

        value5 = captures.slot1.Data.ActiveArena.Value
        tmp_X = captures.slot2
        writeCell(tmp_X, value5)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1508 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value6, value7, value8, value9

        value6 = captures.slot1.engaged
        if value6 then
            value6 = captures.slot1.style
            if value6 then
                value6 = captures.slot1.victimName
                if value6 then
                    value6 = (not captures.slot1.resolved)
                    if value6 then
                        tmp_X = captures.slot2
                        value6 = readCell(tmp_X)
                        value7 = captures.slot1.victimName
                        value8 = captures.slot1.style
                        value9 = false
                        value6(value7, value8, value9)
                        captures.slot1.resolved = true
                        captures.slot1.engaged = false
                    end
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.ensureOpponentStats = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value4, value6, value7, value11

        tmp_X = {...}
        value6 = rawget(tmp_X, 1)
        if value6 then
            if (not captures.slot1.players[value6]) then
                value4 = captures.slot1.players
                value7 = {}
                value11 = 0
                value7.wins = value11
                value11 = 0
                value7.losses = value11
                value4[value6] = value7
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.formatOpeningStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value17

        tmp_X = {...}
        value17 = rawget(tmp_X, 1)
        value1 = (value17 == "aggressive")
        if value1 then
            value1 = "Press"
        else
            value1 = (value17 == "patient")
            if value1 then
                value1 = "Patient"
            else
                value1 = "\226\128\148"
            end
        end
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.deathRatio = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value4, value6, value7

        tmp_X = {...}
        value6, value7 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value4 = value6.stats[value7]
        value6 = (value4.kills + value4.deaths)
        if (not (value6 == 0)) then
            value4 = (value4.deaths / value6)
            return value4
        end
        return -1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1587 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value7, value33, value34, value35, value37

        tmp_X = {...}
        value37 = rawget(tmp_X, 1)
        value1 = captures.slot1.players[value37]
        value2 = (not value1)
        if value2 then
            tmp_X = captures.slot2
            value2 = readCell(tmp_X).randomiseOpening
            if value2 then
                value2 = captures.slot1.STYLE_LIST
                value33 = globals.math.random
                value34 = 1
                value35 = (# captures.slot1.STYLE_LIST)
                value2 = value2[(value33(value34, value35))]
            else
                tmp_X = captures.slot2
                value2 = readCell(tmp_X).defaultOpeningStyle
                if (not value2) then
                    value2 = captures.slot1.CORNER
                end
            end
            value1 = {}
            value1.style = value2
            value3 = {}
            value4 = captures.slot1.CORNER
            value5 = {}
            value5.kills = 0
            value7 = 0
            value5.deaths = value7
            value3[value4] = value5
            value4 = captures.slot1.CHARGE
            value5 = {}
            value5.kills = 0
            value7 = 0
            value5.deaths = value7
            value3[value4] = value5
            value1.stats = value3
            value2 = captures.slot1.players
            value2[value37] = value1
        end
        tmp_X = captures.slot2
        value2 = readCell(tmp_X).openingStyleOverride[value37]
        value3 = "auto"
        if (value2 == value3) then
            value1.locked = false
            tmp_X = captures.slot2
            value3 = readCell(tmp_X).openingStyleOverride
            value3[value37] = nil
            tmp_X = captures.authAliveCell
            if (not (readCell(tmp_X))) then
                return
            end
        else
            if (value2 == captures.slot1.CORNER) then
                value1.style = value2
                value1.locked = true
                tmp_X = captures.slot2
                value2 = readCell(tmp_X).openingStyleOverride
                value2[value37] = nil
            else
                if (value2 == captures.slot1.CHARGE) then
                    value1.style = value2
                    value1.locked = true
                    tmp_X = captures.slot2
                    value2 = readCell(tmp_X).openingStyleOverride
                    value2[value37] = nil
                end
            end
        end
        value1 = value1.style
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1600 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value9

        tmp_X = {...}
        value9 = rawget(tmp_X, 1)
        if (value9 <= (0)) then
            captures.slot2.markDeath()
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1602 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value22

        tmp_X = {...}
        value22 = rawget(tmp_X, 1)
        if ((globals.type(value22)) ~= "number") then
            return "\226\128\148"
        end
        if (1000000000 <= value22) then
            return "X"
        end
        value1 = globals.string.format
        return value1("%.1f", value22)
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.createUIInstance = function(captures, globals)
    return function(className, properties, parent)
        local instance = globals.Instance.new(className)
        for property, value in globals.pairs(properties or {}) do
            instance[property] = value
        end
        if parent then instance.Parent = parent end
        return instance
    end
end

Functions.helper_1624 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value1, value2, value3, value4, value5, value6, value7, value8, value9, value11, value13, value17

        tmp_X = captures.slot1
        if ((readCell(tmp_X))) then
            tmp_X = captures.slot1
            value9 = readCell(tmp_X)
            value9.Destroy(value9)
            tmp_X = captures.slot1
            writeCell(tmp_X, value4)
        end
        value1 = (not captures.slot2)
        if (not value1) then
            value1 = globals.Instance.new("Folder")
            tmp_X = captures.slot1
            writeCell(tmp_X, value1)
            tmp_X = captures.slot1
            readCell(tmp_X).Name = "VG_VIZ"
            tmp_X = captures.slot1
            value1 = readCell(tmp_X)
            value3 = globals.workspace
            value1.Parent = value3
            value11 = Functions.helper_331({catalogCell = captures.catalogCell, slot2 = captures.slot4, slot3 = captures.slot1}, globals)
            tmp_X = captures.slot5
            value2 = (# (readCell(tmp_X)))
            value1 = 1
            value3 = 1
            loop = {parent = loop, index = (value1 - value3), limit = value2, step = value3}
            while true do
                loop.index += loop.step
                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                if loopContinues then
                    value13 = loop.index
                end
                if loopContinues then
                    value1 = (value13 + 1)
                    value3 = 1
                    loop = {parent = loop, index = (value1 - value3), limit = value2, step = value3}
                    while true do
                        loop.index += loop.step
                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                        if loopContinues then
                            value1 = loop.index
                        end
                        if loopContinues then
                            tmp_X = captures.slot6
                            value3 = readCell(tmp_X)[value13]
                            if value3 then
                                tmp_X = captures.slot6
                                value3 = readCell(tmp_X)[value13][value1]
                                if value3 then
                                    value4 = globals.Vector3.new
                                    tmp_X = captures.slot5
                                    value5 = readCell(tmp_X)[value13].X
                                    tmp_X = captures.slot4
                                    value6 = readCell(tmp_X)
                                    tmp_X = captures.slot5
                                    value7 = readCell(tmp_X)[value13].Z
                                    value4 = value4(value5, value6, value7)
                                    value5 = globals.Vector3.new
                                    tmp_X = captures.slot5
                                    value6 = readCell(tmp_X)[value1].X
                                    tmp_X = captures.slot4
                                    value7 = readCell(tmp_X)
                                    tmp_X = captures.slot5
                                    value8 = readCell(tmp_X)[value1].Z
                                    value5 = value5(value6, value7, value8)
                                    value1 = (value5 - value4).Magnitude
                                    if (value1 > 0.1) then
                                        value3 = globals.Instance.new
                                        value17 = value3("Part")
                                        value17.Anchored = true
                                        value17.CanCollide = false
                                        value6 = false
                                        value17.CanQuery = value6
                                        value17.CastShadow = false
                                        value6 = globals.Enum.Material.Neon
                                        value17.Material = value6
                                        value6 = globals.Color3.fromRGB
                                        value8 = 120
                                        value7 = 60
                                        value9 = 255
                                        value6 = value6(value7, value8, value9)
                                        value17.Color = value6
                                        value6 = globals.Vector3.new
                                        value8 = 0.08
                                        value7 = 0.08
                                        value9 = value1
                                        value6 = value6(value7, value8, value9)
                                        value17.Size = value6
                                        value3 = globals.CFrame.lookAt
                                        value3 = value3(value4, value5)
                                        value6 = globals.CFrame.new
                                        value1 = (- value1)
                                        value9 = (value1 / (2))
                                        value7 = 0
                                        value8 = 0
                                        value1 = (value3 * (value6(value7, value8, value9)))
                                        value17.CFrame = value1
                                        tmp_X = captures.slot1
                                        value3 = readCell(tmp_X)
                                        value17.Parent = value3
                                        continue
                                    else
                                        continue
                                    end
                                else
                                    continue
                                end
                            else
                                continue
                            end
                        else
                            break
                        end
                    end
                    loop = loop.parent
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            value1 = 1
            value3 = 1
            loop = {parent = loop, index = (value1 - value3), limit = value2, step = value3}
            while true do
                loop.index += loop.step
                loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                if loopContinues then
                    value1 = loop.index
                end
                if loopContinues then
                    tmp_X = captures.slot5
                    value5 = readCell(tmp_X)[value1]
                    value1 = globals.Color3
                    value6 = value1.fromRGB
                    value7 = 255
                    value8 = 220
                    value9 = 40
                    value6 = value6(value7, value8, value9)
                    value7 = 0.6
                    value4 = value11
                    value4(value5, value6, value7)
                    continue
                else
                    break
                end
            end
            loop = loop.parent
            value1 = globals.ipairs
            tmp_X = captures.slot7
            value2 = readCell(tmp_X)
            value1, value2, value3 = value1(value2)
            loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
            while true do
                loopContinues, tmp_key, tmp_value = loop.iterator()
                if loopContinues then
                    value2, value3 = tmp_key, tmp_value
                end
                if loopContinues then
                    value6 = globals.Color3.fromRGB
                    value7 = 230
                    value9 = 40
                    value8 = 40
                    value6 = value6(value7, value8, value9)
                    value7 = 0.45
                    value4 = value11
                    value5 = value3
                    value4(value5, value6, value7)
                    continue
                else
                    break
                end
            end
            loop = loop.parent
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1631 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value6, value7, value8, value9, value10, value11, value12, value13, value14, value15, value16, value17, value18, value19

        tmp_X = {...}
        value13, value14 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value15 = readCell(tmp_X)
        value17 = {}
        value6 = globals.UDim2.new
        value7 = 1
        value8 = 0
        value9 = 0
        value10 = 28
        value6 = value6(value7, value8, value9, value10)
        value17.Size = value6
        value11 = globals.UDim2.fromOffset
        value12 = 0
        value11 = value11(value12, value13)
        value17.Position = value11
        value7 = captures.slot2.panel2
        value17.BackgroundColor3 = value7
        value7 = 0
        value17.BorderSizePixel = value7
        value16 = "Frame"
        value18 = captures.slot4
        value15 = value15(value16, value17, value18)
        tmp_X = captures.slot5
        readCell(tmp_X)(value15, 6)
        tmp_X = captures.slot1
        value12 = readCell(tmp_X)
        value6 = {}
        value7 = globals.UDim2.new
        value11 = 0
        value8 = 1
        value9 = (- 80)
        value10 = 1
        value7 = value7(value8, value9, value10, value11)
        value6.Size = value7
        value16 = globals.UDim2.fromOffset
        value17 = 10
        value18 = 0
        value16 = value16(value17, value18)
        value6.Position = value16
        value8 = 1
        value6.BackgroundTransparency = value8
        value8 = globals.Enum.Font.GothamMedium
        value6.Font = value8
        value6.Text = value14
        value8 = captures.slot2.subtext
        value6.TextColor3 = value8
        value6.TextSize = 12
        value8 = globals.Enum.TextXAlignment.Left
        value6.TextXAlignment = value8
        value13 = "TextLabel"
        value14 = value6
        value12(value13, value14, value15)
        tmp_X = captures.slot1
        value12 = readCell(tmp_X)
        value14 = {}
        value16 = globals.UDim2.fromOffset
        value17 = 56
        value18 = 22
        value16 = value16(value17, value18)
        value14.Size = value16
        value6 = globals.UDim2.new
        value7 = 1
        value8 = (- 64)
        value9 = 0.5
        value10 = (- 11)
        value6 = value6(value7, value8, value9, value10)
        value14.Position = value6
        value7 = captures.slot2.accent
        value14.BackgroundColor3 = value7
        value14.Text = "ON"
        value7 = globals.Enum.Font.GothamBold
        value14.Font = value7
        value16 = globals.Color3.new
        value19 = 1
        value17 = 1
        value18 = 1
        value16 = value16(value17, value18, value19)
        value14.TextColor3 = value16
        value7 = 12
        value14.TextSize = value7
        value14.AutoButtonColor = true
        value7 = 0
        value14.BorderSizePixel = value7
        value13 = "TextButton"
        value12 = value12(value13, value14, value15)
        tmp_X = captures.slot5
        readCell(tmp_X)(value12, 6)
        return value12
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1645 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value6, value7, value8, value11, value12, value13, value14, value15

        tmp_X = {...}
        value6, value7, value8 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        if value6 then
            value6 = captures.slot1[value6]
            value2 = (not value6)
            if (not value2) then
                value2 = (not value7)
                if (not value2) then
                    if value8 then
                        value2 = value6.stats[value7]
                        value7 = value6.stats[value7].kills
                        value7 = (value7 + (1))
                        value2.kills = value7
                        value6.streak = 0
                        tmp_X = captures.sentinelBCell
                    else
                        value2 = value6.stats[value7]
                        value11 = value6.stats[value7].deaths
                        value11 = (value11 + (1))
                        value2.deaths = value11
                        if value6.locked then
                            tmp_X = captures.sentinelBCell
                        else
                            tmp_X = captures.slot4
                            value11 = readCell(tmp_X)
                            value13 = captures.slot5
                            tmp_X = captures.slot6
                            value15 = readCell(tmp_X)
                            value12 = value6
                            value14 = value7
                            value11(value12, value13, value14, value15)
                        end
                    end
                end
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.toggleMinimized = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value3, value4, value6, value8

        tmp_X = captures.slot1
        value2 = (not (readCell(tmp_X)))
        tmp_X = captures.slot1
        writeCell(tmp_X, value2)
        tmp_X = captures.slot1
        value4 = (not (readCell(tmp_X)))
        captures.slot2.Visible = value4
        tmp_X = captures.slot1
        value4 = (not (readCell(tmp_X)))
        captures.slot3.Visible = value4
        value8 = captures.slot4
        tmp_X = captures.slot1
        value3 = readCell(tmp_X)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        if value3 then
            value6 = globals.UDim2.fromOffset
            value4 = 36
            value3 = 440
            value2 = value6
            value2 = value2(value3, value4)
        end
        if (not value2) then
            value6 = globals.UDim2.fromOffset
            value4 = 524
            value3 = 440
            value2 = value6
            value2 = value2(value3, value4)
        end
        value8.Size = value2
        value2 = captures.slot6
        tmp_X = captures.slot1
        value4 = readCell(tmp_X)
        tmp_X = captures.slot1
        value6 = readCell(tmp_X)
        if value4 then
            value6 = "+"
        end
        if (not value6) then
            value6 = "-"
        end
        value2.Text = value6
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value20, value21

        tmp_X = {...}
        value20, value21 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value1 = value20.stats[value21]
        value3 = (value1.kills + value1.deaths)
        if (value3 == 0) then
            return -1
        end
        value1 = (value1.deaths / value3)
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1710 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value4, value8

        tmp_X = captures.slot1
        value4 = readCell(tmp_X)()
        value8 = captures.slot2
        value4.autoQueueSide = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1716 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, value1, value2, value3, value4, value5, value6, value32, value33, value34, value35, value36

        tmp_X = {...}
        value36 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value6 = (readCell(tmp_X)()).reachAdjust[value36]
        if (not value6) then
            value6 = 0
        end
        value2 = captures.slot2.FANAKA_DEBUG
        if value2 then
            value2 = captures.slot2.FANAKA_DEBUG.reachTableRaw
            if value2 then
                value2 = value2[value36]
                if value2 then
                    value35 = ((globals.type(value2.n)) == "number")
                    if value35 then
                        value35 = value2.n
                        if (not value35) then
                            value35 = 0
                        end
                    else
                        value35 = 0
                    end
                else
                    value35 = 0
                end
            else
                value35 = 0
            end
        else
            value35 = 0
        end
        value3 = (value35 >= captures.slot3)
        if value3 then
            value1 = globals.type
            value4 = value2.samples
            value3 = ((value1(value4)) == "table")
            value1 = 7.2
            if value3 then
                value3 = {}
                value34 = 1
                value36 = 1
                loop = {parent = loop, index = (value34 - value36), limit = value35, step = value36}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value4 = loop.index
                    end
                    if loopContinues then
                        value5 = value2.samples[value4]
                        value3[value4] = value5
                        continue
                    else
                        break
                    end
                end
                loop = loop.parent
                globals.table.sort(value3)
                value32 = globals.math.clamp
                value33 = globals.math.ceil((captures.slot4 * value35))
                value34 = 1
                value32 = value32(value33, value34, value35)
                value5 = globals.math.clamp
                value2 = value3[value32]
                value3 = 7.2
                value4 = 11
                value1 = value5
                value1 = value1(value2, value3, value4)
            end
        else
            value1 = 7.2
        end
        value5 = globals.math.clamp
        value2 = (value1 + value6)
        value3 = 0
        value4 = (captures.slot5 + 2)
        value1 = value5
        value1 = value1(value2, value3, value4)
        return value1, value6, value35
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.addUIStroke = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value27, value28, value29, value30, value31

        tmp_X = {...}
        value27, value28 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = globals.Instance.new
        value2 = value2("UIPadding")
        value29 = globals.UDim.new
        value30 = 0
        value31 = value28
        value29 = value29(value30, value31)
        value2.PaddingLeft = value29
        value29 = globals.UDim.new
        value30 = 0
        value31 = value28
        value29 = value29(value30, value31)
        value2.PaddingRight = value29
        value29 = globals.UDim.new
        value30 = 0
        value31 = value28
        value29 = value29(value30, value31)
        value2.PaddingTop = value29
        value29 = globals.UDim.new
        value30 = 0
        value31 = value28
        value29 = value29(value30, value31)
        value2.PaddingBottom = value29
        value2.Parent = value27
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1757 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value5, value11, value12, value13, value14, value15

        tmp_X = {...}
        value13, value14, value15 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        if value13 then
            value13 = captures.slot1.players[value13]
            value2 = (not value13)
            if (not value2) then
                value2 = (not value14)
                if (not value2) then
                    if value15 then
                        value2 = value13.stats[value14]
                        value5 = value13.stats[value14].kills
                        value5 = (value5 + (1))
                        value2.kills = value5
                        value13.streak = 0
                    else
                        value2 = value13.stats[value14]
                        value5 = (value13.stats[value14].deaths + 1)
                        value2.deaths = value5
                        value2 = value13.locked
                        if (not value2) then
                            tmp_X = captures.slot3
                            value11 = readCell(tmp_X)
                            value2 = captures.slot1.STYLE_LIST
                            value15 = captures.slot1.deathRatio
                            value12 = value13
                            value13 = value2
                            value11(value12, value13, value14, value15)
                        end
                    end
                end
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1766 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value5, value6

        value6 = captures.slot1
        value5 = value6.GetNetworkPing(value6)
        tmp_X = captures.slot2
        writeCell(tmp_X, value5)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.updateDebugInterface = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_I, tmp_X, tmp_cache_r, tmp_key, tmp_n, tmp_value, value2, value3, value4, value5, value6, value7, value11, value13
        local sharedPath_250

        sharedPath_250 = function(...)
            if (value11 == "receive") then
                value13 = captures.slot8.reach.value
                value2 = ((globals.type(value7.victimReach)) == "number")
                if value2 then
                    value6 = globals.string.format
                    value4 = value7.victimReach
                    value5 = globals.tonumber(value7.victimReachN)
                    if (not value5) then
                        value5 = 0
                    end
                    value3 = "%.2f studs \194\183 n%d"
                    value2 = value6
                    value2 = value2(value3, value4, value5)
                    if (not value2) then
                        value2 = "\226\128\148"
                    end
                else
                    value2 = "\226\128\148"
                end
                value13.Text = value2
                value2 = value7.loseLoseStyle
                value3 = captures.slot8.llStyle.value
                value5 = (value2 == "grab")
                if value5 then
                    value5 = "Grab"
                else
                    value5 = (value2 == "run")
                    if value5 then
                        value5 = "Run"
                    else
                        value5 = "\226\128\148"
                    end
                end
                value3.Text = value5
                value3 = captures.slot8.llStyle.value
                value5 = (value2 == "grab")
                if value5 then
                    value5 = captures.slot9.good
                    if (not value5) then
                        value5 = (value2 == "run")
                        if value5 then
                            value5 = captures.slot9.text
                            if (not value5) then
                                value5 = captures.slot9.idle
                            end
                        else
                            value5 = captures.slot9.idle
                        end
                    end
                else
                    value5 = (value2 == "run")
                    if value5 then
                        value5 = captures.slot9.text
                        if (not value5) then
                            value5 = captures.slot9.idle
                        end
                    else
                        value5 = captures.slot9.idle
                    end
                end
                value3.TextColor3 = value5
            else
                value2 = captures.slot8.reach.value
                value2.Text = "\226\128\148"
                value2 = captures.slot8.llStyle.value
                value2.Text = "\226\128\148"
                value2 = captures.slot8.llStyle.value
                value4 = captures.slot9.text
                value2.TextColor3 = value4
            end
            value2 = value7.openingStyle
            value3 = (value2 == "corner")
            if value3 then
                value3 = captures.slot8.opening.value
                value5 = (value2 == "corner")
                if value5 then
                    value5 = "Corner (hold L-corner)"
                else
                    value5 = "Charge (rush holder)"
                end
                value3.Text = value5
                value3 = captures.slot8.opening.value
                value2 = (value2 == "charge")
                if value2 then
                    value2 = captures.slot9.good
                    if (not value2) then
                        value2 = captures.slot9.accent
                    end
                else
                    value2 = captures.slot9.accent
                end
                value3.TextColor3 = value2
            else
                value3 = (value2 == "charge")
                if value3 then
                    value3 = captures.slot8.opening.value
                    value5 = (value2 == "corner")
                    if value5 then
                        value5 = "Corner (hold L-corner)"
                    else
                        value5 = "Charge (rush holder)"
                    end
                    value3.Text = value5
                    value3 = captures.slot8.opening.value
                    value2 = (value2 == "charge")
                    if value2 then
                        value2 = captures.slot9.good
                        if (not value2) then
                            value2 = captures.slot9.accent
                        end
                    else
                        value2 = captures.slot9.accent
                    end
                    value3.TextColor3 = value2
                else
                    value4 = captures.slot8.opening.value
                    value4.Text = "\226\128\148"
                    value4 = captures.slot8.opening.value
                    value6 = captures.slot9.text
                    value4.TextColor3 = value6
                end
            end
            value2 = captures.slot8.bombTime.value
            tmp_X = captures.slot10
            value4 = readCell(tmp_X)(value7.bombTime)
            value2.Text = value4
            value6 = captures.slot8.nearest.value
            value3 = ((globals.type(value7.nearestDist)) == "number")
            if value3 then
                value2 = globals.string.format
                value5 = value7.nearestDist
                value4 = "%.1f studs"
                value3 = value2
                value3 = value3(value4, value5)
                if (not value3) then
                    value3 = "\226\128\148"
                end
            else
                value3 = "\226\128\148"
            end
            value6.Text = value3
            value2 = globals.type(value7.secondDist)
            value2 = (value2 == "number")
            if value2 then
                value3 = value7.secondDist
                value2 = (value3 > (0))
                if value2 then
                    value6 = captures.slot8.second.value
                    value2 = globals.string.format
                    value4 = value7.secondDist
                    value5 = value7.secondHasBomb
                    if value5 then
                        value5 = "  \226\128\162 bomb"
                    else
                        value5 = ""
                    end
                    value3 = "%.1f studs%s"
                    value2 = value2(value3, value4, value5)
                    value6.Text = value2
                    value2 = captures.slot8.second.value
                    value4 = value7.secondHasBomb
                    if value4 then
                        value4 = captures.slot9.bad
                        if (not value4) then
                            value4 = captures.slot9.text
                        end
                    else
                        value4 = captures.slot9.text
                    end
                else
                    value2 = captures.slot8.second.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.second.value
                    value4 = captures.slot9.text
                end
            else
                value2 = captures.slot8.second.value
                value2.Text = "\226\128\148"
                value2 = captures.slot8.second.value
                value4 = captures.slot9.text
            end
            value2.TextColor3 = value4
            value2 = captures.slot8.tagTime.value
            tmp_X = captures.slot10
            value4 = readCell(tmp_X)(value7.tagTime)
            value2.Text = value4
            value2 = captures.slot8.contactBomb.value
            tmp_X = captures.slot10
            value4 = readCell(tmp_X)(value7.contactBombTime)
            value2.Text = value4
            value2 = globals.tonumber(value7.contactBombTime)
            if (value11 == "give") then
                value3 = value7.goodWindow
                if value3 then
                    value3 = (value2 ~= nil)
                    if value3 then
                        value3 = (value2 > 0)
                        value2 = captures.slot8.contactBomb.value
                        if value3 then
                            value3 = captures.slot9.good
                            if (not value3) then
                                value3 = captures.slot9.bad
                            end
                        else
                            value3 = captures.slot9.bad
                        end
                    else
                        value2 = captures.slot8.contactBomb.value
                        value3 = captures.slot9.bad
                    end
                else
                    value2 = captures.slot8.contactBomb.value
                    value3 = captures.slot9.bad
                end
            else
                value3 = value7.goodWindow
                value2 = captures.slot8.contactBomb.value
                if value3 then
                    value3 = captures.slot9.good
                    if (not value3) then
                        value3 = captures.slot9.bad
                    end
                else
                    value3 = captures.slot9.bad
                end
            end
            value2.TextColor3 = value3
            value2 = captures.slot8.navMode.value
            value4 = value7.navMode
            if (not value4) then
                value4 = "\226\128\148"
            end
            value2.Text = value4
            value2 = value7.navMode
            if (value2 == "around") then
                value6 = captures.slot8.navSide.value
                value2 = globals.string.format
                tmp_X = captures.slot11
                value4 = readCell(tmp_X)(value7.navCommitted)
                tmp_X = captures.slot11
                value3 = readCell(tmp_X)
                value5 = value7.navNew
                value5 = table.pack(value3(value5))
                value3 = "%s / %s"
                tmp_n = value5
                tmp_I = tmp_n.n
                tmp_cache_r = ((3 + tmp_I) - 1)
                tmp_n.n = tmp_cache_r
                table.move(tmp_n, 1, tmp_I, 3, tmp_n)
                table.move({[3] = value3, [4] = value4}, 3, 4, 1, tmp_n)
                tmp_D = table.pack(value2(table.unpack(tmp_n, 1, tmp_n.n)))
                value2 = rawget(tmp_D, 1)
                value6.Text = value2
                value2 = captures.slot8.navSide.value
                value4 = (value7.navCommitted ~= value7.navNew)
                if value4 then
                    value4 = captures.slot9.bad
                    if (not value4) then
                        value4 = captures.slot9.text
                    end
                else
                    value4 = captures.slot9.text
                end
                value2.TextColor3 = value4
                value13 = captures.slot8.navRoute.value
                value2 = globals.string.format
                tmp_X = captures.slot12
                value4 = readCell(tmp_X)(value7.navCostR)
                tmp_X = captures.slot12
                value5 = readCell(tmp_X)(value7.navCostL)
                value6 = value7.navEdgeR
                if value6 then
                    value6 = "y"
                else
                    value6 = "n"
                end
                value7 = value7.navEdgeL
                if value7 then
                    value7 = "y"
                else
                    value7 = "n"
                end
                value3 = "%s / %s  (%s/%s)"
                value2 = value2(value3, value4, value5, value6, value7)
                value13.Text = value2
            else
                value2 = captures.slot8.navSide.value
                value2.Text = "\226\128\148"
                value2 = captures.slot8.navSide.value
                value4 = captures.slot9.text
                value2.TextColor3 = value4
                value2 = captures.slot8.navRoute.value
                value2.Text = "\226\128\148"
            end
            return
        end

        value2 = captures.slot1
        tmp_X = captures.slot2
        value4 = readCell(tmp_X)()
        value2.Text = value4
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        if (value2 == "Bots") then
            tmp_X = captures.slot5
            readCell(tmp_X)()
        end
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        if (value2 ~= "Debug") then
        else
            value7 = captures.slot7.FANAKA_DEBUG
            if (not value7) then
                value2 = captures.slot8.__header
                value2.Text = "Prediction \226\128\148 waiting for bot\226\128\166"
                value2 = captures.slot8.__header
                value4 = captures.slot9.subtext
                value2.TextColor3 = value4
                value2 = globals.pairs
                value3 = captures.slot8
                value2, value3, value4 = value2(value3)
                loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
                while true do
                    loopContinues, tmp_key, tmp_value = loop.iterator()
                    if loopContinues then
                        value3, value4 = tmp_key, tmp_value
                    end
                    if loopContinues then
                        value5 = globals.type(value4)
                        if (value5 ~= "table") then
                            continue
                        else
                            value5 = value4.value
                            value5.Text = "\226\128\148"
                            value5 = value4.value
                            value7 = captures.slot9.text
                            value5.TextColor3 = value7
                            continue
                        end
                    else
                        break
                    end
                end
                loop = loop.parent
            else
                value11 = value7.mode
                if (not value11) then
                    value11 = "idle"
                end
                value2 = Functions.helper_1838({catalogCell = captures.catalogCell, slot2 = captures.slot9}, globals)
                value2(captures.slot8.vizGraph, value7.vizGraph)
                value2(captures.slot8.vizRays, value7.vizRays)
                value2(captures.slot8.vizBeams, value7.vizBeams)
                if (value11 == "give") then
                    value2 = captures.slot8.__header
                    value2.Text = "Prediction \226\128\148 GIVING (we hold the bomb \226\134\146 victim)"
                    value2 = captures.slot8.__header
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.mode.value
                    value2.Text = "Giving"
                    value2 = captures.slot8.tagTime.label
                    value2.Text = "Time to reach victim"
                    value2 = captures.slot8.contactBomb.label
                    value2.Text = "Bomb time at give"
                else
                    if (value11 == "receive") then
                        value2 = captures.slot8.__header
                        value2.Text = "Prediction \226\128\148 RECEIVING (they hold the bomb \226\134\146 us)"
                        value2 = captures.slot8.__header
                        value4 = captures.slot9.text
                        value2.TextColor3 = value4
                        value2 = captures.slot8.mode.value
                        value4 = "Receiving"
                        value2.Text = value4
                        value2 = captures.slot8.tagTime.label
                        value4 = "Time until they reach us"
                        value2.Text = value4
                        value2 = captures.slot8.contactBomb.label
                        value4 = "Bomb time when tagged"
                        value2.Text = value4
                    else
                        value2 = captures.slot8.__header
                        value2.Text = "Prediction \226\128\148 IDLE (no active target)"
                        value2 = captures.slot8.__header
                        value4 = captures.slot9.subtext
                        value2.TextColor3 = value4
                        value2 = captures.slot8.mode.value
                        value2.Text = "Idle"
                        value2 = captures.slot8.tagTime.label
                        value2.Text = "Tag prediction"
                        value2 = captures.slot8.contactBomb.label
                        value4 = "Bomb time at tag"
                        value2.Text = value4
                    end
                end
                value2 = captures.slot8.mode.value
                value4 = (value11 == "idle")
                if value4 then
                    value4 = captures.slot9.idle
                    if (not value4) then
                        value4 = captures.slot9.text
                    end
                else
                    value4 = captures.slot9.text
                end
                value2.TextColor3 = value4
                if (value11 == "idle") then
                    value2 = captures.slot8.bombTime.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.nearest.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.second.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.second.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.tagTime.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.contactBomb.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.contactBomb.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.navMode.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.navSide.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.navSide.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.navRoute.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.reach.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.llStyle.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.llStyle.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.aggro.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.aggro.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.waverMode.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.waverMode.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                    value2 = captures.slot8.opening.value
                    value2.Text = "\226\128\148"
                    value2 = captures.slot8.opening.value
                    value4 = captures.slot9.text
                    value2.TextColor3 = value4
                else
                    if (value11 == "give") then
                        value2 = value7.aggroStyle
                        value3 = captures.slot8.aggro.value
                        value5 = (value2 == "aggressive")
                        if value5 then
                            value5 = "Press (raw bomb time)"
                        else
                            value5 = (value2 == "patient")
                            if value5 then
                                value5 = "Patient (contact time)"
                            else
                                value5 = "\226\128\148"
                            end
                        end
                        value3.Text = value5
                        value3 = captures.slot8.aggro.value
                        value5 = (value2 == "aggressive")
                        if value5 then
                            value5 = captures.slot9.good
                            if (not value5) then
                                value5 = (value2 == "patient")
                                if value5 then
                                    value5 = captures.slot9.text
                                    if (not value5) then
                                        value5 = captures.slot9.idle
                                    end
                                else
                                    value5 = captures.slot9.idle
                                end
                            end
                        else
                            value5 = (value2 == "patient")
                            if value5 then
                                value5 = captures.slot9.text
                                if (not value5) then
                                    value5 = captures.slot9.idle
                                end
                            else
                                value5 = captures.slot9.idle
                            end
                        end
                        value3.TextColor3 = value5
                    else
                        value2 = captures.slot8.aggro.value
                        value2.Text = "\226\128\148"
                        value2 = captures.slot8.aggro.value
                        value4 = captures.slot9.text
                        value2.TextColor3 = value4
                    end
                    if (value11 == "give") then
                        value2 = value7.waverMode
                        value3 = captures.slot8.waverMode.value
                        value5 = (value2 == "hold")
                        if value5 then
                            value5 = "Hold (orbit-guard)"
                        else
                            value5 = (value2 == "chase")
                            if value5 then
                                value5 = "Chase (pursue runner)"
                            else
                                value5 = (value2 == "charge")
                                if value5 then
                                    value5 = "Charge (closing in)"
                                else
                                    value5 = "\226\128\148"
                                end
                            end
                        end
                        value3.Text = value5
                        value3 = captures.slot8.waverMode.value
                        value5 = (value2 == "chase")
                        if value5 then
                            value5 = captures.slot9.good
                            if (not value5) then
                                value5 = (value2 == "charge")
                                if value5 then
                                    value5 = captures.slot9.lock
                                    if (not value5) then
                                        value5 = (value2 == "hold")
                                        if value5 then
                                            value5 = captures.slot9.accent
                                            if (not value5) then
                                                value5 = captures.slot9.text
                                            end
                                        else
                                            value5 = captures.slot9.text
                                        end
                                    end
                                else
                                    value5 = (value2 == "hold")
                                    if value5 then
                                        value5 = captures.slot9.accent
                                        if (not value5) then
                                            value5 = captures.slot9.text
                                        end
                                    else
                                        value5 = captures.slot9.text
                                    end
                                end
                            end
                        else
                            value5 = (value2 == "charge")
                            if value5 then
                                value5 = captures.slot9.lock
                                if (not value5) then
                                    value5 = (value2 == "hold")
                                    if value5 then
                                        value5 = captures.slot9.accent
                                        if (not value5) then
                                            value5 = captures.slot9.text
                                        end
                                    else
                                        value5 = captures.slot9.text
                                    end
                                end
                            else
                                value5 = (value2 == "hold")
                                if value5 then
                                    value5 = captures.slot9.accent
                                    if (not value5) then
                                        value5 = captures.slot9.text
                                    end
                                else
                                    value5 = captures.slot9.text
                                end
                            end
                        end
                        value3.TextColor3 = value5
                    else
                        value2 = captures.slot8.waverMode.value
                        value2.Text = "\226\128\148"
                        value2 = captures.slot8.waverMode.value
                        value4 = captures.slot9.text
                        value2.TextColor3 = value4
                    end
                    return sharedPath_250(...)
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.updateAutoQueue = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value3, value4, value5, value7, value9, value10, value11, value12, value13, value15, value17

        value7 = captures.localPlayer.Character
        if value7 then
            value3 = value7
            value5 = value3.FindFirstChild
            value4 = "HumanoidRootPart"
            value2 = value5
            value15 = (value2(value3, value4))
        else
            value15 = value7
        end
        if value7 then
            value3 = value7
            value2 = value3.FindFirstChildOfClass
            value9 = value3
            value5 = "Humanoid"
            value3 = value2
            value4 = value9
            value7 = (value3(value4, value5))
        end
        value11 = globals.workspace
        value2 = value11.FindFirstChild
        value12 = "Arenas"
        value10 = value2
        value4 = (value10(value11, value12))
        if value15 then
            value2 = value7
            if value2 then
                value2 = (not value4)
                if (not value2) then
                    value2 = (captures.queueState.state ~= "start")
                    if value2 then
                        value2 = (((globals.tick()) - captures.queueState.lastCheck) >= captures.queueState.CHECK_EVERY)
                        if value2 then
                            value2 = captures.queueState
                            value5 = globals.tick()
                            value2.lastCheck = value5
                            value9 = captures.queueState.sane
                            value10 = value4
                            value11 = value15
                            value2 = (not (value9(value10, value11)))
                            if value2 then
                                captures.queueState.reset()
                                value2 = captures.debugState
                                value5 = "restart"
                                value2.autoQueueState = value5
                            else
                                value2 = captures.queueState.state
                                if (value2 == "start") then
                                    value2 = captures.queueState.chooseArena(value4)
                                    if (not value2) then
                                        captures.debugState.autoQueueState = "waiting"
                                    else
                                        captures.queueState.arena = value2
                                        globals.pcall((Functions.moveToArenaApproach({slot1 = value15, slot2 = value4, slot3 = value2, catalogCell = captures.catalogCell}, globals)))
                                        value7 = captures.queueState
                                        captures.queueState.attempts = 0
                                        value7.state = "toslot"
                                        captures.debugState.autoQueueState = "teleporting"
                                    end
                                else
                                    value2 = captures.queueState.state
                                    if (value2 == "toslot") then
                                        value9 = captures.queueState.chooseSlot
                                        value11 = captures.queueState.arena
                                        value10 = value4
                                        value9, value10 = value9(value10, value11)
                                        value2 = value9
                                        value3 = value10
                                        value9 = (not value2)
                                        if value9 then
                                            captures.queueState.reset()
                                            captures.debugState.autoQueueState = "no-slot"
                                        else
                                            value11 = captures.queueState
                                            captures.queueState.side = value2
                                            value11.slot = value3
                                            value17 = captures.queueState.padPos
                                            value9 = captures.queueState.slotPad
                                            value11 = captures.queueState.arena
                                            value10 = value4
                                            value12 = value2
                                            value13 = value3
                                            value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                            value9 = value17(table.unpack(value9, 1, value9.n))
                                            if value9 then
                                                value3 = value7
                                                value3.MoveTo(value3, value9)
                                            end
                                            value2 = captures.queueState
                                            value9 = captures.queueState
                                            value11 = globals.tick()
                                            value2.slotStart = value11
                                            value9.state = "onslot"
                                            captures.debugState.autoQueueState = "to-slot"
                                        end
                                    else
                                        value2 = captures.queueState.state
                                        if (value2 == "onslot") then
                                            captures.debugState.autoQueueState = "on-slot"
                                            value2 = ((globals.tick()) - captures.queueState.slotStart)
                                            value3 = captures.queueState.READY_WAIT
                                            if (not (value2 < value3)) then
                                                value9 = captures.queueState.slotPad
                                                value11 = captures.queueState.arena
                                                value12 = captures.queueState.side
                                                value13 = captures.queueState.slot
                                                value10 = value4
                                                value9 = value9(value10, value11, value12, value13)
                                                value2 = captures.queueState.slotPlayer(value9)
                                                value3 = captures.localPlayer
                                                if (value2 == value3) then
                                                    captures.queueState.state = "ready"
                                                    value2 = captures.queueState
                                                    value10 = 0
                                                    value2.lastReady = value10
                                                else
                                                    value2 = captures.queueState
                                                    value10 = (captures.queueState.attempts + 1)
                                                    value2.attempts = value10
                                                    value2 = captures.queueState.attempts
                                                    value3 = captures.queueState.MAX_TRY
                                                    if (value3 < value2) then
                                                        captures.queueState.reset()
                                                    else
                                                        value9 = captures.queueState.padPos(value9)
                                                        if value9 then
                                                            value3 = value7
                                                            value2 = value3.MoveTo
                                                            value10 = globals.Vector3.new
                                                            value11 = 6
                                                            value12 = 0
                                                            value13 = 0
                                                            value2(value3, (value9 + (value10(value11, value12, value13))))
                                                        end
                                                        value2 = captures.queueState
                                                        value9 = captures.queueState
                                                        value11 = globals.tick()
                                                        value2.wiggleStart = value11
                                                        value9.state = "wiggleoff"
                                                    end
                                                end
                                            end
                                        else
                                            value2 = captures.queueState.state
                                            if (value2 == "wiggleoff") then
                                                value2 = captures.debugState
                                                value9 = "retry"
                                                value2.autoQueueState = value9
                                                value2 = ((globals.tick()) - captures.queueState.wiggleStart)
                                                value3 = captures.queueState.WIGGLE
                                                if (not (value2 < value3)) then
                                                    value2 = captures.queueState.padPos
                                                    value9 = captures.queueState.slotPad
                                                    value11 = captures.queueState.arena
                                                    value12 = captures.queueState.side
                                                    value13 = captures.queueState.slot
                                                    value10 = value4
                                                    value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                                    value9 = value2(table.unpack(value9, 1, value9.n))
                                                    if value9 then
                                                        value3 = value7
                                                        value3.MoveTo(value3, value9)
                                                    end
                                                    value2 = captures.queueState
                                                    value7 = captures.queueState
                                                    value10 = globals.tick()
                                                    value11 = "onslot"
                                                    value2.slotStart = value10
                                                    value7.state = value11
                                                end
                                            else
                                                value2 = (captures.queueState.state == "ready")
                                                if value2 then
                                                    value2 = captures.queueState.padPos
                                                    value9 = captures.queueState.slotPad
                                                    value11 = captures.queueState.arena
                                                    value12 = captures.queueState.side
                                                    value13 = captures.queueState.slot
                                                    value10 = value4
                                                    value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                                    value9 = value2(table.unpack(value9, 1, value9.n))
                                                    if value9 then
                                                        value3 = value7
                                                        value3.MoveTo(value3, value9)
                                                        tmp_X = captures.sentinelBCell
                                                        value2 = readCell(tmp_X)
                                                    end
                                                    value12 = (captures.queueState.side == "Left")
                                                    if value12 then
                                                        value12 = "Right"
                                                    else
                                                        value12 = "Left"
                                                    end
                                                    value9 = captures.queueState.sideCount
                                                    value11 = captures.queueState.arena
                                                    value10 = value4
                                                    value9 = value9(value10, value11, value12)
                                                    if (1 <= value9) then
                                                        value2 = captures.debugState
                                                        value9 = "readied"
                                                        value2.autoQueueState = value9
                                                        value2 = (((globals.tick()) - captures.queueState.lastReady) >= captures.queueState.READY_REFIRE)
                                                        if value2 then
                                                            value2 = captures.queueState
                                                            value9 = globals.tick()
                                                            value2.lastReady = value9
                                                            globals.pcall((Functions.sendQueueReady({}, globals)))
                                                        end
                                                    else
                                                        tmp_X = captures.authReadyCell
                                                        if (not (not (readCell(tmp_X)))) then
                                                            captures.debugState.autoQueueState = "waiting-opponent"
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        else
                            value2 = captures.queueState.state
                            if (value2 == "start") then
                                value2 = captures.queueState.chooseArena(value4)
                                if (not value2) then
                                    captures.debugState.autoQueueState = "waiting"
                                else
                                    captures.queueState.arena = value2
                                    globals.pcall((Functions.moveToArenaApproach({slot1 = value15, slot2 = value4, slot3 = value2, catalogCell = captures.catalogCell}, globals)))
                                    value7 = captures.queueState
                                    captures.queueState.attempts = 0
                                    value7.state = "toslot"
                                    captures.debugState.autoQueueState = "teleporting"
                                end
                            else
                                value2 = captures.queueState.state
                                if (value2 == "toslot") then
                                    value9 = captures.queueState.chooseSlot
                                    value11 = captures.queueState.arena
                                    value10 = value4
                                    value9, value10 = value9(value10, value11)
                                    value2 = value9
                                    value3 = value10
                                    value9 = (not value2)
                                    if value9 then
                                        captures.queueState.reset()
                                        captures.debugState.autoQueueState = "no-slot"
                                    else
                                        value11 = captures.queueState
                                        captures.queueState.side = value2
                                        value11.slot = value3
                                        value17 = captures.queueState.padPos
                                        value9 = captures.queueState.slotPad
                                        value11 = captures.queueState.arena
                                        value10 = value4
                                        value12 = value2
                                        value13 = value3
                                        value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                        value9 = value17(table.unpack(value9, 1, value9.n))
                                        if value9 then
                                            value3 = value7
                                            value3.MoveTo(value3, value9)
                                        end
                                        value2 = captures.queueState
                                        value9 = captures.queueState
                                        value11 = globals.tick()
                                        value2.slotStart = value11
                                        value9.state = "onslot"
                                        captures.debugState.autoQueueState = "to-slot"
                                    end
                                else
                                    value2 = captures.queueState.state
                                    if (value2 == "onslot") then
                                        captures.debugState.autoQueueState = "on-slot"
                                        value2 = ((globals.tick()) - captures.queueState.slotStart)
                                        value3 = captures.queueState.READY_WAIT
                                        if (not (value2 < value3)) then
                                            value9 = captures.queueState.slotPad
                                            value11 = captures.queueState.arena
                                            value12 = captures.queueState.side
                                            value13 = captures.queueState.slot
                                            value10 = value4
                                            value9 = value9(value10, value11, value12, value13)
                                            value2 = captures.queueState.slotPlayer(value9)
                                            value3 = captures.localPlayer
                                            if (value2 == value3) then
                                                captures.queueState.state = "ready"
                                                value2 = captures.queueState
                                                value10 = 0
                                                value2.lastReady = value10
                                            else
                                                value2 = captures.queueState
                                                value10 = (captures.queueState.attempts + 1)
                                                value2.attempts = value10
                                                value2 = captures.queueState.attempts
                                                value3 = captures.queueState.MAX_TRY
                                                if (value3 < value2) then
                                                    captures.queueState.reset()
                                                else
                                                    value9 = captures.queueState.padPos(value9)
                                                    if value9 then
                                                        value3 = value7
                                                        value2 = value3.MoveTo
                                                        value10 = globals.Vector3.new
                                                        value11 = 6
                                                        value12 = 0
                                                        value13 = 0
                                                        value2(value3, (value9 + (value10(value11, value12, value13))))
                                                    end
                                                    value2 = captures.queueState
                                                    value9 = captures.queueState
                                                    value11 = globals.tick()
                                                    value2.wiggleStart = value11
                                                    value9.state = "wiggleoff"
                                                end
                                            end
                                        end
                                    else
                                        value2 = captures.queueState.state
                                        if (value2 == "wiggleoff") then
                                            value2 = captures.debugState
                                            value9 = "retry"
                                            value2.autoQueueState = value9
                                            value2 = ((globals.tick()) - captures.queueState.wiggleStart)
                                            value3 = captures.queueState.WIGGLE
                                            if (not (value2 < value3)) then
                                                value2 = captures.queueState.padPos
                                                value9 = captures.queueState.slotPad
                                                value11 = captures.queueState.arena
                                                value12 = captures.queueState.side
                                                value13 = captures.queueState.slot
                                                value10 = value4
                                                value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                                value9 = value2(table.unpack(value9, 1, value9.n))
                                                if value9 then
                                                    value3 = value7
                                                    value3.MoveTo(value3, value9)
                                                end
                                                value2 = captures.queueState
                                                value7 = captures.queueState
                                                value10 = globals.tick()
                                                value11 = "onslot"
                                                value2.slotStart = value10
                                                value7.state = value11
                                            end
                                        else
                                            value2 = (captures.queueState.state == "ready")
                                            if value2 then
                                                value2 = captures.queueState.padPos
                                                value9 = captures.queueState.slotPad
                                                value11 = captures.queueState.arena
                                                value12 = captures.queueState.side
                                                value13 = captures.queueState.slot
                                                value10 = value4
                                                value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                                value9 = value2(table.unpack(value9, 1, value9.n))
                                                if value9 then
                                                    value3 = value7
                                                    value3.MoveTo(value3, value9)
                                                    tmp_X = captures.sentinelBCell
                                                    value2 = readCell(tmp_X)
                                                end
                                                value12 = (captures.queueState.side == "Left")
                                                if value12 then
                                                    value12 = "Right"
                                                else
                                                    value12 = "Left"
                                                end
                                                value9 = captures.queueState.sideCount
                                                value11 = captures.queueState.arena
                                                value10 = value4
                                                value9 = value9(value10, value11, value12)
                                                if (1 <= value9) then
                                                    value2 = captures.debugState
                                                    value9 = "readied"
                                                    value2.autoQueueState = value9
                                                    value2 = (((globals.tick()) - captures.queueState.lastReady) >= captures.queueState.READY_REFIRE)
                                                    if value2 then
                                                        value2 = captures.queueState
                                                        value9 = globals.tick()
                                                        value2.lastReady = value9
                                                        globals.pcall((Functions.sendQueueReady({}, globals)))
                                                    end
                                                else
                                                    tmp_X = captures.authReadyCell
                                                    if (not (not (readCell(tmp_X)))) then
                                                        captures.debugState.autoQueueState = "waiting-opponent"
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    else
                        value2 = captures.queueState.state
                        if (value2 == "start") then
                            value2 = captures.queueState.chooseArena(value4)
                            if (not value2) then
                                captures.debugState.autoQueueState = "waiting"
                            else
                                captures.queueState.arena = value2
                                globals.pcall((Functions.moveToArenaApproach({slot1 = value15, slot2 = value4, slot3 = value2, catalogCell = captures.catalogCell}, globals)))
                                value7 = captures.queueState
                                captures.queueState.attempts = 0
                                value7.state = "toslot"
                                captures.debugState.autoQueueState = "teleporting"
                            end
                        else
                            value2 = captures.queueState.state
                            if (value2 == "toslot") then
                                value9 = captures.queueState.chooseSlot
                                value11 = captures.queueState.arena
                                value10 = value4
                                value9, value10 = value9(value10, value11)
                                value2 = value9
                                value3 = value10
                                value9 = (not value2)
                                if value9 then
                                    captures.queueState.reset()
                                    captures.debugState.autoQueueState = "no-slot"
                                else
                                    value11 = captures.queueState
                                    captures.queueState.side = value2
                                    value11.slot = value3
                                    value17 = captures.queueState.padPos
                                    value9 = captures.queueState.slotPad
                                    value11 = captures.queueState.arena
                                    value10 = value4
                                    value12 = value2
                                    value13 = value3
                                    value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                    value9 = value17(table.unpack(value9, 1, value9.n))
                                    if value9 then
                                        value3 = value7
                                        value3.MoveTo(value3, value9)
                                    end
                                    value2 = captures.queueState
                                    value9 = captures.queueState
                                    value11 = globals.tick()
                                    value2.slotStart = value11
                                    value9.state = "onslot"
                                    captures.debugState.autoQueueState = "to-slot"
                                end
                            else
                                value2 = captures.queueState.state
                                if (value2 == "onslot") then
                                    captures.debugState.autoQueueState = "on-slot"
                                    value2 = ((globals.tick()) - captures.queueState.slotStart)
                                    value3 = captures.queueState.READY_WAIT
                                    if (not (value2 < value3)) then
                                        value9 = captures.queueState.slotPad
                                        value11 = captures.queueState.arena
                                        value12 = captures.queueState.side
                                        value13 = captures.queueState.slot
                                        value10 = value4
                                        value9 = value9(value10, value11, value12, value13)
                                        value2 = captures.queueState.slotPlayer(value9)
                                        value3 = captures.localPlayer
                                        if (value2 == value3) then
                                            captures.queueState.state = "ready"
                                            value2 = captures.queueState
                                            value10 = 0
                                            value2.lastReady = value10
                                        else
                                            value2 = captures.queueState
                                            value10 = (captures.queueState.attempts + 1)
                                            value2.attempts = value10
                                            value2 = captures.queueState.attempts
                                            value3 = captures.queueState.MAX_TRY
                                            if (value3 < value2) then
                                                captures.queueState.reset()
                                            else
                                                value9 = captures.queueState.padPos(value9)
                                                if value9 then
                                                    value3 = value7
                                                    value2 = value3.MoveTo
                                                    value10 = globals.Vector3.new
                                                    value11 = 6
                                                    value12 = 0
                                                    value13 = 0
                                                    value2(value3, (value9 + (value10(value11, value12, value13))))
                                                end
                                                value2 = captures.queueState
                                                value9 = captures.queueState
                                                value11 = globals.tick()
                                                value2.wiggleStart = value11
                                                value9.state = "wiggleoff"
                                            end
                                        end
                                    end
                                else
                                    value2 = captures.queueState.state
                                    if (value2 == "wiggleoff") then
                                        value2 = captures.debugState
                                        value9 = "retry"
                                        value2.autoQueueState = value9
                                        value2 = ((globals.tick()) - captures.queueState.wiggleStart)
                                        value3 = captures.queueState.WIGGLE
                                        if (not (value2 < value3)) then
                                            value2 = captures.queueState.padPos
                                            value9 = captures.queueState.slotPad
                                            value11 = captures.queueState.arena
                                            value12 = captures.queueState.side
                                            value13 = captures.queueState.slot
                                            value10 = value4
                                            value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                            value9 = value2(table.unpack(value9, 1, value9.n))
                                            if value9 then
                                                value3 = value7
                                                value3.MoveTo(value3, value9)
                                            end
                                            value2 = captures.queueState
                                            value7 = captures.queueState
                                            value10 = globals.tick()
                                            value11 = "onslot"
                                            value2.slotStart = value10
                                            value7.state = value11
                                        end
                                    else
                                        value2 = (captures.queueState.state == "ready")
                                        if value2 then
                                            value2 = captures.queueState.padPos
                                            value9 = captures.queueState.slotPad
                                            value11 = captures.queueState.arena
                                            value12 = captures.queueState.side
                                            value13 = captures.queueState.slot
                                            value10 = value4
                                            value9 = table.pack(value9(table.unpack({[10] = value10, [11] = value11, [12] = value12, [13] = value13}, 10, 13)))
                                            value9 = value2(table.unpack(value9, 1, value9.n))
                                            if value9 then
                                                value3 = value7
                                                value3.MoveTo(value3, value9)
                                                tmp_X = captures.sentinelBCell
                                                value2 = readCell(tmp_X)
                                            end
                                            value12 = (captures.queueState.side == "Left")
                                            if value12 then
                                                value12 = "Right"
                                            else
                                                value12 = "Left"
                                            end
                                            value9 = captures.queueState.sideCount
                                            value11 = captures.queueState.arena
                                            value10 = value4
                                            value9 = value9(value10, value11, value12)
                                            if (1 <= value9) then
                                                value2 = captures.debugState
                                                value9 = "readied"
                                                value2.autoQueueState = value9
                                                value2 = (((globals.tick()) - captures.queueState.lastReady) >= captures.queueState.READY_REFIRE)
                                                if value2 then
                                                    value2 = captures.queueState
                                                    value9 = globals.tick()
                                                    value2.lastReady = value9
                                                    globals.pcall((Functions.sendQueueReady({}, globals)))
                                                end
                                            else
                                                tmp_X = captures.authReadyCell
                                                if (not (not (readCell(tmp_X)))) then
                                                    captures.debugState.autoQueueState = "waiting-opponent"
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            else
        
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.getRegistry = function(captures, globals)
    local function recovered(...)
        local value2

        value2 = ((globals.type(captures.slot1.FANAKA)) == "table")
        if value2 then
            value2 = captures.slot1.FANAKA
            if (not value2) then
                value2 = nil
            end
        else
            value2 = nil
        end
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1781 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value5, value17, value18, value22, value27, value28, value29, value30

        tmp_X = {...}
        value27 = rawget(tmp_X, 1)
        if (not value27) then
            return 25
        end
        value29 = captures.slot1
        value1 = value29.FindFirstChild
        value30 = value27.Name
        value28 = value1
        if ((value28(value29, value30)).Data.Slot.Value == value22) then
            return 15
        end
        value29 = captures.slot1
        value1 = value29.FindFirstChild
        value30 = value27.Name
        value28 = value1
        value29 = (value28(value29, value30)).Data.Slot.Value
        value28 = value29.WaitForChild
        value30 = "Statsboard"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "UI_Back"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "Main"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "StatsHolder"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "HeadshotHolder"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "Headshot"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "PingHolder"
        value29 = (value28(value29, value30))
        value28 = value29.WaitForChild
        value30 = "Ping"
        value2 = (value28(value29, value30))
        value29 = captures.slot1
        value1 = value29.FindFirstChild
        value30 = value27.Name
        value28 = value1
        value29 = (value28(value29, value30)).Data
        value1 = value29.FindFirstChild
        value30 = "LastPing"
        value28 = value1
        value28 = value28(value29, value30)
        if value28 then
            value29 = captures.slot1
            value1 = value29.FindFirstChild
            value30 = value27.Name
            value28 = value1
            value29 = (value28(value29, value30)).Data
            value1 = value29.FindFirstChild
            value30 = "LastPing"
            value28 = value1
            value28 = value28(value29, value30)
            value5 = globals.tonumber(value2.Text)
            value28.Value = value5
            value29 = captures.slot1
            value1 = value29.FindFirstChild
            value30 = value27.Name
            value28 = value1
            value29 = (value28(value29, value30)).Data
            value1 = value29.FindFirstChild
            value30 = "LastPing"
            value28 = value1
            value1 = ((value28(value29, value30)).Value == value17)
            if value1 then
                return 15
            else
                value29 = captures.slot1
                value1 = value29.FindFirstChild
                value30 = value27.Name
                value28 = value1
                value29 = (value28(value29, value30)).Data
                value1 = value29.FindFirstChild
                value30 = "LastPing"
                value28 = value1
                value1 = (value28(value29, value30)).Value
                return value1
            end
        end
        value5 = globals.Instance.new("NumberValue")
        value2 = globals.tonumber(value2.Text)
        value5.Value = value2
        value29 = captures.slot1
        value1 = value29.FindFirstChild
        value30 = value27.Name
        value28 = value1
        value1 = (value28(value29, value30)).Data
        value5.Parent = value1
        value5.Name = "LastPing"
        value1 = value5.Value
        if (value1 == value18) then
            value1 = 15
        else
            value1 = value5.Value
        end
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.estimateReach = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, value2, value3, value4, value5, value6, value9, value11, value13

        tmp_X = {...}
        value2 = rawget(tmp_X, 1)
        if value2 then
            tmp_X = captures.slot1
            value11 = readCell(tmp_X).reachAdjust[value2]
            if (not value11) then
                value11 = 0
            end
        else
            value11 = 0
        end
        if value2 then
            value2 = captures.slot2[value2]
            value3 = (not value2)
            if value3 then
                value9 = 7.2
            else
                value3 = (value2.n < 3)
                if value3 then
                    value9 = 7.2
                else
                    value13 = {}
                    value4 = value2.n
                    value3 = 1
                    value5 = 1
                    loop = {parent = loop, index = (value3 - value5), limit = value4, step = value5}
                    while true do
                        loop.index += loop.step
                        loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                        if loopContinues then
                            value3 = loop.index
                        end
                        if loopContinues then
                            value4 = value2.samples[value3]
                            value13[value3] = value4
                            continue
                        else
                            break
                        end
                    end
                    loop = loop.parent
                    globals.table.sort(value13)
                    value6 = globals.math.clamp
                    value3 = globals.math.ceil
                    value3 = value3(((0.85) * value2.n))
                    value5 = value2.n
                    value4 = 1
                    value2 = value6
                    value2 = value2(value3, value4, value5)
                    value6 = globals.math.clamp
                    value3 = value13[value2]
                    value4 = 7.2
                    value5 = 11
                    value2 = value6
                    value9 = (value2(value3, value4, value5))
                end
            end
        else
            value9 = 7.2
        end
        value3 = globals.math.clamp
        value4 = (value9 + value11)
        value5 = 0
        value6 = 13
        return value3(table.unpack({[4] = value4, [5] = value5, [6] = value6}, 4, 6))
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1812 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value8

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value8 = (not value2.randomiseOpening)
        value2.randomiseOpening = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.toggleInterfaceVisible = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value25, value26

        tmp_X = {...}
        value25, value26 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if (not value26) then
            if (value25.KeyCode == globals.Enum.KeyCode.RightShift) then
                value2 = captures.slot1
                value4 = (not captures.slot1.Visible)
                value2.Visible = value4
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1837 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value6, value7, value8, value10, value21, value22, value23, value24, value25, value26, value27

        tmp_X = {...}
        value25, value26, value27 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value1 = captures.slot1
        value3 = true
        value1.goodWindow = value3
        tmp_X = captures.slot3
        writeCell(tmp_X, false)
        value1 = globals.Vector3.new
        value2 = 2.5
        value3 = 0
        value4 = (- 2.5)
        value1 = value1(value2, value3, value4)
        value5 = globals.Vector3.new
        value2 = value1.X
        value4 = value1.Z
        value3 = 0
        value1 = value5
        value8 = (value1(value2, value3, value4)).Unit
        value1 = globals.Vector3.new
        value2 = value25.Torso.Position.X
        value3 = captures.slot4.Torso.Position.Y
        value4 = value25.Torso.Position.Z
        value1 = value1(value2, value3, value4)
        value2 = globals.CFrame.lookAt
        value3 = captures.slot4.Torso.Position
        value4 = value1
        value2 = value2(value3, value4)
        value5 = (value1 - captures.slot4.Torso.Position).Unit
        value3 = globals.Vector3.new
        value4 = value5.X
        value6 = value5.Z
        value5 = 0
        value5 = (value3(value4, value5, value6)).Unit
        value4 = value2
        value3 = value4.VectorToObjectSpace
        value3 = value3(value4, value5)
        value6 = globals.math.atan2
        value4 = ((value8.X * value3.Z) - (value8.Z * value3.X))
        value5 = ((value8.X * value3.X) + (value8.Z * value3.Z))
        value3 = value6
        value3 = value3(value4, value5)
        value5 = captures.slot5.ON
        if value5 then
            value4 = globals.math.random()
            value5 = (((value4 * (2)) - 1) * captures.slot5.AIM)
            if (not value5) then
                value5 = 0
            end
        else
            value5 = 0
        end
        value7 = globals.CFrame.Angles
        value4 = 0
        value5 = ((- value3) + value5)
        value6 = 0
        value3 = value7
        value10 = (value2 * (value3(value4, value5, value6)))
        value3 = (captures.slot4.Torso.Position - value1)
        value1 = globals.Vector3.new
        value2 = value3.X
        value4 = value3.Z
        value3 = 0
        value4 = (value1(value2, value3, value4)).Unit
        value1 = globals.CFrame.lookAt
        value2 = captures.slot4.Torso.Position
        value3 = (captures.slot4.Torso.Position + value4)
        value1 = value1(value2, value3)
        value3 = value1
        value2 = value3.VectorToObjectSpace
        value2 = value2(value3, value4)
        value5 = globals.math.atan2
        value3 = ((value8.X * value2.Z) - (value8.Z * value2.X))
        value4 = ((value8.X * value2.X) + (value8.Z * value2.Z))
        value2 = value5
        value2 = value2(value3, value4)
        value6 = globals.CFrame.Angles
        value4 = (- value2)
        value3 = 0
        value5 = 0
        value2 = value6
        value8 = (value1 * (value2(value3, value4, value5)))
        value3 = (value25.Torso.Position - captures.slot4.Torso.Position).Magnitude
        value4 = globals.CFrame.Angles
        value1 = captures.slot5.wiggleAngle
        value2 = captures.slot6
        value1 = value1(value2, value3)
        value5 = 0
        value7 = 0
        value6 = value1
        value4 = value4(value5, value6, value7)
        if value27 then
            value1 = (value10 * value4)
            if (not value1) then
                value1 = value8
            end
        else
            if value26 then
                value1 = (value3 <= (4.5))
                if value1 then
                    value1 = (value10 * value4)
                    if (not value1) then
                        value1 = value8
                    end
                else
                    value1 = value8
                end
            else
                value1 = value8
            end
        end
        if value26 then
            value27 = value26
        end
        value22 = value25.Torso.Position
        if captures.slot5.ON then
            if (value3 > captures.slot5.ENGAGE) then
                tmp_X = captures.slot7
                value21 = readCell(tmp_X)
                value23 = true
                value24 = 5.03553390593
                value26 = true
                value21(value22, value23, value24, value25, value26, value27)
            else
                tmp_X = captures.slot7
                value21 = readCell(tmp_X)
                value24 = 5.03553390593
                value26 = true
                value23 = value1
                value21(value22, value23, value24, value25, value26, value27)
                value1 = captures.slot4.Humanoid
                value3 = false
                value1.AutoRotate = value3
            end
        else
            tmp_X = captures.slot7
            value21 = readCell(tmp_X)
            value24 = 5.03553390593
            value26 = true
            value23 = value1
            value21(value22, value23, value24, value25, value26, value27)
            value1 = captures.slot4.Humanoid
            value3 = false
            value1.AutoRotate = value3
        end
        tmp_X = captures.slot8
        value1 = readCell(tmp_X)
        value2 = true
        if (value1 == value2) then
            value1 = captures.slot4.Torso.CFrame.LookVector
            value2 = captures.slot4.Torso
            value4 = globals.CFrame.new(value25.Torso.Position)
            value2.CFrame = value4
            value2 = captures.slot4.Torso
            value24 = globals.CFrame.lookAt
            value25 = captures.slot4.Torso.Position
            value26 = (captures.slot4.Torso.Position + value1)
            value24 = value24(value25, value26)
            value2.CFrame = value24
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1838 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value5, value15, value16

        tmp_X = {...}
        value15, value16 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = value15.value
        if value16 then
            value5 = "ON"
        else
            value5 = "OFF"
        end
        value2.Text = value5
        value2 = value15.value
        if value16 then
            value16 = captures.slot2.good
            if (not value16) then
                value16 = captures.slot2.idle
            end
        else
            value16 = captures.slot2.idle
        end
        value2.TextColor3 = value16
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1845 = function(captures, globals)
    local function recovered(...)
        local R = {}
        local tmp_D, tmp_X, value25

        tmp_X = {...}
        value25 = rawget(tmp_X, 1)
        if (value25 == 1) then
            return "R"
        end
        if (value25 == (- 1)) then
            return "L"
        end
        return "\194\183"
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.firstEmptyQueueSlot = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, loopExit_5, value2, value3, value4, value18, value19, value20, value21, value22, value23

        tmp_X = {...}
        value19, value20, value21 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3)
        value2 = 1
        value3 = 4
        value4 = 1
        loop = {parent = loop, index = (value2 - value4), limit = value3, step = value4}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value22 = loop.index
            end
            if loopContinues then
                value2 = captures.slot1.slotPlayer
                value18 = captures.slot1.slotPad
                value18 = table.pack(value18(table.unpack({[19] = value19, [20] = value20, [21] = value21, [22] = value22}, 19, 22)))
                if ((value2(table.unpack(value18, 1, value18.n))) == value23) then
                    loopExit_5 = 14
                    break
                else
                    continue
                end
            else
                loopExit_5 = 11
                break
            end
        end
        if (loopExit_5 == 11) then
            loop = loop.parent
            return value23
        elseif (loopExit_5 == 14) then
        
        end
        return value22
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1856 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value6

        if (captures.slot1.UserInputState == globals.Enum.UserInputState.End) then
            value6 = false
            tmp_X = captures.slot3
            writeCell(tmp_X, value6)
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.updateWindowDrag = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value5, value6, value7, value8, value10

        tmp_X = {...}
        value10 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        tmp_X = captures.slot1
        value4 = readCell(tmp_X)
        if value2 then
            value4 = (value10.UserInputType == globals.Enum.UserInputType.MouseMovement)
            if value4 then
                value2 = value10.Position
                tmp_X = captures.slot2
                value2 = (value2 - (readCell(tmp_X)))
                value10 = captures.slot3
                value4 = globals.UDim2.new
                tmp_X = captures.slot4
                value5 = readCell(tmp_X).X.Scale
                tmp_X = captures.slot4
                value6 = (readCell(tmp_X).X.Offset + value2.X)
                tmp_X = captures.slot4
                value7 = readCell(tmp_X).Y.Scale
                tmp_X = captures.slot4
                value8 = (readCell(tmp_X).Y.Offset + value2.Y)
                value4 = value4(value5, value6, value7, value8)
                value10.Position = value4
            else
                value4 = (value10.UserInputType == globals.Enum.UserInputType.Touch)
                if value4 then
                    value2 = value10.Position
                    tmp_X = captures.slot2
                    value2 = (value2 - (readCell(tmp_X)))
                    value10 = captures.slot3
                    value4 = globals.UDim2.new
                    tmp_X = captures.slot4
                    value5 = readCell(tmp_X).X.Scale
                    tmp_X = captures.slot4
                    value6 = (readCell(tmp_X).X.Offset + value2.X)
                    tmp_X = captures.slot4
                    value7 = readCell(tmp_X).Y.Scale
                    tmp_X = captures.slot4
                    value8 = (readCell(tmp_X).Y.Offset + value2.Y)
                    value4 = value4(value5, value6, value7, value8)
                    value10.Position = value4
                end
            end
        else
            if value4 then
                value2 = value10.Position
                tmp_X = captures.slot2
                value2 = (value2 - (readCell(tmp_X)))
                value10 = captures.slot3
                value4 = globals.UDim2.new
                tmp_X = captures.slot4
                value5 = readCell(tmp_X).X.Scale
                tmp_X = captures.slot4
                value6 = (readCell(tmp_X).X.Offset + value2.X)
                tmp_X = captures.slot4
                value7 = readCell(tmp_X).Y.Scale
                tmp_X = captures.slot4
                value8 = (readCell(tmp_X).Y.Offset + value2.Y)
                value4 = value4(value5, value6, value7, value8)
                value10.Position = value4
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1877 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value5, value6, value7, value8, value10, value11, value12, value13, value14, value16

        tmp_X = {...}
        value7, value8 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value16 = {}
        value10 = globals.UDim2.new
        value11 = 1
        value12 = 0
        value13 = 0
        value14 = 18
        value10 = value10(value11, value12, value13, value14)
        value16.Size = value10
        value5 = globals.UDim2.fromOffset
        value6 = 0
        value5 = value5(value6, value7)
        value16.Position = value5
        value6 = 1
        value16.BackgroundTransparency = value6
        value6 = globals.Enum.Font.GothamBold
        value16.Font = value6
        value16.Text = value8
        value6 = captures.slot3.text
        value16.TextColor3 = value6
        value16.TextSize = 14
        value6 = globals.Enum.TextXAlignment.Left
        value16.TextXAlignment = value6
        value11 = "TextLabel"
        value13 = captures.slot4
        value10 = value2
        value12 = value16
        value10(value11, value12, value13)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.isValidOpponent = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value4, value5, value12, value14, value15, value16, value17, value18

        tmp_X = {...}
        value15 = rawget(tmp_X, 1)
        if (value15 == value12) then
            value2 = false
            return value2
        end
        if (value15.Name == captures.slot1.Name) then
            value2 = false
            return value2
        end
        value17 = globals.game.Players
        value16 = value17.FindFirstChild
        value18 = value15.Name
        value16 = value16(value17, value18)
        if (not value16) then
            value2 = false
            return value2
        end
        value17 = value16
        value16 = value17.FindFirstChild
        value18 = "Data"
        value4 = (value16(value17, value18))
        if (not value4) then
            return false
        end
        value3 = value4
        value2 = value3.FindFirstChild
        value18 = "ActiveArena"
        value16 = value2
        value17 = value3
        value5 = (value16(value17, value18))
        if (not value5) then
            return false
        end
        value17 = captures.slot1
        value2 = value17.FindFirstChild
        value18 = "Data"
        value16 = value2
        if (not ((value16(value17, value18)))) then
            return false
        end
        value17 = captures.slot1.Data
        value3 = value17.FindFirstChild
        value18 = "ActiveArena"
        value16 = value3
        if (not ((value16(value17, value18)))) then
            return false
        end
        if (value5.Value ~= captures.slot1.Data.ActiveArena.Value) then
            return false
        end
        value2 = value15.FindFirstChild
        value16 = "TeamHighlight"
        value14 = value2
        if ((value14(value15, value16))) then
            tmp_X = captures.numericBCell
            value3 = readCell(tmp_X)
            if (18063 < (value3((4908)))) then
                return false
            else
                globals.error("Recovered state check failed at cached record 1878", 0)
            end
        end
        value3 = value4.FindFirstChild
        value5 = "Slot"
        value3 = value3(value4, value5)
        if value3 then
            if (value3.Value ~= nil) then
                value17 = value3.Value
                value2 = value17.FindFirstChild
                value18 = "Pad"
                value16 = value2
                value16 = value16(value17, value18)
                if value16 then
                    value12 = value16.Color
                    value2 = globals.Color3.fromRGB
                    value3 = 255
                    value4 = 89
                    value5 = 89
                    if (value12 == (value2(value3, value4, value5))) then
                        return false
                    end
                end
            end
        else
        
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1901 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value8

        tmp_X = captures.slot1
        value2 = readCell(tmp_X)()
        value8 = captures.slot2
        value2.defaultLoseLoseStyle = value8
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.queuePadPosition = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value4, value20, value21, value22, value23

        tmp_X = {...}
        value20 = rawget(tmp_X, 1)
        if (not value20) then
            return value4
        end
        value3 = captures.slot1.posOf
        value22 = value20
        value1 = value22.FindFirstChild
        value23 = "Pad"
        value21 = value1
        value21 = table.pack(value21(table.unpack({[22] = value22, [23] = value23}, 22, 23)))
        value1 = value3(table.unpack(value21, 1, value21.n))
        if (not value1) then
            value1 = captures.slot1.posOf(value20)
        end
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1915 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value33

        tmp_X = {...}
        value33 = rawget(tmp_X, 1)
        if (not ((globals.type(value33)) ~= "number")) then
            value2 = globals.string.format
            return value2("%.2f s", value33)
        end
        return "\226\128\148"
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseWaverStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value3, value5, value6, value8, value18, value19, value20, value21

        tmp_X = {...}
        value21 = rawget(tmp_X, 1)
        value1 = captures.slot1[value21]
        value3 = (not value1)
        if value3 then
            tmp_X = captures.slot2
            value3 = readCell(tmp_X).randomiseWaver
            if value3 then
                value3 = captures.slot3
                value18 = globals.math.random
                value20 = (# captures.slot3)
                value19 = 1
                value3 = value3[(value18(value19, value20))]
            else
                tmp_X = captures.slot2
                value3 = readCell(tmp_X).defaultWaverStyle
                if (not value3) then
                    value3 = "orbit"
                end
            end
            value1 = {}
            value1.style = value3
            value5 = {}
            value6 = "orbit"
            value8 = {}
            value8.kills = 0
            value8.deaths = 0
            value5[value6] = value8
            value1.stats = value5
            captures.slot1[value21] = value1
        end
        tmp_X = captures.slot2
        value3 = readCell(tmp_X).waverStyleOverride[value21]
        if (value3 == "auto") then
            value1.locked = false
            tmp_X = captures.slot2
            value3 = readCell(tmp_X).waverStyleOverride
            value3[value21] = nil
        else
            tmp_X = captures.slot5
            if ((readCell(tmp_X)(value3))) then
                value1.style = value3
                value1.locked = true
                tmp_X = captures.slot2
                value3 = readCell(tmp_X).waverStyleOverride
                value3[value21] = nil
            end
        end
        value1 = value1.style
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1933 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value2, value3, value7, value8, value10, value11

        value2 = globals.pcall
        value3 = Functions.helper_948({}, globals)
        value2, value3 = value2(value3)
        if value2 then
            if value3 then
                return value3
            end
        end
        value7 = globals.pcall
        value8 = Functions.helper_1357({catalogCell = captures.catalogCell}, globals)
        value7, value8 = value7(value8)
        if (not value7) then
            value11 = captures.slot3
            value10 = value11.WaitForChild
            return value10(value11, "PlayerGui")
        end
        if (not value8) then
            value11 = captures.slot3
            value10 = value11.WaitForChild
            return value10(value11, "PlayerGui")
        end
        if (not (globals.pcall((Functions.helper_344({slot1 = value8}, globals))))) then
            value11 = captures.slot3
            value10 = value11.WaitForChild
            return value10(value11, "PlayerGui")
        end
        tmp_X = captures.sentinelBCell
        return value8
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1952 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, value1, value2, value3, value5, value7, value9, value10, value11, value12, value13, value14, value15, value16, value17, value18, value19, value20, value22, value23, value24, value25

        tmp_X = {...}
        value15, value16, value17, value18 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        tmp_X = captures.slot1
        value19 = (# (readCell(tmp_X)))
        if (value19 == 0) then
            return value25
        end
        tmp_X = captures.slot2
        if ((readCell(tmp_X)) == value25) then
            return value25
        end
        tmp_X = captures.slot2
        if ((# (readCell(tmp_X))) ~= value19) then
            return value25
        end
        tmp_X = captures.slot3
        value5 = readCell(tmp_X)(value15)
        tmp_X = captures.slot3
        value1 = readCell(tmp_X)(value16)
        tmp_X = captures.slot4
        if (value18 ~= (readCell(tmp_X))) then
            tmp_X = captures.slot4
            writeCell(tmp_X, value18)
            tmp_X = captures.slot5
            writeCell(tmp_X, nil)
        end
        value3 = Functions.helper_415({slot1 = value19, slot2 = captures.slot1, slot3 = captures.slot6}, globals)
        value2 = {}
        value18 = 1
        value20 = 1
        loop = {parent = loop, index = (value18 - value20), limit = value19, step = value20}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value7 = loop.index
            end
            if loopContinues then
                tmp_X = captures.slot7
                value22 = readCell(tmp_X)
                tmp_X = captures.slot1
                value24 = readCell(tmp_X)[value7]
                value23 = value1
                value22 = value22(value23, value24)
                value2[value7] = value22
                continue
            else
                break
            end
        end
        loop = loop.parent
        value22 = value3
        value23 = value1
        value24 = value2
        value2 = (value22(value23, value24))
        tmp_X = captures.slot2
        value24 = readCell(tmp_X)
        value22 = value3
        value23 = value5
        value22 = value22(value23, value24)
        value3 = (- globals.math.huge)
        value7 = (- globals.math.huge)
        value18 = 1
        value20 = 1
        value9 = nil
        value10 = nil
        loop = {parent = loop, index = (value18 - value20), limit = value19, step = value20}
        while true do
            loop.index += loop.step
            loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
            if loopContinues then
                value11 = loop.index
            end
            if loopContinues then
                value12 = (value22[value11] < globals.math.huge)
                if value12 then
                    value12 = (value2[value11] < globals.math.huge)
                    if value12 then
                        value23 = globals.math.max
                        value12 = value2[value11]
                        tmp_X = captures.slot1
                        value25 = (value12 - (readCell(tmp_X)[value11] - value1).Magnitude)
                        value24 = 0
                        value23 = value23(value24, value25)
                        tmp_X = captures.slot9
                        value13 = readCell(tmp_X)[value11]
                        if (not value13) then
                            value13 = 0
                        end
                        value12 = (1.5 * value13)
                        value13 = ((value2[value11] - (1 * value22[value11])) + (0.6 * value23))
                        value12 = (value13 + value12)
                        if (value3 < value12) then
                            value3 = value12
                            value9 = value11
                        end
                        tmp_X = captures.slot5
                        value13 = readCell(tmp_X)
                        tmp_X = captures.slot5
                        value14 = readCell(tmp_X)
                        if value13 then
                            tmp_X = captures.slot1
                            value13 = readCell(tmp_X)[value11]
                            tmp_X = captures.slot5
                            value13 = (value13 - (readCell(tmp_X))).Magnitude
                            value14 = (value13 < (3))
                        end
                        if value14 then
                            if (value12 > value7) then
                                value7 = value12
                                value10 = value11
                                continue
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        continue
                    end
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        if (not value9) then
            tmp_X = captures.slot5
            writeCell(tmp_X, nil)
            return nil
        end
        if value10 then
            if (not ((value3 - value7) <= 4)) then
                value10 = value9
            end
        else
            value10 = value9
        end
        tmp_X = captures.slot1
        value1 = readCell(tmp_X)[value10]
        tmp_X = captures.slot5
        writeCell(tmp_X, value1)
        tmp_X = captures.slot10
        value14 = readCell(tmp_X)
        tmp_X = captures.slot1
        value16 = readCell(tmp_X)[value10]
        value14, value15, value16 = value14(value15, value16)
        tmp_X = captures.slot3
        value1 = readCell(tmp_X)((value16 - value5))
        if (value1.Magnitude < 0.01) then
            return nil
        end
        value2 = value1.Unit
        value16 = value2
        value15 = value16.Dot
        value15 = value15(value16, value17)
        if (value15 < (- (0.25))) then
            return nil
        end
        return value2, value10
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1964 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value6, value27, value28, value29, value30, value31, value32, value33, value34

        tmp_X = {...}
        value29, value30 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value31 = readCell(tmp_X)
        value33 = {}
        value1 = globals.UDim2.new
        value3 = 0
        value5 = 28
        value2 = 1
        value4 = 0
        value1 = value1(value2, value3, value4, value5)
        value33.Size = value1
        value27 = globals.UDim2.fromOffset
        value28 = 0
        value27 = value27(value28, value29)
        value33.Position = value27
        value2 = captures.slot3.panel2
        value33.BackgroundColor3 = value2
        value33.BorderSizePixel = 0
        value32 = "Frame"
        value34 = captures.slot4
        value31 = value31(value32, value33, value34)
        tmp_X = captures.slot5
        value1 = readCell(tmp_X)
        value1(value31, (6))
        tmp_X = captures.slot1
        value28 = readCell(tmp_X)
        value1 = {}
        value2 = globals.UDim2.new
        value3 = 1
        value4 = (- 80)
        value5 = 1
        value6 = 0
        value2 = value2(value3, value4, value5, value6)
        value1.Size = value2
        value32 = globals.UDim2.fromOffset
        value33 = 10
        value34 = 0
        value32 = value32(value33, value34)
        value1.Position = value32
        value1.BackgroundTransparency = 1
        value3 = globals.Enum.Font.GothamMedium
        value1.Font = value3
        value1.Text = value30
        value3 = captures.slot3.subtext
        value1.TextColor3 = value3
        value3 = 12
        value1.TextSize = value3
        value3 = globals.Enum.TextXAlignment.Left
        value1.TextXAlignment = value3
        value29 = "TextLabel"
        value30 = value1
        value28(value29, value30, value31)
        tmp_X = captures.slot1
        value28 = readCell(tmp_X)
        value30 = {}
        value32 = globals.UDim2.fromOffset
        value33 = 56
        value34 = 22
        value32 = value32(value33, value34)
        value30.Size = value32
        value1 = globals.UDim2.new
        value2 = 1
        value3 = (- 64)
        value4 = 0.5
        value5 = (- 11)
        value1 = value1(value2, value3, value4, value5)
        value30.Position = value1
        value2 = captures.slot3.panel
        value30.BackgroundColor3 = value2
        value30.Text = "OFF"
        value2 = globals.Enum.Font.GothamBold
        value30.Font = value2
        value2 = captures.slot3.subtext
        value30.TextColor3 = value2
        value30.TextSize = 12
        value30.AutoButtonColor = true
        value30.BorderSizePixel = 0
        value29 = "TextButton"
        value28 = value28(value29, value30, value31)
        tmp_X = captures.slot5
        value1 = readCell(tmp_X)
        value1(value28, (6))
        return value28
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.recordOpeningDeath = function(captures, globals)
    local function recovered(...)
        local value5, value6, value7, value8

        value5 = captures.slot1.armed
        if value5 then
            value5 = captures.slot1.style
            if value5 then
                value5 = captures.slot1.targetName
                if value5 then
                    value5 = (not captures.slot1.resolved)
                    if value5 then
                        value5 = captures.slot1.recordOutcome
                        value6 = captures.slot1.targetName
                        value7 = captures.slot1.style
                        value8 = false
                        value5(value6, value7, value8)
                        captures.slot1.resolved = true
                    end
                end
            end
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1984 = function(captures, globals)
    local function recovered(...)
        local tmp_X, value5

        value5 = captures.slot1.Data.Player.Value
        tmp_X = captures.slot2
        writeCell(tmp_X, value5)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1985 = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value1, value2, value3, value5, value6, value7, value8, value9, value11, value13, value15

        tmp_X = captures.slot1
        value11 = readCell(tmp_X)()
        if value11 then
            value11 = value11.selected
        end
        value1 = globals.pairs
        value2 = captures.slot2
        value1, value2, value3 = value1(value2)
        loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value2, value3 = tmp_key, tmp_value
            end
            if loopContinues then
                tmp_X = captures.slot3
                value13 = readCell(tmp_X)(value2)
                if value13 then
                    value5 = (value2 == value11)
                    value6 = value3.card
                    if value5 then
                        value8 = captures.slot4.accent
                        if (not value8) then
                            value8 = captures.slot4.panel
                        end
                    else
                        value8 = captures.slot4.panel
                    end
                else
                    value5 = value13
                    value6 = value3.card
                    value8 = captures.slot4.panel
                end
                value6.BackgroundColor3 = value8
                value6 = value3.card
                if value13 then
                    value8 = 0
                    if (not value8) then
                        value8 = 0.4
                    end
                else
                    value8 = 0.4
                end
                value6.BackgroundTransparency = value8
                value6 = value3.card
                value6.AutoButtonColor = value13
                value6 = value3.check
                value6.Visible = value5
                value15 = value3.nameL
                if value5 then
                    value9 = globals.Color3.new
                    value6 = 1
                    value7 = 1
                    value8 = 1
                    value5 = value9
                    value5 = value5(value6, value7, value8)
                    if (not value5) then
                        if value13 then
                            value5 = captures.slot4.text
                            if (not value5) then
                                value5 = captures.slot4.idle
                            end
                        else
                            value5 = captures.slot4.idle
                        end
                    end
                else
                    if value13 then
                        value5 = captures.slot4.text
                        if (not value5) then
                            value5 = captures.slot4.idle
                        end
                    else
                        value5 = captures.slot4.idle
                    end
                end
                value15.TextColor3 = value5
                value5 = value3.note
                if value13 then
                    value13 = ""
                else
                    value13 = "not loaded"
                end
                value5.Text = value13
                continue
            else
                break
            end
        end
        loop = loop.parent
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_1995 = function(captures, globals)
    local function recovered(...)
        local R = {}
        local tmp_D, tmp_X, value2, value3, value4, value5, value6, value7, value8, value9, value10, value11, value12, value13, value18, value19, value20, value21, value22, value23, value24, value26

        tmp_X = {...}
        value26 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value3 = {}
        value3.Name = value26
        value20 = globals.UDim2.new
        value21 = 1
        value22 = (- 4)
        value23 = 0
        value24 = 94
        value20 = value20(value21, value22, value23, value24)
        value3.Size = value20
        value5 = captures.slot2.panel2
        value3.BackgroundColor3 = value5
        value3.BorderSizePixel = 0
        value22 = "Frame"
        tmp_X = captures.slot3
        value24 = readCell(tmp_X)
        value21 = value2
        value23 = value3
        value21 = value21(value22, value23, value24)
        tmp_X = captures.slot4
        value2 = readCell(tmp_X)
        value2(value21, (6))
        tmp_X = captures.slot1
        value18 = readCell(tmp_X)
        value20 = {}
        value2 = globals.UDim2.new
        value3 = 1
        value4 = (- 250)
        value5 = 0
        value6 = 22
        value2 = value2(value3, value4, value5, value6)
        value20.Size = value2
        value22 = globals.UDim2.fromOffset
        value23 = 10
        value24 = 4
        value22 = value22(value23, value24)
        value20.Position = value22
        value20.BackgroundTransparency = 1
        value3 = globals.Enum.Font.GothamBold
        value20.Font = value3
        value20.Text = value26
        value3 = captures.slot2.text
        value20.TextColor3 = value3
        value20.TextSize = 12
        value3 = globals.Enum.TextXAlignment.Left
        value20.TextXAlignment = value3
        value3 = globals.Enum.TextTruncate.AtEnd
        value20.TextTruncate = value3
        value19 = "TextLabel"
        value18 = value18(value19, value20, value21)
        tmp_X = captures.slot1
        value7 = readCell(tmp_X)
        value8 = {}
        value22 = globals.UDim2.fromOffset
        value24 = 20
        value23 = 60
        value22 = value22(value23, value24)
        value8.Size = value22
        value2 = globals.UDim2.new
        value3 = 1
        value6 = 5
        value4 = (- 238)
        value5 = 0
        value2 = value2(value3, value4, value5, value6)
        value8.Position = value2
        value8.BackgroundTransparency = 1
        value3 = globals.Enum.Font.GothamMedium
        value8.Font = value3
        value8.Text = ""
        value3 = captures.slot2.subtext
        value8.TextColor3 = value3
        value8.TextSize = 11
        value3 = globals.Enum.TextXAlignment.Left
        value8.TextXAlignment = value3
        value3 = "TextLabel"
        value2 = value7
        value4 = value8
        value5 = value21
        value2 = value2(value3, value4, value5)
        tmp_X = captures.slot1
        value8 = readCell(tmp_X)
        value9 = {}
        value22 = globals.UDim2.fromOffset
        value23 = 20
        value24 = 20
        value22 = value22(value23, value24)
        value9.Size = value22
        value3 = globals.UDim2.new
        value7 = 5
        value4 = 1
        value5 = (- 172)
        value6 = 0
        value3 = value3(value4, value5, value6, value7)
        value9.Position = value3
        value4 = captures.slot2.panel
        value9.BackgroundColor3 = value4
        value9.Text = "\226\136\146"
        value4 = globals.Enum.Font.GothamBold
        value9.Font = value4
        value4 = captures.slot2.text
        value9.TextColor3 = value4
        value4 = 14
        value9.TextSize = value4
        value9.AutoButtonColor = true
        value9.BorderSizePixel = 0
        value4 = "TextButton"
        value3 = value8
        value5 = value9
        value6 = value21
        value3 = value3(value4, value5, value6)
        tmp_X = captures.slot4
        readCell(tmp_X)(value3, 6)
        tmp_X = captures.slot1
        value9 = readCell(tmp_X)
        value10 = "TextLabel"
        value11 = {}
        value22 = globals.UDim2.fromOffset
        value23 = 122
        value24 = 20
        value22 = value22(value23, value24)
        value11.Size = value22
        value4 = globals.UDim2.new
        value6 = (- (148))
        value8 = 5
        value5 = 1
        value7 = 0
        value4 = value4(value5, value6, value7, value8)
        value11.Position = value4
        value5 = 1
        value11.BackgroundTransparency = value5
        value5 = globals.Enum.Font.GothamMedium
        value11.Font = value5
        value11.Text = "R \226\128\148"
        value5 = captures.slot2.subtext
        value11.TextColor3 = value5
        value11.TextSize = 11
        value5 = globals.Enum.TextXAlignment.Center
        value11.TextXAlignment = value5
        value4 = value9
        value5 = value10
        value6 = value11
        value7 = value21
        value4 = value4(value5, value6, value7)
        tmp_X = captures.slot1
        value10 = readCell(tmp_X)
        value11 = "TextButton"
        value12 = {}
        value22 = globals.UDim2.fromOffset
        value23 = 20
        value24 = 20
        value22 = value22(value23, value24)
        value12.Size = value22
        value5 = globals.UDim2.new
        value6 = 1
        value7 = (- (22))
        value8 = 0
        value9 = 5
        value5 = value5(value6, value7, value8, value9)
        value12.Position = value5
        value6 = captures.slot2.panel
        value12.BackgroundColor3 = value6
        value12.Text = "+"
        value6 = globals.Enum.Font.GothamBold
        value12.Font = value6
        value6 = captures.slot2.text
        value12.TextColor3 = value6
        value12.TextSize = 14
        value12.AutoButtonColor = true
        value12.BorderSizePixel = 0
        value5 = value10
        value6 = value11
        value7 = value12
        value8 = value21
        value5 = value5(value6, value7, value8)
        tmp_X = captures.slot4
        readCell(tmp_X)(value5, 6)
        value24 = value3.MouseButton1Click
        lifecycle.connect(value24, (Functions.helper_1477({slot1 = captures.slot6, slot2 = value26, catalogCell = captures.catalogCell}, globals)))
        value24 = value5.MouseButton1Click
        lifecycle.connect(value24, (Functions.helper_242({slot1 = captures.slot6, slot2 = value26, catalogCell = captures.catalogCell}, globals)))
        value3 = Functions.helper_623({slot1 = captures.slot1, catalogCell = captures.catalogCell, slot3 = captures.slot2, slot4 = value21, slot5 = captures.slot4}, globals)
        value24 = 28
        value23 = value3
        value23, value24 = value23(value24)
        value6 = 50
        value5 = value3
        value5, value6 = value5(value6)
        value8 = 72
        value7 = value3
        value7, value8 = value7(value8)
        value9 = Functions.helper_2138({slot1 = captures.slot7, slot2 = value26, slot3 = captures.slot6}, globals)
        value12 = "aggroRaw"
        value11 = captures.slot8
        value13 = "aggroStyleOverride"
        value10 = value23
        value9(value10, value11, value12, value13)
        value12 = "loseLoseRaw"
        value11 = captures.slot9
        value13 = "loseLoseStyleOverride"
        value10 = value5
        value9(value10, value11, value12, value13)
        value11 = captures.slot10
        value12 = "openingRaw"
        value13 = "openingStyleOverride"
        value10 = value7
        value9(value10, value11, value12, value13)
        value3 = captures.slot11
        value9 = {}
        value9.frame = value21
        value9.name = value18
        value9.wl = value2
        value9.reach = value4
        value9.agStyle = value23
        value9.agStat = value24
        value9.llStyle = value5
        value9.llStat = value6
        value9.opStyle = value7
        value9.opStat = value8
        value3[value26] = value9
        value2 = captures.slot11[value26]
        return value2
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.createKevinEngine = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local tmp_Y, value1, value2, value3, value4, value7, value8, value9, value12, value13, value15, value18, value19, value20, value21, value41, value46, value47, value48, value51, value60, value61, value65, value68, value70, value71, value72, value73, value74, value79, value83, value84, value85, value89, value90, value92, value93, value97, value112, value113, value114, value120, value122, value124, value125, value126, value127, value128, value129, value130, value131, value132, value134, value142, value147, value151, value158, value160, value163, value165, value179, value186, value188, value195, value196, value197

        value1 = globals.game.Players.LocalPlayer.Name
        if (value1 ~= "tgodjk") then
            value2 = globals.game
            value4 = value2.GetService
            value3 = "RunService"
            value1 = value4
            value1 = value1(value2, value3)
            value3 = globals.game
            value2 = value3.GetService
            R[5] = value2
            value4 = "UserInputService"
            value2 = R[5]
            value2 = value2(value3, value4)
            value4 = globals.game
            value3 = value4.GetService
            R[6] = value3
            R[5] = "Players"
            value3 = R[6]
            value3 = value3(value4, R[5])
            R[5] = globals.game
            value7 = R[5].GetService
            R[6] = "Debris"
            value4 = value7
            value4 = value4(R[5], R[6])
            R[5] = globals.game
            R[5] = R[5].Workspace
            value15 = R[5].Characters
            R[16] = nil
            R[5] = globals.getgenv
            if R[5] then
                R[6] = globals.getgenv
                R[5] = R[6]()
                if (not R[5]) then
                    R[5] = globals._G
                end
            else
                R[5] = globals._G
            end
            R[16] = R[5].FANAKA
            R[6] = globals.type
            R[6] = R[6](R[16])
            R[6] = (R[6] ~= "table")
            if R[6] then
                R[16] = {}
                R[5].FANAKA = R[16]
            end
            R[5] = globals.type
            R[6] = R[16].brains
            R[5] = R[5](R[6])
            R[5] = (R[5] ~= "table")
            if R[5] then
                value7 = {}
                R[16].brains = value7
            end
            R[5] = {}
            R[5].name = "Kevin"
            value7 = 1485
            R[5].elo = value7
            R[5].desc = "The most humanlike and realistic engine yet. Plays like someone with thousands of wins."
            R[6] = globals.type
            value7 = R[16].register
            R[6] = R[6](value7)
            R[6] = (R[6] == "function")
            if R[6] then
                R[16].register("kevin", R[5])
            else
                R[6] = R[16].brains
                R[6].kevin = R[5]
                R[5] = R[16].selected
                if (R[5] == nil) then
                    R[16].selected = "kevin"
                end
            end
            R[17] = nil
            R[5] = globals.Instance
            R[5] = R[5].new
            value18 = R[5]("Part")
            R[5] = globals.Vector3
            R[5] = R[5].new
            R[6] = 0.5
            value7 = 9999
            value8 = 0.5
            R[5] = R[5](R[6], value7, value8)
            value18.Size = R[5]
            value18.Anchored = true
            R[5] = globals.Color3
            R[5] = R[5].fromRGB
            R[6] = 0
            value7 = 0
            value8 = 255
            R[5] = R[5](R[6], value7, value8)
            value18.Color = R[5]
            R[6] = globals.game
            R[6] = R[6].Workspace
            value18.Parent = R[6]
            value18.CanCollide = false
            R[5] = globals.Instance
            R[5] = R[5].new
            R[6] = "Part"
            value19 = R[5](R[6])
            R[5] = globals.Vector3
            R[5] = R[5].new
            R[6] = 0.5
            value7 = 9999
            value8 = 0.5
            R[5] = R[5](R[6], value7, value8)
            value19.Size = R[5]
            R[6] = true
            value19.Anchored = R[6]
            R[5] = globals.Color3
            R[5] = R[5].fromRGB
            R[6] = 0
            value7 = 255
            value8 = 0
            R[5] = R[5](R[6], value7, value8)
            value19.Color = R[5]
            R[6] = globals.game
            R[6] = R[6].Workspace
            value19.Parent = R[6]
            value19.CanCollide = false
            R[5] = globals.Instance
            R[5] = R[5].new
            R[6] = "Part"
            value20 = R[5](R[6])
            R[5] = globals.Vector3
            R[5] = R[5].new
            R[6] = 0.5
            value8 = 0.5
            value7 = 9999
            R[5] = R[5](R[6], value7, value8)
            value20.Size = R[5]
            value20.Anchored = true
            R[5] = globals.Color3
            R[5] = R[5].fromRGB
            value7 = 0
            R[6] = 255
            value8 = 0
            R[5] = R[5](R[6], value7, value8)
            value20.Color = R[5]
            R[6] = globals.game
            R[6] = R[6].Workspace
            value20.Parent = R[6]
            value20.CanCollide = false
            value21 = value3.LocalPlayer
            R[22] = false
            R[23] = 0
            R[24] = 0
            R[25] = nil
            R[26] = nil
            R[5] = globals.Vector3
            R[5] = R[5].new
            R[6] = 0
            value7 = 0
            value8 = 0
            R[5] = R[5](R[6], value7, value8)
            R[27] = 0
            R[28] = 0
            R[29] = nil
            R[30] = nil
            R[6] = globals.Vector3
            R[6] = R[6].new
            value9 = 0
            value7 = 0
            value8 = 0
            R[6] = R[6](value7, value8, value9)
            R[31] = nil
            R[32] = nil
            R[33] = false
            R[34] = false
            R[35] = nil
            R[36] = false
            R[37] = nil
            R[38] = nil
            R[39] = false
            R[40] = nil
            value7 = {}
            value8 = "orbit"
            tmp_Y = value7
            table.move({[8] = value8}, 8, 8, 1, tmp_Y)
            value41 = {}
            R[42] = "orbit"
            R[43] = nil
            R[44] = false
            R[45] = false
            value8 = {}
            value9 = "grab"
            R[10] = "run"
            tmp_Y = value8
            table.move({[9] = value9, [10] = R[10]}, 9, 10, 1, tmp_Y)
            value46 = {}
            value47 = {}
            R[10] = true
            value47.USE = R[10]
            R[10] = 2.5
            value47.MAX_TIME = R[10]
            value47.DURATION = 0.5
            value47.REACH = 2.2360679775
            value47.AWAY_SPEED = 2
            value47.CANCEL_SPEED = 1
            R[10] = false
            value47.engaged = R[10]
            value47.victimChar = nil
            value47.victimName = nil
            value47.style = nil
            value47.resolved = false
            value47.phase = nil
            value47.baitUntil = 0
            value47.baitVictim = nil
            value9 = {}
            R[10] = "aggressive"
            R[11] = "patient"
            tmp_Y = value9
            table.move({[10] = R[10], [11] = R[11]}, 10, 11, 1, tmp_Y)
            value48 = {}
            R[49] = "aggressive"
            R[50] = nil
            value51 = {}
            value51.CORNER = "corner"
            value51.CHARGE = "charge"
            value51.USE = true
            R[11] = 3.5
            value51.DURATION = R[11]
            value51.MOVE_TIME = 1.35
            R[11] = 40
            value51.SIDE_STEP = R[11]
            value51.WALL_BUFFER = 2
            value51.PROBE = 12
            value51.ESCAPE = 6
            value51.armed = false
            value51.roundStart = 0
            value51.style = nil
            value51.targetName = nil
            value51.cornerTarget = nil
            value51.moveStart = nil
            R[11] = true
            value51.resolved = R[11]
            value51.prevChar = nil
            R[11] = {}
            value51.players = R[11]
            R[10] = {}
            R[11] = value51.CORNER
            value12 = value51.CHARGE
            tmp_Y = R[10]
            table.move({[11] = R[11], [12] = value12}, 11, 12, 1, tmp_Y)
            value51.STYLE_LIST = R[10]
            R[11] = Functions.recordOpeningDeath({slot1 = value51, catalogCell = captures.catalogCell}, globals)
            value51.markDeath = R[11]
            R[11] = Functions.watchOpeningDeaths({slot1 = value51, sentinelACell = captures.sentinelACell}, globals)
            value51.hookDeath = R[11]
            R[11] = value21.CharacterAdded
            R[10] = lifecycle.connect
            value12 = value51.hookDeath
            R[10](R[11], value12)
            R[10] = value21.Character
            if R[10] then
                R[10] = value51.hookDeath
                R[11] = value21.Character
                R[10](R[11])
            end
            R[52] = nil
            R[53] = nil
            R[10] = globals.Vector3
            R[10] = R[10].new
            value13 = 0
            R[11] = 0
            value12 = 0
            R[10] = R[10](R[11], value12, value13)
            R[54] = nil
            R[55] = nil
            R[56] = nil
            R[57] = {}
            R[58] = false
            R[59] = nil
            value60 = {}
            value61 = {}
            R[62] = false
            R[11] = globals.math
            R[11] = R[11].random
            R[11](65, 90)
            R[11] = globals.math
            R[11] = R[11].random
            value12 = 40
            R[11](35, value12)
            R[63] = false
            R[64] = false
            R[11] = globals.tick
            value65 = R[11]()
            R[66] = nil
            R[67] = nil
            R[11] = globals.Vector3
            R[11] = R[11].new
            value12 = 0
            value13 = 0
            R[14] = 0
            R[11] = R[11](value12, value13, R[14])
            R[14] = 1
            value68 = {}
            value68.mode = "idle"
            value68.bombTime = 0
            value68.nearestDist = 0
            value68.tagTime = 0
            value68.contactBombTime = 0
            value68.goodWindow = false
            value70 = 0
            value68.secondDist = value70
            value71 = false
            value68.secondHasBomb = value71
            value68.victimReach = 0
            value68.victimReachN = 0
            value68.navMode = "-"
            value68.navCommitted = 0
            value68.navNew = 0
            value68.navCostR = 0
            value72 = 0
            value68.navCostL = value72
            value73 = false
            value68.navEdgeR = value73
            value68.navEdgeL = false
            value68.vizGraph = false
            value68.vizRays = false
            value68.vizBeams = true
            value68.waverStyle = "-"
            value68.waverMode = "-"
            value68.aggroStyle = "-"
            value68.aggroRaw = nil
            value68.waverStylesRaw = nil
            value68.loseLoseStyle = "-"
            value68.loseLoseRaw = nil
            value68.openingStyle = "-"
            value68.openingRaw = nil
            value12 = globals.getgenv
            if value12 then
                value12 = globals.getgenv()
                if (not value12) then
                    value12 = globals._G
                end
            else
                value12 = globals._G
            end
            value73 = value12
            value73.FANAKA_DEBUG = value68
            value68.waverStylesRaw = value41
            value68.reachTableRaw = value61
            value68.loseLoseRaw = value46
            value68.aggroRaw = value48
            value74 = value51.players
            value68.openingRaw = value74
            value74 = {}
            R[75] = {}
            value74.players = R[75]
            value74.opponent = nil
            value74.resolved = false
            value74.prevChar = nil
            R[75] = Functions.ensureOpponentStats({slot1 = value74, catalogCell = captures.catalogCell}, globals)
            value74.ensure = R[75]
            R[75] = value74.players
            value68.winLossRaw = R[75]
            value68.autoQueueState = "-"
            R[75] = value73.FANAKA_CONFIG
            if ((globals.type(R[75])) ~= "table") then
                R[75] = {}
            end
            if (R[75].randomiseWaver == nil) then
                R[77] = false
                R[75].randomiseWaver = R[77]
            end
            R[77] = nil
            R[77] = Functions.helper_2066({}, globals)
            value12 = R[75].defaultWaverStyle
            if (not (R[77](value12))) then
                R[75].defaultWaverStyle = "orbit"
            end
            if ((globals.type(R[75].waverStyleOverride)) ~= "table") then
                value79 = {}
                R[75].waverStyleOverride = value79
            end
            R[75].styleList = value7
            if (R[75].randomiseLoseLose == nil) then
                R[75].randomiseLoseLose = true
            end
            value12 = R[75].defaultLoseLoseStyle
            if (value12 ~= "grab") then
                if (R[75].defaultLoseLoseStyle ~= "run") then
                    value83 = "run"
                    R[75].defaultLoseLoseStyle = value83
                end
            end
            if ((globals.type(R[75].loseLoseStyleOverride)) ~= "table") then
                value84 = {}
                R[75].loseLoseStyleOverride = value84
            end
            R[75].loseLoseStyleList = value8
            if ((globals.type(R[75].reachAdjust)) ~= "table") then
                value85 = {}
                R[75].reachAdjust = value85
            end
            if (R[75].randomiseAggro == nil) then
                R[75].randomiseAggro = false
            end
            if (R[75].defaultAggroStyle ~= "aggressive") then
                if (R[75].defaultAggroStyle ~= "patient") then
                    value89 = "aggressive"
                    R[75].defaultAggroStyle = value89
                end
            end
            if ((globals.type(R[75].aggroStyleOverride)) ~= "table") then
                value90 = {}
                R[75].aggroStyleOverride = value90
            end
            R[75].aggroStyleList = value9
            if (R[75].randomiseOpening == nil) then
                R[75].randomiseOpening = true
            end
            if (R[75].defaultOpeningStyle ~= value51.CORNER) then
                if (R[75].defaultOpeningStyle ~= value51.CHARGE) then
                    value92 = value51.CORNER
                    R[75].defaultOpeningStyle = value92
                end
            end
            if ((globals.type(R[75].openingStyleOverride)) ~= "table") then
                value93 = {}
                R[75].openingStyleOverride = value93
            end
            value93 = value51.STYLE_LIST
            R[75].openingStyleList = value93
            if (R[75].autoQueue == nil) then
                R[75].autoQueue = false
            end
            if (R[75].autoQueueFind == nil) then
                R[75].autoQueueFind = true
            end
            if (R[75].autoQueueArena ~= "2") then
                if (R[75].autoQueueArena ~= "4") then
                    if (R[75].autoQueueArena ~= "6") then
                        value97 = R[75].autoQueueArena
                        if (value97 ~= "none") then
                            R[75].autoQueueArena = "none"
                        end
                    end
                end
            end
            if (R[75].autoQueueSide ~= "either") then
                if (R[75].autoQueueSide ~= "left") then
                    if (R[75].autoQueueSide ~= "right") then
                        R[75].autoQueueSide = "either"
                    end
                end
            end
            value73.FANAKA_CONFIG = R[75]
            R[101] = nil
            R[101] = Functions.chooseWaverStyle({slot1 = value41, slot2 = captureShared(cells, R, 75), slot3 = value7, catalogCell = captures.catalogCell, slot5 = captureShared(cells, R, 77)}, globals)
            R[102] = nil
            R[102] = Functions.chooseStyle({}, globals)
            R[103] = nil
            R[103] = Functions.recordKill({slot1 = value41}, globals)
            R[104] = nil
            R[104] = Functions.helper_146({catalogCell = captures.catalogCell}, globals)
            R[105] = nil
            R[105] = Functions.helper_2216({slot1 = value41, catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 104), slot4 = value7, slot5 = captureShared(cells, R, 102)}, globals)
            R[106] = nil
            R[106] = Functions.chooseAggressionStyle({slot1 = value48, slot2 = captureShared(cells, R, 75), slot3 = value9, catalogCell = captures.catalogCell}, globals)
            R[107] = nil
            R[107] = Functions.deathRatioForAggression({}, globals)
            R[108] = nil
            R[108] = Functions.helper_2061({slot1 = value48, slot2 = captureShared(cells, R, 104), slot3 = value9, slot4 = captureShared(cells, R, 107)}, globals)
            R[109] = nil
            R[109] = Functions.chooseEncounterStyle({slot1 = value46, slot2 = captureShared(cells, R, 75), slot3 = value8, catalogCell = captures.catalogCell, authAliveCell = captures.authAliveCell}, globals)
            R[110] = nil
            R[110] = Functions.helper_142({}, globals)
            R[111] = nil
            R[111] = Functions.helper_1645({slot1 = value46, catalogCell = captures.catalogCell, sentinelBCell = captures.sentinelBCell, slot4 = captureShared(cells, R, 104), slot5 = value8, slot6 = captureShared(cells, R, 110)}, globals)
            value112 = Functions.helper_1508({slot1 = value47, slot2 = captureShared(cells, R, 111)}, globals)
            value47.markDeath = value112
            value112 = Functions.watchEncounterDeaths({catalogCell = captures.catalogCell, slot2 = value47}, globals)
            value47.hookDeath = value112
            value13 = value21.CharacterAdded
            lifecycle.connect(value13, value47.hookDeath)
            if value21.Character then
                value47.hookDeath(value21.Character)
            end
            value112 = Functions.helper_1587({slot1 = value51, slot2 = captureShared(cells, R, 75), catalogCell = captures.catalogCell, authAliveCell = captures.authAliveCell}, globals)
            value51.ensureStyle = value112
            value112 = Functions.deathRatio({}, globals)
            value51.deathRatio = value112
            value112 = Functions.helper_1757({slot1 = value51, catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 104)}, globals)
            value51.recordOutcome = value112
            value13 = value2.InputBegan
            value12 = lifecycle.connect
            value112 = Functions.handleKevinKeyDown({catalogCell = captures.catalogCell, enabledCell = captureShared(cells, R, 63), teleportHeldCell = captureShared(cells, R, 64)}, globals)
            value12(value13, value112)
            value13 = value2.InputEnded
            lifecycle.connect(value13, (Functions.handleKevinKeyUp({teleportHeldCell = captureShared(cells, R, 64), enabledCell = captureShared(cells, R, 63)}, globals)))
            value112 = false
            value113 = false
            value114 = false
            value120 = 1
            value122 = 1
            value18.Transparency = 1
            value19.Transparency = value120
            value20.Transparency = value122
            value122 = {}
            value122.wallSlack = 1
            value124 = 10
            value122.sweepStep = value124
            value125 = 9
            value122.sweepMax = value125
            value122.orbitSpeed = 6
            value126 = 1.5
            value122.orbitRate = value126
            value127 = 12
            value122.orbitCorrect = value127
            value122.chaseSmooth = 0.15
            value128 = 4
            value122.chaseEnter = value128
            value129 = 1
            value122.chaseExit = value129
            value122.chaseBand = 0.3
            value130 = true
            value122.chargeAtVictim = value130
            value130 = {}
            value130.AWARE = true
            value130.BODY_R = 2
            value130.MARGIN = 1
            value131 = {}
            value132 = {}
            value134 = {}
            value134.level = 0.9
            value134.react = 0.28
            value134.timing = 0.42
            value134.waver = 2.2
            value142 = 0.3839724354387525
            value134.aim = value142
            value134.turn = 12.217304763960307
            value134.engage = 4.5
            value134.distBias = 0.1
            value147 = 0.3
            value134.pathErr = value147
            value134.sideOn = 4
            value134.wiggleDeg = 30
            value151 = 5
            value134.wiggleMargin = value151
            value134.wigglePeriod = 0.85
            value134.wiggleStart = 2.5
            value134.slideErr = 0.06981317007977318
            value134.waverOut = 5
            value134.waverFace = 13
            value134.waverSmooth = 0.2
            value134.antiJitter = 1
            value132.kevin = value134
            value131.PROFILES = value132
            value158 = Functions.applyKevinProfile({slot1 = value131, catalogCell = captures.catalogCell, slot3 = value68}, globals)
            value131.apply = value158
            value158 = Functions.wiggleAngle({slot1 = value131, catalogCell = captures.catalogCell}, globals)
            value131.wiggleAngle = value158
            value131.apply("kevin")
            value158 = globals.RaycastParams.new()
            value160 = globals.Enum.RaycastFilterType
            R[161] = value160.Include
            value158.FilterType = R[161]
            value158.IgnoreWater = true
            R[161] = {}
            value163 = globals.OverlapParams.new()
            value165 = globals.Enum.RaycastFilterType
            R[166] = value165.Include
            value163.FilterType = R[166]
            R[166] = nil
            R[166] = Functions.refreshCollisionFilters({slot1 = value158, slot2 = value163, slot3 = captureShared(cells, R, 161)}, globals)
            R[166]()
            value12 = globals.tick
            R[167] = value12()
            R[168] = nil
            R[168] = Functions.horizontalVector({catalogCell = captures.catalogCell}, globals)
            R[169] = nil
            R[169] = Functions.recordReachSample({catalogCell = captures.catalogCell, slot2 = value61}, globals)
            R[170] = nil
            R[170] = Functions.estimateReach({slot1 = captureShared(cells, R, 75), slot2 = value61, catalogCell = captures.catalogCell}, globals)
            R[171] = nil
            R[171] = Functions.isValidOpponent({slot1 = value21, catalogCell = captures.catalogCell, numericBCell = captures.numericBCell}, globals)
            R[172] = nil
            R[172] = Functions.drawDebugLine({catalogCell = captures.catalogCell, slot2 = value4}, globals)
            R[173] = nil
            R[173] = Functions.castMovementProbe({catalogCell = captures.catalogCell, raycastParams = value158}, globals)
            R[174] = {}
            R[175] = {}
            R[176] = 0
            R[177] = 0
            R[178] = false
            value179 = {}
            value179.lastPos = nil
            value179.pending = false
            value179.jumpAt = 0
            value179.settlePos = nil
            value179.settleSince = 0
            value179.JUMP = 40
            value179.MINWAIT = 0.15
            value179.EPS = 3
            value179.WIN = 0.25
            if value21 then
                value13 = value21.CharacterAdded
                value12 = lifecycle.connect
                R[180] = Functions.handleRespawnDelay({slot1 = captureShared(cells, R, 178)}, globals)
                value12(value13, R[180])
            end
            R[180] = nil
            R[181] = nil
            R[182] = {}
            R[183] = {}
            R[184] = nil
            value186 = globals.RaycastParams.new()
            value188 = globals.Enum.RaycastFilterType
            R[189] = value188.Include
            value186.FilterType = R[189]
            value186.IgnoreWater = true
            R[189] = {}
            R[190] = nil
            R[190] = Functions.helper_758({slot1 = captureShared(cells, R, 168), catalogCell = captures.catalogCell}, globals)
            R[191] = nil
            R[191] = Functions.helper_737({slot1 = captureShared(cells, R, 176), catalogCell = captures.catalogCell, slot3 = value186}, globals)
            R[192] = nil
            R[192] = Functions.helper_1624({slot1 = captureShared(cells, R, 184), slot2 = value112, catalogCell = captures.catalogCell, slot4 = captureShared(cells, R, 176), slot5 = captureShared(cells, R, 174), slot6 = captureShared(cells, R, 175), slot7 = captureShared(cells, R, 182)}, globals)
            R[193] = nil
            R[193] = Functions.buildNavigationGraph({slot1 = captureShared(cells, R, 176), slot2 = captureShared(cells, R, 174), slot3 = captureShared(cells, R, 182), slot4 = captureShared(cells, R, 168), slot5 = captureShared(cells, R, 161), catalogCell = captures.catalogCell, slot7 = captureShared(cells, R, 190), slot8 = value163, slot9 = value186, slot10 = captureShared(cells, R, 175), slot11 = captureShared(cells, R, 191), slot12 = captureShared(cells, R, 183), slot13 = captureShared(cells, R, 173), slot14 = value51, slot15 = captureShared(cells, R, 177), slot16 = captureShared(cells, R, 192)}, globals)
            R[194] = nil
            R[194] = Functions.refreshNavigation({slot1 = captureShared(cells, R, 177), slot2 = captureShared(cells, R, 178), slot3 = captureShared(cells, R, 193), slot4 = captureShared(cells, R, 168), slot5 = captureShared(cells, R, 180), slot6 = captureShared(cells, R, 181), slot7 = captureShared(cells, R, 174), slot8 = captureShared(cells, R, 191), slot9 = captureShared(cells, R, 189)}, globals)
            value195 = Functions.helper_2320({slot1 = captureShared(cells, R, 168), slot2 = captureShared(cells, R, 173), slot3 = value51, catalogCell = captures.catalogCell}, globals)
            value51.pickCorner = value195
            value2 = {}
            value2.state = "start"
            value2.arena = nil
            value2.side = nil
            value2.slot = nil
            value2.slotStart = 0
            value2.wiggleStart = 0
            value2.attempts = 0
            value2.wasInGame = false
            value2.pendingBake = false
            value2.bakeEnter = 0
            value2.bakeEntryPos = nil
            value2.bakeLastPos = nil
            value2.bakeStableSince = 0
            value2.BAKE_MIN_WAIT = 0.4
            value2.BAKE_STABLE_EPS = 3
            value196 = 0.25
            value2.BAKE_STABLE_WIN = value196
            value2.BAKE_MOVE_MIN = 20
            value2.BAKE_MAX_WAIT = 3
            value2.READY_WAIT = 1
            value2.WIGGLE = 0.4
            value2.MAX_TRY = 3
            value2.lastReady = 0
            value197 = 0.75
            value2.READY_REFIRE = value197
            R[198] = 0
            value2.lastCheck = R[198]
            value2.CHECK_EVERY = 1
            value2.CHECK_DIST = 28
            R[198] = Functions.resetAutoQueue({slot1 = value2}, globals)
            value2.reset = R[198]
            R[198] = Functions.objectPosition({catalogCell = captures.catalogCell}, globals)
            value2.posOf = R[198]
            R[198] = Functions.queuePadPosition({slot1 = value2}, globals)
            value2.padPos = R[198]
            R[198] = Functions.findQueuePad({catalogCell = captures.catalogCell}, globals)
            value2.slotPad = R[198]
            R[198] = Functions.queuePadOccupant({}, globals)
            value2.slotPlayer = R[198]
            R[198] = Functions.playerActiveArena({}, globals)
            value2.playerActiveArena = R[198]
            R[198] = Functions.queueArenaInProgress({catalogCell = captures.catalogCell, slot2 = value2}, globals)
            value2.inProgress = R[198]
            R[198] = Functions.someoneQueuing({slot1 = value2}, globals)
            value2.someoneQueuing = R[198]
            R[198] = Functions.countQueueSide({catalogCell = captures.catalogCell, slot2 = value2}, globals)
            value2.sideCount = R[198]
            R[198] = Functions.firstEmptyQueueSlot({slot1 = value2}, globals)
            value2.emptySlot = R[198]
            R[198] = Functions.chooseQueueArena({slot1 = captureShared(cells, R, 75), catalogCell = captures.catalogCell, slot3 = value2}, globals)
            value2.chooseArena = R[198]
            R[198] = Functions.chooseQueueSideAndSlot({slot1 = captureShared(cells, R, 75), catalogCell = captures.catalogCell, slot3 = value2}, globals)
            value2.chooseSlot = R[198]
            R[198] = Functions.queueSelectionValid({slot1 = value2, slot2 = value21}, globals)
            value2.sane = R[198]
            R[198] = Functions.updateAutoQueue({localPlayer = value21, queueState = value2, debugState = value68, catalogCell = captures.catalogCell, sentinelBCell = captures.sentinelBCell, authReadyCell = captures.authReadyCell}, globals)
            value2.run = R[198]
            R[198] = nil
            R[198] = Functions.helper_306({slot1 = captureShared(cells, R, 168), slot2 = captureShared(cells, R, 191), slot3 = captureShared(cells, R, 174), slot4 = captureShared(cells, R, 181), slot5 = captureShared(cells, R, 180), catalogCell = captures.catalogCell, slot7 = captureShared(cells, R, 175)}, globals)
            R[199] = nil
            R[199] = Functions.helper_299({slot1 = captureShared(cells, R, 168), catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 189), slot4 = captureShared(cells, R, 198)}, globals)
            R[200] = nil
            R[200] = Functions.helper_1440({slot1 = captureShared(cells, R, 199)}, globals)
            R[201] = nil
            R[201] = Functions.helper_468({slot1 = captureShared(cells, R, 200), catalogCell = captures.catalogCell, slot3 = value122}, globals)
            R[202] = nil
            R[202] = Functions.helper_904({catalogCell = captures.catalogCell, slot2 = captureShared(cells, R, 201), slot3 = value122}, globals)
            R[203] = nil
            R[203] = Functions.helper_1952({slot1 = captureShared(cells, R, 174), slot2 = captureShared(cells, R, 181), slot3 = captureShared(cells, R, 168), slot4 = captureShared(cells, R, 38), slot5 = captureShared(cells, R, 37), slot6 = captureShared(cells, R, 175), slot7 = captureShared(cells, R, 191), catalogCell = captures.catalogCell, slot9 = captureShared(cells, R, 183), slot10 = captureShared(cells, R, 199)}, globals)
            R[204] = nil
            R[204] = Functions.helper_478({slot1 = captureShared(cells, R, 31), slot2 = captureShared(cells, R, 32), catalogCell = captures.catalogCell, slot4 = captureShared(cells, R, 33), slot5 = captureShared(cells, R, 34), slot6 = captureShared(cells, R, 35), slot7 = captureShared(cells, R, 36)}, globals)
            R[205] = nil
            R[205] = Functions.helper_1111({slot1 = captureShared(cells, R, 52), slot2 = captureShared(cells, R, 53), sentinelBCell = captures.sentinelBCell}, globals)
            R[206] = nil
            R[206] = Functions.helper_280({slot1 = captureShared(cells, R, 56), catalogCell = captures.catalogCell, slot3 = captureShared(cells, R, 10), slot4 = captureShared(cells, R, 54), slot5 = captureShared(cells, R, 168), slot6 = captureShared(cells, R, 55), slot7 = value21, slot8 = value131}, globals)
            R[207] = nil
            R[207] = Functions.navigateKevin({directionMarker = value19, localPlayer = value21, catalogCell = captures.catalogCell, sentinelACell = captures.sentinelACell, targetMarker = value18, horizontalVectorCell = captureShared(cells, R, 168), raycastParams = value158, lastCharacterCell = captureShared(cells, R, 26), numericCCell = captures.numericCCell, velocityCell = captureShared(cells, R, 6), lastPositionCell = captureShared(cells, R, 29), lastPositionAtCell = captureShared(cells, R, 30), castProbeCell = captureShared(cells, R, 173), blockedUntilCell = captureShared(cells, R, 28), wallContactSinceCell = captureShared(cells, R, 27), debugState = value68, committedAtCell = captureShared(cells, R, 24), committedPositionCell = captureShared(cells, R, 25), steerDirectionCell = captureShared(cells, R, 5), destinationMarker = value20, findPathCell = captureShared(cells, R, 199), showRays = value113, drawRayCell = captureShared(cells, R, 172), humanization = value131, steeringModeCell = captureShared(cells, R, 17)}, globals)
            value13 = value1.Heartbeat
            value12 = lifecycle.connectEngine
            value1 = Functions.updateKevin({registryCell = captureShared(cells, R, 16), sharedEnvironment = value73, debugState = value68, humanization = value131, showGraph = value112, showRays = value113, showBeams = value114, filterRefreshAtCell = captureShared(cells, R, 167), sentinelACell = captures.sentinelACell, catalogCell = captures.catalogCell, refreshFiltersCell = captureShared(cells, R, 166), localPlayer = value21, opening = value51, encounter = value47, opponentStats = value74, queueState = value2, settingsCell = captureShared(cells, R, 75), numericCCell = captures.numericCCell, authAliveCell = captures.authAliveCell, respawnPendingCell = captureShared(cells, R, 178), teleportHeldCell = captureShared(cells, R, 64), respawnState = value179, numericBCell = captures.numericBCell, refreshNavigationCell = captureShared(cells, R, 194), characters = value15, isValidOpponentCell = captureShared(cells, R, 171), playersService = value3, jumpPendingCell = captureShared(cells, R, 58), trackedJumpTargetsCell = captureShared(cells, R, 57), hadTargetCell = captureShared(cells, R, 45), hadBombCell = captureShared(cells, R, 44), recordKillCell = captureShared(cells, R, 103), previousTargetNameCell = captureShared(cells, R, 43), recordWaverOutcomeCell = captureShared(cells, R, 105), previousAggressionTargetCell = captureShared(cells, R, 50), recordAggressionOutcomeCell = captureShared(cells, R, 108), waverState = value60, previousBombCell = captureShared(cells, R, 59), sentinelBCell = captures.sentinelBCell, recordReachCell = captureShared(cells, R, 169), horizontalVectorCell = captureShared(cells, R, 168), recordEncounterOutcomeCell = captureShared(cells, R, 111), localHasBombCell = captureShared(cells, R, 22), bombHoldDelayCell = captureShared(cells, R, 23), enabledCell = captureShared(cells, R, 63), startTime = value65, navigateCell = captureShared(cells, R, 207), chasingCell = captureShared(cells, R, 36), chaseTargetCell = captureShared(cells, R, 35), orbitSettings = value122, waveringCell = captureShared(cells, R, 34), chaseCell = captureShared(cells, R, 200), fleeingCell = captureShared(cells, R, 33), fleeCell = captureShared(cells, R, 202), roundActiveCell = captureShared(cells, R, 62), lastTargetPositionCell = captureShared(cells, R, 66), lastTargetVelocityCell = captureShared(cells, R, 67), smoothedMoveCell = captureShared(cells, R, 11), lastMoveAtCell = captureShared(cells, R, 14), avoidanceSettings = value130, raycastParams = value158, pathfindCell = captureShared(cells, R, 203), hadContactCell = captureShared(cells, R, 40), lastContactAtCell = captureShared(cells, R, 39), lastSteeringCell = captureShared(cells, R, 10), estimateReachCell = captureShared(cells, R, 170), steeringModeCell = captureShared(cells, R, 17), lockDeadlineCell = captureShared(cells, R, 52), chooseWaverCell = captureShared(cells, R, 101), waverStyleCell = captureShared(cells, R, 42), chooseAggressionCell = captureShared(cells, R, 106), aggressionStyleCell = captureShared(cells, R, 49), tagTransitionCell = captureShared(cells, R, 204), lastTagTargetCell = captureShared(cells, R, 31), numericACell = captures.numericACell, queueCell = captureShared(cells, R, 206), lockStateCell = captureShared(cells, R, 205), reachRecords = value61, chooseEncounterCell = captureShared(cells, R, 109), encounterRecords = value46}, globals)
            value12(value13, value1)
            lifecycle.attachEngine(
                captureShared(cells, R, 63), captureShared(cells, R, 64),
                value68, value131, captureShared(cells, R, 75), value2)
        end
        closeCaptures(cells, R)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.applyKevinProfile = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value4, value6, value7, value18

        tmp_X = {...}
        value18 = rawget(tmp_X, 1)
        if (not captures.slot1.PROFILES[value18]) then
            value18 = "maximum"
        end
        value2 = captures.slot1.PROFILES[value18]
        value3 = value2.level
        if (not value3) then
            value3 = 0
        end
        captures.slot1.NAME = value18
        captures.slot1.LEVEL = value3
        value4 = captures.slot1
        value7 = value2.react
        if (not value7) then
            value7 = (0.3 * value3)
        end
        value4.REACT = value7
        value4 = captures.slot1
        value7 = value2.timing
        if (not value7) then
            value7 = (0.45 * value3)
        end
        value4.TIMING = value7
        value4 = captures.slot1
        value7 = value2.waver
        if (not value7) then
            value7 = (2 * value3)
        end
        value4.WAVER = value7
        value4 = captures.slot1
        value7 = value2.aim
        if (not value7) then
            value7 = (0.2792526803190927 * value3)
        end
        value4.AIM = value7
        value3 = captures.slot1
        value6 = value2.turn
        if (not value6) then
            value6 = 0
        end
        value3.TURN = value6
        value3 = captures.slot1
        value6 = value2.engage
        if (not value6) then
            value6 = globals.math.huge
        end
        value3.ENGAGE = value6
        value3 = captures.slot1
        value6 = value2.distBias
        if (not value6) then
            value6 = 0
        end
        value3.DISTBIAS = value6
        value3 = captures.slot1
        value6 = value2.pathErr
        if (not value6) then
            value6 = 0
        end
        value3.PATHERR = value6
        value3 = captures.slot1
        value6 = value2.sideOn
        if (not value6) then
            value6 = globals.math.huge
        end
        value3.SIDEON = value6
        value3 = captures.slot1
        value6 = value2.wiggleDeg
        if (not value6) then
            value6 = 0
        end
        value3.WIGGLEDEG = value6
        value3 = captures.slot1
        value6 = value2.wiggleMargin
        if (not value6) then
            value6 = 0
        end
        value3.WIGGLEMARGIN = value6
        value3 = captures.slot1
        value6 = value2.wigglePeriod
        if (not value6) then
            value6 = 0
        end
        value3.WIGGLEPERIOD = value6
        value3 = captures.slot1
        value6 = value2.wiggleStart
        if (not value6) then
            value6 = 0
        end
        value3.WIGGLESTART = value6
        value3 = captures.slot1
        value6 = value2.slideErr
        if (not value6) then
            value6 = 0
        end
        value3.SLIDEERR = value6
        value3 = captures.slot1
        value6 = value2.waverOut
        if (not value6) then
            value6 = 0
        end
        value3.WAVEROUT = value6
        value3 = captures.slot1
        value6 = value2.waverFace
        if (not value6) then
            value6 = globals.math.huge
        end
        value3.WAVERFACE = value6
        value3 = captures.slot1
        value6 = value2.waverSmooth
        if (not value6) then
            value6 = 0
        end
        value3.WAVERSMOOTH = value6
        value3 = captures.slot1
        value2 = value2.antiJitter
        if (not value2) then
            value2 = 0
        end
        value3.ANTIJITTER = value2
        value2 = captures.slot1
        value4 = (((captures.slot1.REACT + captures.slot1.TIMING) + captures.slot1.WAVER) + captures.slot1.AIM)
        value4 = (value4 > 0)
        if (not value4) then
            value4 = (captures.slot1.TURN > 0)
            if (not value4) then
                value4 = (captures.slot1.ENGAGE < globals.math.huge)
                if (not value4) then
                    value4 = (captures.slot1.DISTBIAS > 0)
                    if (not value4) then
                        value4 = (captures.slot1.PATHERR > 0)
                    end
                end
            end
        end
        value2.ON = value4
        captures.slot1.timingBias = 0
        captures.slot1.waverJitter = 0
        captures.slot1.lastLook = nil
        captures.slot1.slideNow = false
        captures.slot1.slideUntil = 0
        captures.slot1.slidingPrev = false
        captures.slot1.slideBias = 0
        value2 = captures.slot1
        value4 = 0
        value2.fleeJitter = value4
        captures.slot1.fleeJitterTarget = 0
        value2 = captures.slot1
        value4 = 0
        value2.fleeJitterAt = value4
        captures.slot1.oscScore = 0
        captures.slot1.lastTurnSign = 0
        captures.slot1.waverSteer = nil
        captures.slot1.wiggleAmpNow = 0
        value2 = captures.slot1
        value4 = 0
        value2.wiggleAmpAt = value4
        captures.slot3.engine = value18
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.playerActiveArena = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local tmp_D, tmp_X, value31, value37

        tmp_X = {...}
        value37 = rawget(tmp_X, 1)
        R[1] = value31
        globals.pcall((Functions.helper_1503({slot1 = value37, slot2 = captureShared(cells, R, 1)}, globals)))
        closeCaptures(cells, R)
        return R[1]
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2061 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value5, value21, value22, value23, value24, value25

        tmp_X = {...}
        value22, value23 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if value22 then
            value22 = captures.slot1[value22]
            value1 = (not value22)
            if (not value1) then
                value24 = value22.style
                if value23 then
                    value1 = value22.stats[value24]
                    value5 = (value22.stats[value24].kills + 1)
                    value1.kills = value5
                    value22.streak = 0
                else
                    value1 = value22.stats[value24]
                    value5 = (value22.stats[value24].deaths + 1)
                    value1.deaths = value5
                    if (not value22.locked) then
                        tmp_X = captures.slot2
                        value21 = readCell(tmp_X)
                        value23 = captures.slot3
                        tmp_X = captures.slot4
                        value25 = readCell(tmp_X)
                        value21(value22, value23, value24, value25)
                    end
                end
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2066 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1

        tmp_X = {...}
        value1 = ((rawget(tmp_X, 1)) == "orbit")
        return value1
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.copyCreatorLink = function(captures, globals)
    local function recovered(...)
        local value4

        value4 = globals.setclipboard
        if value4 then
            globals.pcall(value4, "https://www.youtube.com/@fanaka09")
            captures.slot1.Text = "Copied!"
        else
            value4 = globals.toclipboard
            if value4 then
                globals.pcall(value4, "https://www.youtube.com/@fanaka09")
                captures.slot1.Text = "Copied!"
            else
                value4 = globals.syn
                if value4 then
                    value4 = globals.syn.write_clipboard
                    if value4 then
                        globals.pcall(value4, "https://www.youtube.com/@fanaka09")
                        captures.slot1.Text = "Copied!"
                    else
                        captures.slot1.Text = "Clipboard N/A"
                    end
                else
                    captures.slot1.Text = "Clipboard N/A"
                end
            end
        end
        value4 = globals.task.delay
        value4((1.2), (Functions.helper_1391({slot1 = captures.slot1}, globals)))
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.findQueuePad = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local tmp_D, tmp_X, value2, value3, value11, value30, value31, value32, value33

        tmp_X = {...}
        value30, value31, value32, value33 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        R[1] = value11
        value2 = globals.pcall
        value3 = Functions.helper_407({slot1 = value30, catalogCell = captures.catalogCell, slot3 = value31, slot4 = value32, slot5 = value33, slot6 = captureShared(cells, R, 1)}, globals)
        value2(value3)
        closeCaptures(cells, R)
        return R[1]
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.someoneQueuing = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_Y, tmp_key, tmp_value, loopExit_11, loopExit_15, value1, value2, value3, value4, value5, value6, value7, value33, value34, value35, value36, value37

        tmp_X = {...}
        value34, value35 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = globals.ipairs
        value1 = {}
        value4 = "Left"
        value5 = "Right"
        tmp_Y = value1
        table.move({[4] = value4, [5] = value5}, 4, 5, 1, tmp_Y)
        value3 = value1
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                value5 = 1
                value6 = 4
                value7 = 1
                loop = {parent = loop, index = (value5 - value7), limit = value6, step = value7}
                while true do
                    loop.index += loop.step
                    loopContinues = (if (loop.step <= 0) then (loop.index >= loop.limit) else (loop.index <= loop.limit))
                    if loopContinues then
                        value37 = loop.index
                    end
                    if loopContinues then
                        value1 = captures.slot1.slotPlayer
                        value33 = captures.slot1.slotPad
                        value36 = value4
                        value33 = table.pack(value33(table.unpack({[34] = value34, [35] = value35, [36] = value36, [37] = value37}, 34, 37)))
                        value1 = value1(table.unpack(value33, 1, value33.n))
                        if value1 then
                            if ((captures.slot1.playerActiveArena(value1)) == nil) then
                                loopExit_15 = 29
                                break
                            else
                                continue
                            end
                        else
                            continue
                        end
                    else
                        loopExit_15 = 22
                        break
                    end
                end
                if (loopExit_15 == 22) then
                    loop = loop.parent
                    continue
                elseif (loopExit_15 == 29) then
                    loopExit_11 = 29
                    break
                end
            else
                loopExit_11 = 18
                break
            end
        end
        if (loopExit_11 == 18) then
            loop = loop.parent
            return false
        elseif (loopExit_11 == 29) then
        
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.handleTabClick = function(captures, globals)
    local function recovered(...)
        local tmp_X

        tmp_X = captures.authReadyCell
        if (not (not (readCell(tmp_X)))) then
            tmp_X = captures.slot2
            readCell(tmp_X)(captures.slot3)
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2138 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value4, value35, value36, value37, value38

        tmp_X = {...}
        value35, value36, value37, value38 = rawget(tmp_X, 1), rawget(tmp_X, 2), rawget(tmp_X, 3), rawget(tmp_X, 4)
        value2 = value35.MouseButton1Click
        value1 = lifecycle.connect
        value4 = Functions.helper_1121({slot1 = captures.slot1, slot2 = value37, slot3 = captures.slot2, slot4 = value36, slot5 = captures.slot3, slot6 = value38}, globals)
        value1(value2, value4)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.createRegistry = function(captures, globals)
    local function recovered(...)
        local R, cells = {}, {}
        local value2, value6

        value2 = globals.getgenv
        if value2 then
            R[4] = globals.getgenv
            value2 = R[4]()
            if (not value2) then
                value2 = globals._G
            end
        else
            value2 = globals._G
        end
        R[4] = value2.FANAKA
        if ((globals.type(R[4])) ~= "table") then
            R[4] = {}
            value2.FANAKA = R[4]
        end
        value6 = "Dracoware Bot v1.6"
        R[4].VERSION = value6
        if ((globals.type(R[4].brains)) ~= "table") then
            value6 = {}
            R[4].brains = value6
        end
        value6 = Functions.registerProfile({numericCCell = captures.numericCCell, slot2 = captureShared(cells, R, 4), registryCell = captures.catalogCell}, globals)
        R[4].register = value6
        value6 = Functions.selectProfile({registryCell = captureShared(cells, R, 4)}, globals)
        R[4].select = value6
        closeCaptures(cells, R)
        return R[4]
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseQueueArena = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_Y, tmp_key, tmp_value, loopExit_23, value1, value2, value3, value4, value5, value6, value23, value24, value25

        tmp_X = {...}
        value24 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        value1 = readCell(tmp_X).autoQueueFind
        if (not value1) then
            tmp_X = captures.slot1
            value1 = readCell(tmp_X).autoQueueArena
            if (value1 == "2") then
                value25 = globals.tonumber(value1)
                value23 = captures.slot3.inProgress
                if (not (value23(value24, value25))) then
                    if value25 then
                        return value25
                    else
                        value25 = nil
                        return value25
                    end
                else
                    value25 = nil
                    return value25
                end
            else
                if (value1 == "4") then
                    value25 = globals.tonumber(value1)
                    value23 = captures.slot3.inProgress
                    if (not (value23(value24, value25))) then
                        if value25 then
                            return value25
                        else
                            value25 = nil
                            return value25
                        end
                    else
                        value25 = nil
                        return value25
                    end
                else
                    if (value1 == "6") then
                        value25 = globals.tonumber(value1)
                        value23 = captures.slot3.inProgress
                        if (not (value23(value24, value25))) then
                            if value25 then
                                return value25
                            else
                                value25 = nil
                                return value25
                            end
                        else
                            value25 = nil
                            return value25
                        end
                    else
                        return nil
                    end
                end
            end
        end
        value1 = globals.ipairs
        value6 = {}
        value4 = 4
        value3 = 2
        value5 = 6
        tmp_Y = value6
        table.move({[3] = value3, [4] = value4, [5] = value5}, 3, 5, 1, tmp_Y)
        value2 = value6
        value1, value2, value3 = value1(value2)
        loop = {parent = loop, iterator = iterateValues(value1, value2, value3)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value2, value3 = tmp_key, tmp_value
            end
            if loopContinues then
                value23 = captures.slot3.inProgress
                value25 = value3
                value23 = (not (value23(value24, value25)))
                if value23 then
                    value23 = captures.slot3.someoneQueuing
                    value25 = value3
                    if ((value23(value24, value25))) then
                        loopExit_23 = 48
                        break
                    else
                        continue
                    end
                else
                    continue
                end
            else
                loopExit_23 = 32
                break
            end
        end
        if (loopExit_23 == 32) then
            loop = loop.parent
            tmp_X = captures.slot1
            value1 = readCell(tmp_X).autoQueueArena
            if (value1 == "2") then
                value25 = globals.tonumber(value1)
                value23 = captures.slot3.inProgress
                if (not (value23(value24, value25))) then
                    if value25 then
                        return value25
                    else
                        value25 = nil
                        return value25
                    end
                else
                    value25 = nil
                    return value25
                end
            else
                if (value1 == "4") then
                    value25 = globals.tonumber(value1)
                    value23 = captures.slot3.inProgress
                    if (not (value23(value24, value25))) then
                        if value25 then
                            return value25
                        else
                            value25 = nil
                            return value25
                        end
                    else
                        value25 = nil
                        return value25
                    end
                else
                    if (value1 == "6") then
                        value25 = globals.tonumber(value1)
                        value23 = captures.slot3.inProgress
                        if (not (value23(value24, value25))) then
                            if value25 then
                                return value25
                            else
                                value25 = nil
                                return value25
                            end
                        else
                            value25 = nil
                            return value25
                        end
                    else
                        return nil
                    end
                end
            end
        elseif (loopExit_23 == 48) then
        
        end
        return value3
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.selectUITab = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_D, tmp_X, tmp_key, tmp_value, value2, value3, value4, value5, value6, value7, value14, value15, value16, value17, value19

        tmp_X = {...}
        value19 = rawget(tmp_X, 1)
        tmp_X = captures.slot1
        writeCell(tmp_X, value19)
        value2 = globals.pairs
        value3 = captures.slot2
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                value6 = (value3 == value19)
                value4.Visible = value6
                continue
            else
                break
            end
        end
        loop = loop.parent
        value5 = globals.pairs
        value6 = captures.slot3
        value5, value6, value7 = value5(value6)
        loop = {parent = loop, iterator = iterateValues(value5, value6, value7)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value6, value7 = tmp_key, tmp_value
            end
            if loopContinues then
                value3 = (value6 == value19)
                if value3 then
                    value3 = captures.slot4.accent
                    if (not value3) then
                        value3 = captures.slot4.panel2
                    end
                else
                    value3 = captures.slot4.panel2
                end
                value7.BackgroundColor3 = value3
                value14 = (value6 == value19)
                if value14 then
                    value2 = globals.Color3.new
                    value16 = 1
                    value15 = 1
                    value17 = 1
                    value14 = value2
                    value14 = value14(value15, value16, value17)
                    if (not value14) then
                        value14 = captures.slot4.subtext
                    end
                else
                    value14 = captures.slot4.subtext
                end
                value7.TextColor3 = value14
                continue
            else
                break
            end
        end
        loop = loop.parent
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseEncounterStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value3, value5, value8, value10, value11, value12, value14

        tmp_X = {...}
        value14 = rawget(tmp_X, 1)
        value2 = captures.slot1[value14]
        if (not value2) then
            tmp_X = captures.slot2
            if readCell(tmp_X).randomiseLoseLose then
                value5 = captures.slot3
                value10 = globals.math.random
                value12 = (# captures.slot3)
                value11 = 1
                value5 = value5[(value10(value11, value12))]
            else
                tmp_X = captures.slot2
                value5 = readCell(tmp_X).defaultLoseLoseStyle
                if (not value5) then
                    value5 = "run"
                end
            end
            value2 = {}
            value2.style = value5
            value5 = {}
            value8 = {}
            value8.kills = 0
            value8.deaths = 0
            value5.grab = value8
            value8 = {}
            value11 = 0
            value8.kills = value11
            value11 = 0
            value8.deaths = value11
            value5.run = value8
            value2.stats = value5
            captures.slot1[value14] = value2
        end
        tmp_X = captures.slot2
        value3 = readCell(tmp_X).loseLoseStyleOverride[value14]
        value5 = "auto"
        if (value3 == value5) then
            value2.locked = false
            tmp_X = captures.slot2
            value5 = readCell(tmp_X).loseLoseStyleOverride
            value5[value14] = nil
            value2 = value2.style
            return value2
        end
        if (not (value3 == "grab")) then
            if (not (value3 == "run")) then
                value2 = value2.style
                return value2
            end
        end
        value2.style = value3
        tmp_X = captures.authAliveCell
        value3 = (not (readCell(tmp_X)))
        if (not value3) then
            value5 = true
            value2.locked = value5
            tmp_X = captures.slot2
            value3 = readCell(tmp_X).loseLoseStyleOverride
            value3[value14] = nil
            value2 = value2.style
            return value2
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.chooseQueueSideAndSlot = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value7, value9, value10, value11, value12

        tmp_X = {...}
        value10, value11 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value7 = readCell(tmp_X).autoQueueSide
        if (value7 == "left") then
            value4 = "Left"
        else
            value2 = "right"
            if (value7 == value2) then
                value4 = "Right"
            else
                value9 = captures.slot3.sideCount
                value12 = "Left"
                value2 = (value9(value10, value11, value12))
                value9 = captures.slot3.sideCount
                value12 = "Right"
                value4 = (value2 <= (value9(value10, value11, value12)))
                if value4 then
                    value4 = "Left"
                else
                    value4 = "Right"
                end
            end
        end
        value9 = captures.slot3.emptySlot
        value12 = value4
        value9 = value9(value10, value11, value12)
        if (not value9) then
            if (value7 == "either") then
                value4 = (value4 == "Left")
                if value4 then
                    value4 = "Right"
                else
                    value4 = "Left"
                end
                value9 = captures.slot3.emptySlot
                value12 = value4
                value9 = value9(value10, value11, value12)
            end
        end
        if (not value9) then
            return nil
        end
        return value4, value9
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.queueSelectionValid = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value4, value6, value10, value15, value16, value17, value18, value19, value20, value21

        tmp_X = {...}
        value15, value16 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        value2 = captures.slot1.arena
        if (not value2) then
            return false
        end
        value18 = value15
        value1 = value18.FindFirstChild
        value19 = ("Arena" .. value2)
        value17 = value1
        if (not (value17(value18, value19))) then
            return false
        end
        value17 = captures.slot1.inProgress
        value18 = value15
        value19 = value2
        if (((value17(value18, value19)))) then
            return false
        end
        value4 = captures.slot1.side
        if value4 then
            value4 = captures.slot1.slot
            if value4 then
                value17 = captures.slot1.slotPad
                value20 = captures.slot1.side
                value21 = captures.slot1.slot
                value18 = value15
                value19 = value2
                value17 = value17(value18, value19, value20, value21)
                if (not value17) then
                    return false
                end
                value4 = captures.slot1.slotPlayer(value17)
                if (captures.slot1.state == "ready") then
                    if (value4 ~= captures.slot2) then
                        return false
                    end
                else
                    if (value4 ~= value10) then
                        if (value4 ~= captures.slot2) then
                            return false
                        end
                    end
                end
                if (captures.slot1.state == "onslot") then
                    value6 = captures.slot1.padPos(value17)
                    if value6 then
                        if ((value16.Position - value6).Magnitude > captures.slot1.CHECK_DIST) then
                            return false
                        end
                    end
                else
                    if (captures.slot1.state == "ready") then
                        value6 = captures.slot1.padPos(value17)
                        if value6 then
                            if ((value16.Position - value6).Magnitude > captures.slot1.CHECK_DIST) then
                                return false
                            end
                        end
                    end
                end
            end
        end
        return true
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2216 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value4, value17, value18, value19, value20, value21

        tmp_X = {...}
        value19, value20 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if value19 then
            value19 = captures.slot1[value19]
            value1 = (not value19)
            if (not value1) then
                if (not value20) then
                    value20 = value19.style
                end
                value1 = value19.stats[value20]
                value4 = value19.stats[value20].deaths
                value4 = (value4 + (1))
                value1.deaths = value4
                if (not value19.locked) then
                    tmp_X = captures.slot3
                    value17 = readCell(tmp_X)
                    value1 = captures.slot4
                    tmp_X = captures.slot5
                    value21 = readCell(tmp_X)
                    value18 = value19
                    value19 = value1
                    value17(value18, value19, value20, value21)
                end
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.refreshCollisionFilters = function(captures, globals)
    local function recovered(...)
        local loop, loopContinues, tmp_X, tmp_key, tmp_value, value2, value3, value4, value6, value7, value8, value11, value13

        value13 = {}
        value3 = globals.workspace
        value6 = value3.GetDescendants
        value7 = value3
        value2 = value6
        value3 = value7
        value2, value3, value4 = value2(value3)
        loop = {parent = loop, iterator = iterateValues(value2, value3, value4)}
        while true do
            loopContinues, tmp_key, tmp_value = loop.iterator()
            if loopContinues then
                value3, value4 = tmp_key, tmp_value
            end
            if loopContinues then
                value7 = value4
                value11 = value7.IsA
                value8 = "BasePart"
                value6 = value11
                if ((value6(value7, value8))) then
                    if (value4.Name == "Wall") then
                        globals.table.insert(value13, value4)
                        continue
                    else
                        if (value4.Name == "Barrier") then
                            globals.table.insert(value13, value4)
                            continue
                        else
                            continue
                        end
                    end
                else
                    continue
                end
            else
                break
            end
        end
        loop = loop.parent
        captures.slot1.FilterDescendantsInstances = value13
        captures.slot2.FilterDescendantsInstances = value13
        tmp_X = captures.slot3
        writeCell(tmp_X, value13)
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2259 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value4, value6, value7, value8, value10, value11, value13, value21, value22, value23, value24, value25, value26, value27, value28, value29, value30, value31, value32, value33

        tmp_X = {...}
        value21 = rawget(tmp_X, 1)
        captures.slot1.goodWindow = true
        value1 = false
        tmp_X = captures.slot3
        writeCell(tmp_X, value1)
        value2 = value21.Bomb.BombHandle
        value4 = globals.tick()
        value6 = captures.slot4.Torso
        value23 = captures.slot4
        value1 = value23.FindFirstChild
        value24 = "Humanoid"
        value22 = value1
        value22 = value22(value23, value24)
        value7 = value2.Position
        tmp_X = captures.slot5
        value1 = readCell(tmp_X)
        tmp_X = captures.slot5
        value2 = readCell(tmp_X)
        if value1 then
            tmp_X = captures.slot6
            value2 = readCell(tmp_X)
        end
        if value2 then
            tmp_X = captures.slot6
            value1 = (value4 - (readCell(tmp_X)))
            value2 = (value1 > 0)
            if value2 then
                value2 = (value1 < 0.5)
                if value2 then
                    value28 = globals.Vector3.new
                    value29 = value6.Position.X
                    value31 = value6.Position.Z
                    value30 = 0
                    value28 = value28(value29, value30, value31)
                    value29 = globals.Vector3.new
                    value30 = value7.X
                    value31 = 0
                    value32 = value7.Z
                    value29 = value29(value30, value31, value32)
                    value30 = globals.Vector3.new
                    tmp_X = captures.slot5
                    value31 = readCell(tmp_X).X
                    value32 = 0
                    tmp_X = captures.slot5
                    value33 = readCell(tmp_X).Z
                    value26 = ((value29 - (value30(value31, value32, value33))) / value1)
                    value24 = (value29 - value28).Unit
                    value1 = value26.Magnitude
                    value2 = 0.1
                    value30 = 1
                    if (value2 < value1) then
                        value1 = value24.Dot
                        value25 = value26.Unit
                        value23 = value1
                        value23 = value23(value24, value25)
                        value1 = globals.math.clamp
                        value31 = (value23 + (0.5))
                        value33 = 1
                        value32 = 0
                        value30 = value1
                        value30 = value30(value31, value32, value33)
                    end
                    tmp_X = captures.slot7
                    value1 = (readCell(tmp_X).Magnitude > 0.1)
                    if value1 then
                        value1 = (value26.Magnitude > 0.1)
                        if value1 then
                            value24 = value26.Unit
                            value1 = value24.Dot
                            tmp_X = captures.slot7
                            value25 = readCell(tmp_X).Unit
                            value23 = value1
                            if ((value23(value24, value25)) < 0) then
                                tmp_X = captures.slot8
                                writeCell(tmp_X, 0)
                            else
                                value31 = globals.math.min
                                tmp_X = captures.slot8
                                value1 = readCell(tmp_X)
                                value32 = (value1 + (0.1))
                                value33 = 1
                                value31 = value31(value32, value33)
                                tmp_X = captures.slot8
                                writeCell(tmp_X, value31)
                            end
                        end
                    end
                    tmp_X = captures.slot7
                    value25 = readCell(tmp_X)
                    value1 = value25.Lerp
                    value27 = 0.3
                    value24 = value1
                    value24 = value24(value25, value26, value27)
                    tmp_X = captures.slot7
                    writeCell(tmp_X, value24)
                    if value22 then
                        value1 = (value22.WalkSpeed > 0)
                        if value1 then
                            value1 = value22.WalkSpeed
                            if (not value1) then
                                value1 = 16
                            end
                        else
                            value1 = 16
                        end
                    else
                        value1 = 16
                    end
                    value1 = (((value29 - value28).Magnitude / value1) + 0.2)
                    tmp_X = captures.slot8
                    value30 = (((value1 * (readCell(tmp_X))) * 0.5) * value30)
                    value29 = globals.math.clamp
                    value31 = 0
                    value32 = 1.5
                    value29 = value29(value30, value31, value32)
                    tmp_X = captures.slot7
                    value8 = (value7 + ((readCell(tmp_X)) * value29))
                else
                    value8 = value7
                end
            else
                value8 = value7
            end
        else
            value8 = value7
        end
        tmp_X = captures.slot5
        writeCell(tmp_X, value7)
        tmp_X = captures.slot6
        writeCell(tmp_X, value4)
        value10 = false
        value2 = captures.slot9.AWARE
        if value2 then
            value26 = value21
            value1 = value26.FindFirstChild
            value27 = "Torso"
            value25 = value1
            value2 = (value25(value26, value27))
            if value2 then
                tmp_X = captures.slot10
                value11 = readCell(tmp_X)(value21.Torso.Position)
                tmp_X = captures.slot10
                value2 = readCell(tmp_X)(value8)
                tmp_X = captures.slot10
                value13 = readCell(tmp_X)(value6.Position)
                value27 = (value2 - value13)
                value4 = value27.Magnitude
                if (not (0.001 < value4)) then
                    value23 = value8
                else
                    value29 = globals.math.clamp
                    value26 = (value11 - value13)
                    value25 = value26.Dot
                    value30 = ((value25(value26, value27)) / (value4 * value4))
                    value31 = 0
                    value32 = 1
                    value29 = value29(value30, value31, value32)
                    value1 = ((value11 - (value13 + (value27 * value29))).Magnitude < captures.slot9.BODY_R)
                    if value1 then
                        value1 = (value29 > 0.05)
                        if value1 then
                            value1 = (value29 < 0.95)
                            if value1 then
                                value1 = (value4 <= captures.slot11.SIDEON)
                                if value1 then
                                    value1 = (value2 - value11)
                                    value2 = value1.Magnitude
                                    value4 = (value2 > (0.01))
                                    if value4 then
                                        value4 = value1.Unit
                                        if (not value4) then
                                            value4 = value27.Unit
                                        end
                                    else
                                        value4 = value27.Unit
                                    end
                                    value1 = (value11 - value13)
                                    value2 = (value1.Magnitude > 0.01)
                                    if value2 then
                                        value2 = value1.Unit
                                        if (not value2) then
                                            value2 = value4
                                        end
                                    else
                                        value2 = value4
                                    end
                                    value24 = globals.Vector3.new
                                    value25 = (- value2.Z)
                                    value27 = value2.X
                                    value26 = 0
                                    value1 = (value24(value25, value26, value27))
                                    value24 = value1
                                    value23 = value24.Dot
                                    value25 = value4
                                    if ((value23(value24, value25)) < 0) then
                                        value2 = 2336
                                        tmp_X = captures.sentinelACell
                                        value1 = (- value1)
                                    end
                                    value2 = (value1 + value4)
                                    value4 = (value2.Magnitude > 0.01)
                                    if value4 then
                                        value4 = value2.Unit
                                        if (not value4) then
                                            value4 = value1
                                        end
                                    else
                                        value4 = value1
                                    end
                                    value1 = (value11 + (value4 * ((captures.slot9.BODY_R + 0.5) + captures.slot9.MARGIN)))
                                    value23 = globals.Vector3.new
                                    value24 = value1.X
                                    value25 = value8.Y
                                    value26 = value1.Z
                                    value23 = value23(value24, value25, value26)
                                    value10 = true
                                else
                                    value23 = value8
                                end
                            else
                                value23 = value8
                            end
                        else
                            value23 = value8
                        end
                    else
                        value23 = value8
                    end
                end
            else
                value23 = value8
            end
        else
            value23 = value8
        end
        value28 = globals.Vector3.new
        value29 = value8.X
        value30 = value6.Position.Y
        value31 = value8.Z
        value28 = value28(value29, value30, value31)
        value26 = globals.CFrame.lookAt
        value27 = value6.Position
        value1 = (value26(value27, value28))
        value29 = globals.Vector3.new
        value30 = 2.5
        value31 = 0
        value32 = (- 0.5)
        value29 = value29(value30, value31, value32)
        value2 = globals.Vector3.new
        value30 = value29.X
        value32 = value29.Z
        value31 = 0
        value29 = value2
        value4 = (value29(value30, value31, value32)).Unit
        value26 = value1
        value2 = value26.VectorToObjectSpace
        value27 = (value28 - value6.Position).Unit
        value25 = value2
        value25 = value25(value26, value27)
        value30 = globals.math.atan2
        value31 = ((value4.X * value25.Z) - (value4.Z * value25.X))
        value32 = ((value4.X * value25.X) + (value4.Z * value25.Z))
        value30 = value30(value31, value32)
        value2 = captures.slot11.ON
        if value2 then
            value2 = ((((globals.math.random()) * 2) - 1) * captures.slot11.AIM)
            if (not value2) then
                value2 = 0
            end
        else
            value2 = 0
        end
        value29 = globals.CFrame.Angles
        value31 = ((- value30) + value2)
        value30 = 0
        value32 = 0
        value1 = (value1 * (value29(value30, value31, value32)))
        value32 = (value7 - value6.Position).Magnitude
        value28 = globals.CFrame.Angles
        value29 = 0
        value30 = captures.slot11.wiggleAngle
        value31 = captures.slot13
        value30 = value30(value31, value32)
        value31 = 0
        value28 = value28(value29, value30, value31)
        value2 = captures.slot11.ON
        if value2 then
            value2 = (value32 > captures.slot11.ENGAGE)
            if value2 then
                tmp_X = captures.slot14
                value22 = readCell(tmp_X)
                value24 = true
                value25 = 3.5
            else
                value2 = captures.slot4.Humanoid
                value2.AutoRotate = false
                tmp_X = captures.slot14
                value22 = readCell(tmp_X)
                value24 = (value1 * value28)
                value25 = 3.5
            end
        else
            value2 = captures.slot4.Humanoid
            value2.AutoRotate = false
            tmp_X = captures.slot14
            value22 = readCell(tmp_X)
            value24 = (value1 * value28)
            value25 = 3.5
        end
        value27 = true
        value26 = value21
        value22(value23, value24, value25, value26, value27)
        if value10 then
            captures.slot1.navMode = "steal-around"
        end
        tmp_X = captures.slot15
        if ((readCell(tmp_X)) == true) then
            value2 = captures.slot4.Torso.CFrame.LookVector
            value4 = captures.slot4.Torso
            value7 = globals.CFrame.new(value7)
            value4.CFrame = value7
            value4 = captures.slot4.Torso
            value30 = globals.CFrame.lookAt
            value31 = captures.slot4.Torso.Position
            value32 = (captures.slot4.Torso.Position + value2)
            value30 = value30(value31, value32)
            value4.CFrame = value30
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2320 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value1, value2, value3, value4, value5, value7, value20, value21, value22, value23, value24

        tmp_X = {...}
        value23, value24 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        if (not value24) then
            return value2
        end
        tmp_X = captures.slot1
        value7 = readCell(tmp_X)(value23)
        tmp_X = captures.slot1
        value2 = ((readCell(tmp_X)(value24)) - value7)
        value1 = (value2.Magnitude > 0.01)
        if value1 then
            value1 = value2.Unit
            if (not value1) then
                value5 = globals.Vector3.new
                value2 = 0
                value3 = 0
                value4 = 1
                value1 = value5
                value1 = value1(value2, value3, value4)
            end
        else
            value5 = globals.Vector3.new
            value2 = 0
            value3 = 0
            value4 = 1
            value1 = value5
            value1 = value1(value2, value3, value4)
        end
        value5 = globals.Vector3.new
        value2 = (- value1.Z)
        value4 = value1.X
        value3 = 0
        value1 = value5
        value1 = value1(value2, value3, value4)
        value2 = Functions.helper_1076({slot1 = captures.slot2, slot2 = value7, slot3 = captures.slot3}, globals)
        value3 = globals.math.random()
        value3 = (value3 < (0.5))
        if value3 then
            value3 = 1
        else
            value3 = (- 1)
        end
        value4 = value2((value1 * value3))
        if (value4 < (4)) then
            if ((value2((value1 * (- value3)))) >= 4) then
                value3 = (- value3)
            end
        end
        value4 = (value1 * value3)
        value1 = globals.math.max
        value2 = value2(value4)
        value3 = 2
        value1 = value1(value2, value3)
        value20 = globals.Vector3.new
        value21 = (value7.X + (value4.X * value1))
        value22 = value23.Y
        value23 = (value7.Z + (value4.Z * value1))
        return value20(table.unpack({[21] = value21, [22] = value22, [23] = value23}, 21, 23))
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.recordKill = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value36

        tmp_X = {...}
        value36 = rawget(tmp_X, 1)
        if value36 then
            value36 = captures.slot1[value36]
            if (not (not value36)) then
                value2 = value36.stats[value36.style]
                value4 = (value36.stats[value36.style].kills + 1)
                value2.kills = value4
            end
        else
        
        end
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.objectPosition = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value5, value7, value8, value9, value10, value12

        tmp_X = {...}
        value5 = rawget(tmp_X, 1)
        if (not value5) then
            return value7
        end
        value8 = value5
        value2 = value8.IsA
        value9 = "BasePart"
        value7 = value2
        value2 = (value7(value8, value9))
        if value2 then
            value2 = value5.Position
            return value2
        end
        value8 = value5
        value12 = value8.FindFirstChildWhichIsA
        value9 = "BasePart"
        value10 = true
        value7 = value12
        value7 = value7(value8, value9, value10)
        if value7 then
            value7 = value7.Position
            return value7
        end
        value9 = globals.pcall
        value10 = Functions.helper_1395({slot1 = value5}, globals)
        value9, value10 = value9(value10)
        if value9 then
            value9 = value10.Position
            if (not value9) then
                value9 = nil
            end
        else
            value9 = nil
        end
        return value9
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.helper_2352 = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4, value6, value7, value9, value10, value11, value12, value13, value14, value15

        tmp_X = {...}
        value6, value7 = rawget(tmp_X, 1), rawget(tmp_X, 2)
        tmp_X = captures.slot1
        value2 = readCell(tmp_X)
        value2 = (value2 + (1))
        tmp_X = captures.slot1
        writeCell(tmp_X, value2)
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        value4 = {}
        value4.Name = value6
        value9 = globals.UDim2.new
        value10 = 1
        value11 = 0
        value12 = 0
        value13 = 26
        value9 = value9(value10, value11, value12, value13)
        value4.Size = value9
        value10 = captures.slot4.panel2
        value4.BackgroundColor3 = value10
        value4.BorderSizePixel = 0
        tmp_X = captures.slot1
        value10 = readCell(tmp_X)
        value4.LayoutOrder = value10
        value10 = "Frame"
        value12 = captures.slot5
        value9 = value2
        value11 = value4
        value9 = value9(value10, value11, value12)
        tmp_X = captures.slot6
        readCell(tmp_X)(value9, 6)
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        value4 = {}
        value10 = globals.UDim2.new
        value11 = 0.55
        value12 = (- 10)
        value13 = 1
        value14 = 0
        value10 = value10(value11, value12, value13, value14)
        value4.Size = value10
        value11 = globals.UDim2.fromOffset
        value12 = 10
        value13 = 0
        value11 = value11(value12, value13)
        value4.Position = value11
        value4.BackgroundTransparency = 1
        value11 = globals.Enum.Font.GothamMedium
        value4.Font = value11
        value4.Text = value7
        value10 = captures.slot4.subtext
        value4.TextColor3 = value10
        value4.TextSize = 12
        value10 = globals.Enum.TextXAlignment.Left
        value4.TextXAlignment = value10
        value11 = "TextLabel"
        value10 = value2
        value12 = value4
        value13 = value9
        value10 = value10(value11, value12, value13)
        tmp_X = captures.slot3
        value2 = readCell(tmp_X)
        value4 = "TextLabel"
        value7 = {}
        value11 = globals.UDim2.new
        value14 = 1
        value12 = 0.45
        value13 = (- 10)
        value15 = 0
        value11 = value11(value12, value13, value14, value15)
        value7.Size = value11
        value11 = globals.UDim2.new
        value12 = 0.55
        value13 = 0
        value14 = 0
        value15 = 0
        value11 = value11(value12, value13, value14, value15)
        value7.Position = value11
        value12 = 1
        value7.BackgroundTransparency = value12
        value12 = globals.Enum.Font.GothamBold
        value7.Font = value12
        value7.Text = "\226\128\148"
        value12 = captures.slot4.text
        value7.TextColor3 = value12
        value7.TextSize = 12
        value12 = globals.Enum.TextXAlignment.Right
        value7.TextXAlignment = value12
        value11 = value2
        value12 = value4
        value13 = value7
        value14 = value9
        value11 = value11(value12, value13, value14)
        value2 = captures.slot7
        value4 = {}
        value4.label = value10
        value4.value = value11
        value2[value6] = value4
        return
    end
    setfenv(recovered, globals)
    return recovered
end

Functions.formatStyle = function(captures, globals)
    local function recovered(...)
        local tmp_D, tmp_X, value2, value4

        tmp_X = {...}
        value2 = rawget(tmp_X, 1)
        value4 = (value2 == "grab")
        if value4 then
            value4 = "Grab"
        else
            value4 = (value2 == "run")
            if value4 then
                value4 = "Run"
            else
                value4 = "\226\128\148"
            end
        end
        return value4
    end
    setfenv(recovered, globals)
    return recovered
end

    local function numericA(input)
        assert(input == 4970, "Unanalysed numeric-A input")
        return (input % 100000) + 3 * input
    end
    local function numericB(input)
        assert(input == 1300 or input == 1461 or input == 2190 or input == 4908,
            "Unanalysed numeric-B input")
        return (6 * input % 10000) + 3 * input
    end
    local function numericC(input)
        assert(input == 2947 or input == 2648 or input == 2877 or input == 4151
            or input == 4290 or input == 494 or input == 2167 or input == 1018,
            "Unanalysed numeric-C input")
        return ((input + 92) % 100) * (input % 86)
    end
    local session = {
        catalogCell = cell(Catalog), sentinelACell = cell(2340), sentinelBCell = cell(5740),
        authReadyCell = cell(true), authAliveCell = cell(true),
        numericACell = cell(numericA), numericBCell = cell(numericB), numericCCell = cell(numericC),
    }
    local initialized, problem = xpcall(function()
        Functions.createRegistry({catalogCell = session.catalogCell, numericCCell = session.numericCCell}, globals)()
        Functions.createInterface({catalogCell = session.catalogCell, sentinelACell = session.sentinelACell,
            sentinelBCell = session.sentinelBCell, authReadyCell = session.authReadyCell,
            numericCCell = session.numericCCell}, globals)()
        Functions.createKevinEngine(session, globals)()
        assert(lifecycle.engine, "Kevin constructor did not attach its control state")
        assert(shared.FANAKA and shared.FANAKA.brains.kevin, "Kevin profile was not registered")
        assert(shared.FANAKA_UI, "Interface construction did not return its ScreenGui")
    end, function(err) return tostring(err) end)
    if not initialized then controller:destroy(); error("Fanaka startup failed: " .. problem, 0) end

    local controlsOK, controlsError = pcall(function()
    if options.controls ~= false then
        local window = shared.FANAKA_UI:FindFirstChild("Window")
        if window then
            local strip = instanceAPI.new("Frame", window)
            strip.Name = "ReconstructionControls"
            strip.Position = host.UDim2.new(0, 0, 1, 4)
            strip.Size = host.UDim2.new(1, 0, 0, 28)
            strip.BackgroundColor3 = host.Color3.fromRGB(32, 33, 39)
            strip.BorderSizePixel = 0
            local function button(name, label, x, width, action)
                local item = instanceAPI.new("TextButton", strip)
                item.Name = name; item.Text = label
                item.Position = host.UDim2.fromOffset(x, 2)
                item.Size = host.UDim2.fromOffset(width, 24)
                item.Font = host.Enum.Font.Gotham
                item.TextSize = 12
                item.BackgroundColor3 = host.Color3.fromRGB(44, 46, 54)
                item.TextColor3 = host.Color3.fromRGB(238, 239, 242)
                item.BorderSizePixel = 0
                lifecycle.connect(item.MouseButton1Click, action)
                return item
            end
            button("StartKevin", "Start Kevin", 4, 105, function() controller:setEnabled(true) end)
            button("PauseKevin", "Pause", 113, 70, function() controller:setEnabled(false) end)
            button("Unload", "Unload", 359, 77, function() controller:destroy() end)
            local status = instanceAPI.new("TextLabel", strip)
            status.Name = "RuntimeStatus"; status.BackgroundTransparency = 1
            status.Position = host.UDim2.fromOffset(189, 2); status.Size = host.UDim2.fromOffset(164, 24)
            status.Font = host.Enum.Font.Gotham; status.TextSize = 11
            status.TextColor3 = host.Color3.fromRGB(220, 223, 229)
            status.Text = "Paused"
            lifecycle.connect(host.game:GetService("RunService").RenderStepped, function()
                status.Text = if #lifecycle.errors > 0 then "Error: paused (see console)"
                    elseif controller:isEnabled() then "Kevin active" else "Paused"
            end)
        end
    end
    end)
    if not controlsOK then controller:destroy(); error("Fanaka controls failed: " .. tostring(controlsError), 0) end
    if options.testAccess then
        controller.testFunctions = Functions
        controller.testGlobals = globals
        controller.testLifecycle = lifecycle
        controller.testSession = session
        controller.testCell = cell
    end
    return controller
end

end)()
local environment = type(getgenv) == "function" and getgenv() or _G
local previous = environment.__FANAKA_RECOVERED_KEVIN
if type(previous) == "table" and type(previous.destroy) == "function" then previous:destroy() end
local controller = createApplication(getfenv(), {
    onDestroy = function(application)
        if environment.__FANAKA_RECOVERED_KEVIN == application then
            environment.__FANAKA_RECOVERED_KEVIN = nil
        end
    end,
})
environment.__FANAKA_RECOVERED_KEVIN = controller
print("Meticulously deobfed by the very same ai used in the development of this script. Pls like it. -biggiddybludspy")
return controller
