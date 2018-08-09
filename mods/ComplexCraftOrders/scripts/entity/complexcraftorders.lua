--[[
Author: Rinart73
Fandom: Avorion
Rating: 5 stars
Genre: Crazy idea
Relationships: My code/Logic
Warnings: Over-optimization, Facepalms, Cola
]]

package.path = package.path .. ";data/scripts/lib/?.lua"
package.path = package.path .. ";mods/ComplexCraftOrders/?.lua"

require("stringutility")
require("faction")

local format = string.format
local min = math.min

local function table_export(o)
   if type(o) == "table" then
      local s = "{ "
      for k,v in pairs(o) do
         if type(k) ~= "number" then k = '"'..k..'"' end
         s = s .. "["..k.."] = " .. table_export(v) .. ", "
      end
      return s .. "} "
   else
      return tostring(o)
   end
end

local isLoaded, config = pcall(require, "config/Config")

local Level = { Error = 1, Warn = 2, Info = 3, Debug = 4 }
local logLevelLabel = { "ERROR", "WARN", "INFO", "DEBUG" }
--[[
Better version, doesn't call functions when we don't need to display that level so debug will not ruin performance
Faster when functions are passed, but we don't need to display that level. 30% slower when we need to
log(Level.Debug, "table contents: %s, value = %s", table_export(sometable), tostring(myvar)) -> 
log(Level.Debug, "table contents: %s, value = %s", table_export, sometable, tostring, myvar)
]]
local function log(level, msg, ...)
    if level > config.logLevel then return end
    local args = {...}
    local finalArgs = {}
    local finalArgLen = 0
    local funcArgs = {}
    local funcArgLen = 0
    local func
    local arg
    for i = 1, select("#", ...) do
        arg = args[i]
        if type(arg) == "function" then
            if func then
                finalArgLen = finalArgLen + 1
                finalArgs[finalArgLen] = func(unpack(funcArgs, 1, funcArgLen))
                funcArgs = {}
                funcArgLen = 0
            end
            func = arg
        else
            if func then
                funcArgLen = funcArgLen + 1
                funcArgs[funcArgLen] = arg
            else
                finalArgLen = finalArgLen + 1
                finalArgs[finalArgLen] = arg
            end
        end
    end
    if func then
        finalArgLen = finalArgLen + 1
        finalArgs[finalArgLen] = func(unpack(funcArgs, 1, funcArgLen))
    end
    print(string.format("[%s][CCO]: "..msg, logLevelLabel[level], unpack(finalArgs, 1, finalArgLen)))
end

-- API
local function logModule(m, level, msg, ...)
    if level > config.logLevel then return end
    log(level, "(%s): "..msg, m._name, ...)
end
--

if not isLoaded then
    local err = config
    config = { logLevel = 3 }
    log(Level.Error, "Failed to load config: %s", err)
end


-- namespace ComplexCraftOrders
ComplexCraftOrders = {}

local targets = {} -- Who
local conditions = {} -- When
local actions = {} -- What to do

local conditionOperators = { "And", "Or", "Action" }
local actionOperators = { "", "And", "Else" }
local ConditionOperator = { And = 0, Or = 1, Action = 2 }
local ActionOperator = { None = 0, And = 1, Else = 2 }

function ComplexCraftOrders.fixRules(data) -- returns rules data with errors fixed
    if not data then return {} end
    local rules = data.rules or {}

    log(Level.Debug, "fixRules - input: %s", table_export, rules)

    local result = {}
    local block = {}
    local blockHasAction = false
    local actionExpected = false
    local argTargetType, argConditionType
    local isAction
    local canUseElse = true
    local i = 1 -- using own var instead of 'for' var, because Lua doesn't allow to decrement it
    local row
    local actualEnd = min(#rules, config.maxRows)
    for _ = 1, config.maxRows*2 do -- still faster than 'while'
        if i > actualEnd then break end
        row = rules[i]

        if not actionExpected then -- Condition expected
            if type(row.target) == "string" and targets[row.target]
              and type(row.condition) == "string" and conditions[row.condition]
              and type(row.operator) == "number" and conditionOperators[row.operator+1] then
                argTargetType = type(row.argTarget)
                argConditionType = type(row.argCondition)
                if (argTargetType == "nil" or argTargetType == "string" or argTargetType == "number")
                  and (argConditionType == "nil" or argConditionType == "string" or argConditionType == "number") then
                    block[#block+1] = row
                    actionExpected = row.operator == ConditionOperator.Action
                else
                    log(Level.Debug, " - row %u is not Condition (args): %s, %s", i, argTargetType, argConditionType)
                end
            else
                log(Level.Debug, " - row %u is not Condition: (%s) - %s, (%s) - %s, (%s) - %s", i,
                  tostring, row.target, tostring, targets[row.target],
                  tostring, row.condition, tostring, conditions[row.condition],
                  tostring, row.operator, tostring, conditionOperators[row.operator+1])
            end
        else -- Action expected
            isAction = false
            if type(row.action) == "string" and actions[row.action]
              and type(row.operator) == "number" and actionOperators[row.operator+1] then
                argConditionType = type(row.argAction)
                if argConditionType == "nil" or argConditionType == "string" or argConditionType == "number" then
                    isAction = true
                else
                    log(Level.Debug, " - row %u is not Action (args): %s", i, argConditionType)
                end
            else
                log(Level.Debug, " - row %u is not Action: %s - %s, %s - %s", i,
                  tostring, row.action, tostring, targets[row.action],
                  tostring, row.operator, tostring, conditionOperators[row.operator+1])
            end
            if isAction then
                blockHasAction = true
                actionExpected = row.operator ~= ActionOperator.None
                if row.operator == ActionOperator.Else then -- if 'else'
                    if canUseElse then
                        canUseElse = false
                    else -- turn 'else' into 'and'
                        log(Level.Debug, " - row %u - only one 'else' in block is allowed", i)
                        row.operator = ActionOperator.And
                    end
                end
                block[#block+1] = row
                if not actionExpected then -- save block
                    for j = 1, #block do
                        result[#result+1] = block[j]
                    end
                    block = {}
                    canUseElse = true
                    blockHasAction = false
                end
            elseif row.invert then -- got a condition
                actionExpected = false
                if blockHasAction then -- remove 'and'/'else' from previous action
                    block[#block].operator = ActionOperator.None
                    for j = 1, #block do -- and save block
                        result[#result+1] = block[j]
                    end
                    log(Level.Debug, " - row %u - got Condition instead of Action - block is saved", i)
                else  -- there are no Actions in this block. Delete whole block
                    log(Level.Debug, " - row %u - got Condition instead of Action - block is deleted", i)
                end
                block = {}
                blockHasAction = false
                canUseElse = true
                i = i - 1 -- proccess this row again as condition
            end
        end
        i = i + 1
    end
    
    -- write unfinished block
    if #block > 0 then
        local row = block[#block]
        -- if last row is Condition with operator 'action' or it's Action with operator 'and'/'else'
        if (row.invert and row.operator == ConditionOperator.Action)
          or (not row.invert and row.operator ~= ActionOperator.None) then
            block[#block].operator = 0
        end
    end
    for j = 1, #block do
        result[#result+1] = block[j]
    end
    
    log(Level.Debug, "fixRules - output: %s", table_export, rules)
    
    data.rules = result
    return data
end


if isLoaded then
if onServer() then


local settings = { version = config.version.string } -- serialized rows, toggle, version
local rules = {} -- rules in a format that is easier to execute

function ComplexCraftOrders.initialize()
    if callingPlayer then return end
    if Faction().isAIFaction then terminate() return end
    
    local hasTargets, hasConditions, hasActions
    local name
    local s, m
    for i = 1, #config.modules do
        name = config.modules[i]
        s, m = pcall(require, format("modules/%s/module", name))
        if not s then
            log(Level.Error, "Error while loading module '%s': %s", name, m)
        else
            log(Level.Debug, "Loading module '%s'", name)
            if m.initialize then -- create an API for module
                m.initialize({
                  _name = name,
                  Level = Level,
                  log = logModule
                })
            end
            if m.Target then
                for k, v in pairs(m.Target) do
                    if not v.func then
                        log(Level.Error, "Module '%s' - target '%s' doesn't have a function", name, k)
                    else
                        targets[k] = v
                        hasTargets = true
                    end
                end
            end
            if m.Condition then
                for k, v in pairs(m.Condition) do
                    if not v.func then
                        log(Level.Error, "Module '%s' - condition '%s' doesn't have a function", name, k)
                    else
                        conditions[k] = v
                        hasConditions = true
                    end
                end
            end
            if m.Action then
                for k, v in pairs(m.Action) do
                    if not v.func then
                        log(Level.Error, "Module '%s' - action '%s' doesn't have a function", name, k)
                    else
                        actions[k] = v
                        hasActions = true
                    end
                end
            end
        end
    end
    isLoaded = hasTargets and hasConditions and hasActions
    if not isLoaded then
        log(Level.Error, "mod was turned off because there are no targets, conditions or actions")
    end
end

function ComplexCraftOrders.secure()
    if callingPlayer then return end
    log(Level.Debug, "secure: %s", table_export, settings)
    return settings
end

function ComplexCraftOrders.restore(dataIn)
    if callingPlayer then return end
    settings = ComplexCraftOrders.fixRules(dataIn)
    log(Level.Debug, "restore: %s", table_export, settings)
    if settings.version then
        if settings.version == "0.1.0" then -- update
            settings.version = config.version.string
        end
    else
        settings = { version = config.version.string }
    end
    rules = ComplexCraftOrders.processRawRules(settings)
end

function ComplexCraftOrders.getUpdateInterval()
    return config.updateInterval
end

function ComplexCraftOrders.updateServer()
    local entity = Entity()
    if not isLoaded or callingPlayer or not settings.toggle or #rules == 0 or entity.hasPilot then return end
    local captains = entity:getCrewMembers(CrewProfessionType.Captain)
    if not captains or captains == 0 then return end
    
    log(Level.Debug, "updateServer - %u blocks", #rules)
    local t = appTimeMs()
    
    local targetCache = {}
    local conditionCache = {}

    local sector = Sector()
    local block, group, part
    local executeAction
    local rowTarget, rowCondition, rowAction
    local previousTarget, currentTarget, currentCondition, currentTargetIndex
    local targetData, arg
    
    for i = 1, #rules do
        block = rules[i]
        executeAction = false
        previousTarget = nil
        currentTarget = nil
        for j = 1, #block.conditions do
            group = block.conditions[j]
            if executeAction then break end -- some other group of Conditions was already met
            for k = 1, #group do
                part = group[k]
                rowTarget = part.target
                targetData = targets[rowTarget]
                arg = part.argTarget or ""
                previousTarget = currentTarget -- save previous target. if conditions will not be met, it will be passed to 'else' Actions
                if targetData.cache ~= false
                  and targetCache[rowTarget]
                  and targetCache[rowTarget][arg] then -- if target is already cached
                    log(Level.Debug, " - Use cached Target for '%s', '%s'", rowTarget, arg)
                    currentTarget = targetCache[rowTarget][arg][1]
                else
                    currentTarget = targetData.func(sector, arg)
                    if targetData.cache ~= false then -- save
                       if not targetCache[rowTarget] then
                          targetCache[rowTarget] = {}
                       end
                       targetCache[rowTarget][arg] = {currentTarget}
                    end
                end
                rowCondition = part.condition
                conditionData = conditions[rowCondition]
                if not currentTarget and not conditionData.acceptsNil then break end -- no target found, stop checking this group unless condition accepts nil
                currentTargetIndex = currentTarget and currentTarget.index.string or ""
                arg = part.argCondition or ""
                if conditionData.cache ~= false and conditionCache[rowCondition]
                  and conditionCache[rowCondition][currentTargetIndex]
                  and conditionCache[rowCondition][currentTargetIndex][arg] then -- if condition is already cached
                    log(Level.Debug, " - Use cached Condition for '%s', '%s', '%s'", rowCondition, currentTargetIndex, arg)
                    currentCondition = conditionCache[rowCondition][currentTargetIndex][arg][1]
                else
                    currentCondition = conditionData.func(currentTarget, arg)
                    if conditionData.cache ~= false then -- save
                       if not conditionCache[rowCondition] then
                          conditionCache[rowCondition] = {}
                       end
                       if not conditionCache[rowCondition][currentTargetIndex] then
                          conditionCache[rowCondition][currentTargetIndex] = {}
                       end
                       conditionCache[rowCondition][currentTargetIndex][arg] = {currentCondition}
                    end
                end
                if part.invert == 1 then
                    log(Level.Debug, " - invert")
                end
                if (part.invert == 0 and currentCondition) or (part.invert == 1 and not currentCondition) then
                    if k == #group then -- if this is the last part in condition group, we need to stop checking conditions and execute action
                        executeAction = true
                    end
                else
                    break -- condition was not met, stop checking this group
                end
            end
        end
        if executeAction then
            log(Level.Debug, " - Execute actions")
            for j = 1, #block.actions do
                rowAction = block.actions[j]
                arg = rowAction.argAction or ""
                actions[rowAction.action].func(currentTarget, arg)
            end
        elseif #block.actionsElse > 0 then
            log(Level.Debug, " - Execute actionsElse")
            for j = 1, #block.actionsElse do
                rowAction = block.actionsElse[j]
                arg = rowAction.argAction or ""
                actions[rowAction.action].func(previousTarget, arg)
            end
        end
    end
    t = appTimeMs() - t
    log(Level.Info, "updateServer took %u ms to execute", t)
end

-- Functions
local users = {} -- list of players that will receive new settings

function ComplexCraftOrders.sendSettings()
    if not isLoaded or not callingPlayer then return end
    local player = Player(callingPlayer)
    if not checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips) then
        log(Level.Warn, "Settings weren't sent because player '%s' doesn't have permissions to do this. Random error or cheating?", player.name)
        return
    end
    local alreadyExists = false
    for i = 1, #users do
        if users[i] == callingPlayer then
            alreadyExists = true
            break
        end
    end
    log(Level.Debug, "sendSettings: %s", table_export, settings)
    if not alreadyExists then users[#users+1] = callingPlayer end
    invokeClientFunction(player, "receiveSettings", settings, {
      targets = targets,
      conditions = conditions,
      actions = actions,
      maxRows = config.maxRows
    })
end

function ComplexCraftOrders.changeSettings(data)
    local entity = Entity()
    if not isLoaded or not checkEntityInteractionPermissions(entity, AlliancePrivilege.ManageShips) then
        local playerName = callingPlayer and Player(callingPlayer).name or ""
        log(Level.Warn, "Settings weren't changed because player '%s' doesn't have permissions to do this. Random error or cheating?", playerName)
        return
    end

    log(Level.Debug, "changeSettings: %s", table_export, data)
    
    if not data.version or data.version ~= config.version.string then
        log(Level.Warn, "Settings weren't changed, because versions doesn't match - server %s, client - %s", config.version.string, tostring, data.version)
        return
    end
    
    if data.rules == nil then
        settings.toggle = data.toggle
    else
        settings = ComplexCraftOrders.fixRules(data)
        rules = ComplexCraftOrders.processRawRules(settings)
    end
    
    -- send new settings to only players that have permissions, are in the same sector and previously accessed mod window
    local newData = data.rules == nil and { toggle = data.toggle } or settings
    local sx, sy = Sector():getCoordinates()
    local player, px, py
    local newUsers = {}
    for i = 1, #users do
        callingPlayer = users[i]
        player = Player(callingPlayer)
        if player then
            px, py = player:getSectorCoordinates()
            if sx == px and sy == py and checkEntityInteractionPermissions(entity, AlliancePrivilege.ManageShips) then
                newUsers[#newUsers+1] = callingPlayer
                invokeClientFunction(player, "receiveSettings", newData)
            end
        end
    end
    users = newUsers
end

function ComplexCraftOrders.processRawRules(raw) -- transform raw rules in a more useful for execution format
    local rules = {}
    local block = { conditions = {{}}, actions = {}, actionsElse = {} }
    local row
    local groupIndex = 1
    local conditionIndex = 0
    local elseBranch = false
    for i = 1, #settings.rules do
        row = settings.rules[i]
        if row.target then -- Condition
            if #block.actions > 0 then -- save block
                elseBranch = false
                rules[#rules+1] = block
                block = { conditions = {{}}, actions = {}, actionsElse = {} }
            end
            conditionIndex = conditionIndex + 1
            block.conditions[groupIndex][conditionIndex] = row
            if row.operator == ConditionOperator.Or then
                groupIndex = groupIndex + 1
                block.conditions[groupIndex] = {}
                conditionIndex = 0
            end
        else -- Action
            if conditionIndex > 0 then -- it's first Action row in the block
                groupIndex = 1
                conditionIndex = 0
            end
            if elseBranch then
                block.actionsElse[#block.actionsElse+1] = row
            else
                block.actions[#block.actions+1] = row
                elseBranch = row.operator == ActionOperator.Else
            end
        end
    end
    if #block.actions > 0 then
        rules[#rules+1] = block
    end
    log(Level.Debug, "processRawRules: %s", table_export, rules)
    return rules
end


else -- onClient


local isSettingsLoaded = false

-- alphabetically sorted
local targetsSorted = {}
local conditionsSorted = {}
local actionsSorted = {}
-- get position in sorted array by string
local targetSortedIndexes = {}
local conditionSortedIndexes = {}
local actionSortedIndexes = {}

local toggleCheckBox -- allows to toggle all rulesets on/off
local leftRowsLabel -- displays how many rows player used
local applyLabel -- because we can't change button text color

local targetComboBoxes = {}
local targetArgComboBoxes = {}
local targetArgTextBoxes = {}
local notComboBoxes = {}
local conditionComboBoxes = {}
local conditionArgComboBoxes = {}
local conditionArgTextBoxes = {}
local operatorComboBoxes = {}
local insertRowButtons = {}

local emptySpace -- allows to select ComboBox entries that are otherwise being displayed outside of the window

local rowByTargetComboBox = {}
local rowByConditionComboBox = {}
local rowByOperatorComboBox = {}
local rowByInsertRowButton = {}

local targetComboBoxesOldValue = {}
local conditionComboBoxesOldValue = {}
local operatorComboBoxesOldValue = {}
local currentOperatorValues = {} -- 'current' value (old value but just before being updated)
local otherComboBoxesOldValue = {} -- arguments, not
 
local rowLines = {} -- shows whether row is related to actions or actionsElse
local connectorLines = {} -- connects rows in one group
local separatorLines = {} -- visually separates blocks

local rowsUsed = 0
local settingsPrevious = {} -- current server settings
local isUnsaved = false


function ComplexCraftOrders.initUI()
    local res = getResolution()
    local size = vec2(900, 600)

    local menu = ScriptUI()
    local window = menu:createWindow(Rect(res * 0.5 - size * 0.5, res * 0.5 + size * 0.5))
    menu:registerWindow(window, "Complex craft orders"%_t)

    window.caption = "Complex craft orders"%_t
    window.showCloseButton = 1
    window.moveable = 1

    -- Top window controls
    local topRect = Rect(10, 10, window.width - 10, 35)
    local toggleSplitter = UIVerticalSplitter(topRect, 10, 0, 0.13)
    local leftRowsSplitter = UIVerticalSplitter(toggleSplitter.right, 10, 0, 0.17)
    local topButtonsSplitter = UIVerticalMultiSplitter(leftRowsSplitter.right, 10, 0, 4)

    toggleCheckBox = window:createCheckBox(Rect(toggleSplitter.left.lower + vec2(0, 2.5), toggleSplitter.left.upper + vec2(0, -2.5)), "Toggle", "")
    leftRowsLabel = window:createLabel(Rect(leftRowsSplitter.left.lower + vec2(0, 5), leftRowsSplitter.left.upper), format("0/%u rows used", config.maxRows), 15) 
    local clearAllButton = window:createButton(topButtonsSplitter:partition(0), "Clear all", "onClearAllButtonClicked")
    local resetButton = window:createButton(topButtonsSplitter:partition(1), "Reset", "onResetButtonClicked")
    local addRowStartButton = window:createButton(topButtonsSplitter:partition(2), "+ Row start", "onAddRowStartButtonClicked")
    local addRowEndButton = window:createButton(topButtonsSplitter:partition(3), "+ Row end", "onAddRowEndButtonClicked")
    window:createButton(topButtonsSplitter:partition(4), "", "onApplyButtonClicked")
    local applyLabelPartition = topButtonsSplitter:partition(4)
    applyLabel = window:createLabel(Rect(applyLabelPartition.lower + vec2(0, 4), applyLabelPartition.upper), "Apply", 14)

    toggleCheckBox.captionLeft = false
    leftRowsLabel.centered = true
    clearAllButton.textSize = 14
    resetButton.textSize = 14
    addRowStartButton.textSize = 14
    addRowEndButton.textSize = 14
    applyLabel.centered = true

    local frame = window:createScrollFrame(Rect(vec2(10, 45), window.size - vec2(10, 10)))
    local lister = UIVerticalLister(Rect(vec2(10, 10), window.size - vec2(80, 10)), 10, 0)
    local rect, targetSplitter, targetArgSplitter, notSplitter, conditionSplitter, conditionArgSplitter
    local targetComboBox, targetArgComboBox, targetArgTextBox, notComboBox, conditionComboBox, conditionArgComboBox, conditionArgTextBox, operatorComboBox
    local rowLine, connectorLine, separatorLine

    for i = 1, config.maxRows do    
        rect = lister:placeRight(vec2(lister.inner.width - 30, 25))

        targetSplitter = UIVerticalSplitter(rect, 10, 0, 0.26)
        targetArgSplitter = UIVerticalSplitter(targetSplitter.right, 10, 0, 0.18)
        notSplitter = UIVerticalSplitter(targetArgSplitter.right, 10, 0, 0.135)
        conditionSplitter = UIVerticalSplitter(notSplitter.right, 10, 0, 0.51)
        conditionArgSplitter = UIVerticalSplitter(conditionSplitter.right, 10, 0, 0.54)

        targetComboBox = frame:createComboBox(targetSplitter.left, "onTargetBoxSelected")
        targetArgComboBox = frame:createComboBox(targetArgSplitter.left, "onOtherBoxSelected")
        targetArgTextBox = frame:createTextBox(targetArgSplitter.left, "onOtherBoxSelected")
        notComboBox = frame:createComboBox(notSplitter.left, "onOtherBoxSelected")
        conditionComboBox = frame:createComboBox(conditionSplitter.left, "onConditionBoxSelected")
        conditionArgComboBox = frame:createComboBox(conditionArgSplitter.left, "onOtherBoxSelected")
        conditionArgTextBox = frame:createTextBox(conditionArgSplitter.left, "onOtherBoxSelected")
        operatorComboBox = frame:createComboBox(conditionArgSplitter.right, "onOperatorBoxSelected")
        insertRowButton = frame:createButton(Rect(rect.upper + vec2(10, -5), rect.upper + vec2(30, 15)), "+", "OnInsertRowButtonClicked")
        rowLine = frame:createLine(rect.lower + vec2(-30, 12.5), rect.lower + vec2(-10, 12.5))
        connectorLine = frame:createLine(rect.lower + vec2(-30, 12.5), rect.lower + vec2(-30, 47.5))
        separatorLine = frame:createLine(rect.lower + vec2(-30, 30), rect.upper + vec2(0, 5))
        
        insertRowButton.textSize = 14
        notComboBox:addEntry("")
        notComboBox:addEntry("Not")
        separatorLine.color = ColorInt(0xff41414b)
        
        targetComboBox.visible = false
        targetArgComboBox.visible = false
        targetArgTextBox.visible = false
        notComboBox.visible = false
        conditionComboBox.visible = false
        conditionArgComboBox.visible = false
        conditionArgTextBox.visible = false
        operatorComboBox.visible = false
        insertRowButton.visible = false
        rowLine.visible = false
        connectorLine.visible = false
        separatorLine.visible = false
        
        targetComboBoxes[i] = targetComboBox
        rowByTargetComboBox[targetComboBox.index] = i
        targetArgComboBoxes[i] = targetArgComboBox
        targetArgTextBoxes[i] = targetArgTextBox
        notComboBoxes[i] = notComboBox
        conditionComboBoxes[i] = conditionComboBox
        rowByConditionComboBox[conditionComboBox.index] = i
        conditionArgComboBoxes[i] = conditionArgComboBox
        conditionArgTextBoxes[i] = conditionArgTextBox
        operatorComboBoxes[i] = operatorComboBox
        rowByOperatorComboBox[operatorComboBox.index] = i
        insertRowButtons[i] = insertRowButton
        rowByInsertRowButton[insertRowButton.index] = i
        rowLines[i] = rowLine
        connectorLines[i] = connectorLine
        separatorLines[i] = separatorLine
    end

    rect = lister:placeRight(vec2(1, 1))
    emptySpace = frame:createLine(rect.lower, rect.upper)
    emptySpace.color = ColorInt(0x00000000)
end

function ComplexCraftOrders.onShowWindow()
    if isSettingsLoaded == false then
        isSettingsLoaded = nil -- don't allow to ask for configs again
        invokeServerFunction("sendSettings") -- request modules and rules
    end
end

function ComplexCraftOrders.interactionPossible(playerIndex, option)
    if not isLoaded then return end
    if not checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips) then
        return false
    end
    return true
end

-- Callbacks

function ComplexCraftOrders.onClearAllButtonClicked()
    if not isSettingsLoaded then return end
    ComplexCraftOrders.clear()
end

function ComplexCraftOrders.onResetButtonClicked()
    if not isSettingsLoaded then return end
    ComplexCraftOrders.clear()
    log(Level.Debug, "onResetButtonClicked: %s", table_export, settingsPrevious)
    ComplexCraftOrders.deserializeRules(settingsPrevious)
    toggleCheckBox.checked = settingsPrevious.toggle
    isUnsaved = false
    applyLabel.color = ColorInt(0xffe0e0e0)
end

function ComplexCraftOrders.onApplyButtonClicked()
    if not isSettingsLoaded then return end
    if isUnsaved then  -- send all
        local data = ComplexCraftOrders.serializeRules()
        data.toggle = toggleCheckBox.checked
        invokeServerFunction("changeSettings", data)
        isUnsaved = false
        applyLabel.color = ColorInt(0xffe0e0e0)
    else -- checkbox only
        invokeServerFunction("changeSettings", {
          version = config.version.string,
          toggle = toggleCheckBox.checked
        })
    end
end

function ComplexCraftOrders.onAddRowStartButtonClicked()
    if not isSettingsLoaded then return end
    if rowsUsed == config.maxRows then
        Player():sendChatMessage("There are no empty rows left"%_t)
        return
    end
    local data = ComplexCraftOrders.serializeRules()
    table.insert(data.rules, 1, {
      target = targetsSorted[1],
      invert = 0,
      condition = conditionsSorted[1],
      operator = ConditionOperator.And
    })
    ComplexCraftOrders.clear()
    ComplexCraftOrders.deserializeRules(ComplexCraftOrders.fixRules(data))
end

function ComplexCraftOrders.onAddRowEndButtonClicked()
    if not isSettingsLoaded then return end
    if rowsUsed == config.maxRows then
        Player():sendChatMessage("There are no empty rows left"%_t)
        return
    end
    rowsUsed = rowsUsed + 1
    leftRowsLabel.caption = format("%u/%u rows used"%_t, rowsUsed, config.maxRows)
    ComplexCraftOrders.addConditionRow(rowsUsed)

    -- move empty space
    local lastRow = targetComboBoxes[rowsUsed]
    emptySpace.rect = Rect(lastRow.upper + vec2(0, 10), lastRow.upper + vec2(0, 310))
    
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.OnInsertRowButtonClicked(button)
    if rowsUsed == config.maxRows then
        Player():sendChatMessage("There are no empty rows left"%_t)
        return
    end
    local rowIndex = rowByInsertRowButton[button.index]
    local data = ComplexCraftOrders.serializeRules()
    local operator = operatorComboBoxes[rowIndex].selectedIndex
    local isCondition = notComboBoxes[rowIndex].visible

    if (isCondition and operator ~= ConditionOperator.Action) or (not isCondition and operator == ActionOperator.None) then
        table.insert(data.rules, rowIndex+1, {
          target = targetsSorted[1],
          invert = 0,
          condition = conditionsSorted[1],
          operator = ConditionOperator.And
        })
    else -- insert Action with 'and' operator
        table.insert(data.rules, rowIndex+1, {
          action = actionsSorted[1],
          operator = ActionOperator.And
        })
    end
    
    ComplexCraftOrders.clear()
    ComplexCraftOrders.deserializeRules(ComplexCraftOrders.fixRules(data))
end

function ComplexCraftOrders.onOtherBoxSelected(box, selectedIndex)
    if not selectedIndex then -- it's TextBox
        selectedIndex = box.text
    end
    if otherComboBoxesOldValue[box.index] == selectedIndex then return end
    otherComboBoxesOldValue[box.index] = selectedIndex
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.onTargetBoxSelected(box, selectedIndex, arg)
    if box.selectedEntry == "" then return end -- it's empty target for 'Action' rows
    local rowIndex = rowByTargetComboBox[box.index]
    local target = targetsSorted[selectedIndex+1]
    if box.selectedEntry == "- Remove row" then
        ComplexCraftOrders.removeRow(rowIndex)
        return
    end
    if targetComboBoxesOldValue[rowIndex] == selectedIndex then return end
    targetComboBoxesOldValue[rowIndex] = selectedIndex
    
    local targetArgTextBox = targetArgTextBoxes[rowIndex]
    local targetArgComboBox = targetArgComboBoxes[rowIndex]
    targetArgTextBox.visible = false
    targetArgComboBox.visible = false
    
    local argData = targets[target].argument
    if argData then
        if type(argData) ~= "table" then
            targetArgComboBox.visible = false
            targetArgTextBox.text = arg and tostring(arg) or ""
            targetArgTextBox.visible = true
        else
            targetArgTextBox.visible = false
            targetArgComboBox:clear()
            for i = 1, #argData do
                targetArgComboBox:addEntry(argData[i])
            end
            if arg and tonumber(arg) > 0 then
                targetArgComboBox.selectedIndex = tonumber(arg)-1
            end
            targetArgComboBox.visible = true
        end
    end
    
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.onConditionBoxSelected(box, selectedIndex, arg)
    local rowIndex = rowByConditionComboBox[box.index]
    if conditionComboBoxesOldValue[rowIndex] == selectedIndex then return end
    conditionComboBoxesOldValue[rowIndex] = selectedIndex
    
    local conditionArgTextBox = conditionArgTextBoxes[rowIndex]
    local conditionArgComboBox = conditionArgComboBoxes[rowIndex]
    conditionArgTextBox.visible = false
    conditionArgComboBox.visible = false
    
    local argData
    if notComboBoxes[rowIndex].visible then -- it's Condition
        argData = conditions[conditionsSorted[selectedIndex+1]].argument
    else -- it's Action
        argData = actions[actionsSorted[selectedIndex+1]].argument
    end
    
    if argData then
        if type(argData) ~= "table" then
            conditionArgComboBox.visible = false
            conditionArgTextBox.text = arg and tostring(arg) or ""
            conditionArgTextBox.visible = true
        else
            conditionArgTextBox.visible = false
            conditionArgComboBox:clear()
            for i = 1, #argData do
                conditionArgComboBox:addEntry(argData[i])
            end
            if arg and tonumber(arg) > 0 then
                conditionArgComboBox.selectedIndex = tonumber(arg)-1
            end
            conditionArgComboBox.visible = true
        end
    end
    
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.onOperatorBoxSelected(box, selectedIndex, doNothing) -- performs various actions, sometimes does random stuff
    local rowIndex = rowByOperatorComboBox[box.index]
    if operatorComboBoxesOldValue[rowIndex] == selectedIndex then return end
    log(Level.Debug, "onOperatorBoxSelected - row %u, doNothing = %s, old = %s, new = %s", rowIndex,
      tostring, doNothing,
      tostring, operatorComboBoxesOldValue[rowIndex],
      tostring, selectedIndex)
    local oldValue = operatorComboBoxesOldValue[rowIndex] or 0
    operatorComboBoxesOldValue[rowIndex] = selectedIndex
    local deserialize = false

    if doNothing then
        currentOperatorValues[rowIndex] = selectedIndex
        return
    end

    local data = ComplexCraftOrders.serializeRules()
    currentOperatorValues[rowIndex] = selectedIndex

    if notComboBoxes[rowIndex].visible then -- it's Condition
        if selectedIndex == ConditionOperator.Action then
            if rowsUsed < config.maxRows then
                log(Level.Debug, " - isCondition, operator 'action'")
                table.insert(data.rules, rowIndex+1, {
                  action = actionsSorted[1],
                  operator = ActionOperator.None
                })
                deserialize = true
            else -- no rows left
                log(Level.Debug, " - isCondition, operator 'action', no rows left")
                Player():sendChatMessage("There are no empty rows left"%_t)
                operatorComboBoxes[rowIndex]:setSelectedIndexNoCallback(oldValue) -- change to the old value
                operatorComboBoxesOldValue[rowIndex] = oldValue
            end
        elseif oldValue == ConditionOperator.Action then -- change row from Action to Condition
            log(Level.Debug, " - isCondition, operator ~= 'action'")
            data.rules[rowIndex+1] = {
              target = targetsSorted[1],
              invert = 0,
              condition = conditionsSorted[1],
              operator = ConditionOperator.And
            }
            deserialize = true
        else
            isUnsaved = true
            applyLabel.color = ColorInt(0xffffff4d)
            ComplexCraftOrders.highlightBlock(rowIndex)
        end
    else -- it's Action
        if selectedIndex ~= ActionOperator.None and oldValue == ActionOperator.None then -- 'and'/'else' and there was no action before
            if rowsUsed < config.maxRows then
                log(Level.Debug, " - isAction, operator 'and'/'else'")
                table.insert(data.rules, rowIndex+1, {
                  action = actionsSorted[1],
                  operator = ActionOperator.None
                })
                deserialize = true
            else -- no rows left
                log(Level.Debug, " - isAction, operator 'and'/'else', no rows left")
                Player():sendChatMessage("There are no empty rows left"%_t)
                operatorComboBoxes[rowIndex]:setSelectedIndexNoCallback(ActionOperator.None) -- change to ''
                operatorComboBoxesOldValue[rowIndex] = ActionOperator.None
            end
        elseif selectedIndex == ActionOperator.Else and oldValue == ActionOperator.And then -- trying to switch from 'and' to 'else', need to check if there already 'else' in current block
            local canUseElse = true
            for i = rowIndex-1, 2, -1 do
                if notComboBoxes[i].visible then break end -- no more actions in this block
                if operatorComboBoxes[i].selectedIndex == ActionOperator.Else then
                    canUseElse = false
                    break
                end
            end
            log(Level.Debug, " - isAction, 'and' -> 'else', can use 'else' - %s", tostring, canUseElse)
            if not canUseElse then
                operatorComboBoxes[rowIndex]:setSelectedIndexNoCallback(ActionOperator.And) -- change to 'and'
                operatorComboBoxesOldValue[rowIndex] = ActionOperator.And
            else
                isUnsaved = true
                applyLabel.color = ColorInt(0xffffff4d)
                ComplexCraftOrders.highlightBlock(rowIndex)
            end
        elseif selectedIndex == ActionOperator.None and oldValue ~= ActionOperator.None then -- remove action
            log(Level.Debug, " - isAction, operator 'and'/'else' -> '', remove action")
            data.rules[rowIndex+1].action = nil
            deserialize = true
        else
            isUnsaved = true
            applyLabel.color = ColorInt(0xffffff4d)
            ComplexCraftOrders.highlightBlock(rowIndex)
        end
    end

    if deserialize then
        ComplexCraftOrders.clear()
        ComplexCraftOrders.deserializeRules(ComplexCraftOrders.fixRules(data))
    end
end

-- Functions

function ComplexCraftOrders.receiveSettings(settings, configs)
    log(Level.Debug, "receiveSettings: %s\n %s", table_export, settings, table_export, configs)
    if configs then
        if config.version.string ~= settings.version then -- versions are not matching
            log(Level.Error, "Client mod version (%s) is different from the server version (%s)", config.version.string, settings.version)
            leftRowsLabel.tooltip = format("Your mod version (%s) is different from the server version (%s). Please install the correct version", config.version.string, settings.version)
            leftRowsLabel.color = ColorInt(0xffff2626)
            return
        elseif config.maxRows < configs.maxRows then -- if client created less rows than server supports, we may lose some data
            log(Level.Warn, "Client 'maxRows' setting(%s) is less than the server setting (%s)", config.maxRows, configs.maxRows)
            leftRowsLabel.tooltip = format("Your 'maxRows' setting is less than the server setting (%s). Please adjust it, otherwise you may lose some rules data", configs.maxRows)
            leftRowsLabel.color = ColorInt(0xffffff4d)
        else
            config.maxRows = configs.maxRows
        end

        targets = configs.targets
        conditions = configs.conditions
        actions = configs.actions

        for k, v in pairs(targets) do
            targetsSorted[#targetsSorted+1] = k
        end
        for k, v in pairs(conditions) do
            conditionsSorted[#conditionsSorted+1] = k
        end
        for k, v in pairs(actions) do
            actionsSorted[#actionsSorted+1] = k
        end
        -- TODO: Add UTF8 support and localization
        table.sort(targetsSorted)
        table.sort(conditionsSorted)
        table.sort(actionsSorted)
        for i = 1, #targetsSorted do
            targetSortedIndexes[targetsSorted[i]] = i
        end
        for i = 1, #conditionsSorted do
            conditionSortedIndexes[conditionsSorted[i]] = i
        end
        for i = 1, #actionsSorted do
            actionSortedIndexes[actionsSorted[i]] = i
        end
        
        isSettingsLoaded = true
    end
    if settings.rules then
        ComplexCraftOrders.clear()
        ComplexCraftOrders.deserializeRules(settings)
        settingsPrevious = settings
    end
    toggleCheckBox.checked = settings.toggle
    settingsPrevious.toggle = settings.toggle
    isUnsaved = false
    applyLabel.color = ColorInt(0xffe0e0e0)
end

function ComplexCraftOrders.removeRow(rowIndex)
    local data = ComplexCraftOrders.serializeRules()
    data.rules[rowIndex].target = nil
    data.rules[rowIndex].action = nil
    ComplexCraftOrders.clear()
    ComplexCraftOrders.deserializeRules(ComplexCraftOrders.fixRules(data))
end

function ComplexCraftOrders.addConditionRow(index, row)
    local target = 0
    local condition = 0
    if not row then
        row = {
          invert = 0,
          operator = ConditionOperator.And
        }
    else
        target = targetSortedIndexes[row.target]-1
        condition = conditionSortedIndexes[row.condition]-1
    end

    -- Target
    local targetComboBox = targetComboBoxes[index]
    targetComboBox:clear()
    for j = 1, #targetsSorted do
        targetComboBox:addEntry(targetsSorted[j])
    end
    targetComboBox:addEntry("- Remove row")
    targetComboBox:setSelectedIndexNoCallback(target)
    targetComboBox.visible = true
    ComplexCraftOrders.onTargetBoxSelected(targetComboBox, target, row.argTarget)

    -- Not
    notComboBoxes[index].selectedIndex = row.invert
    notComboBoxes[index].visible = true

    -- Condition
    local conditionComboBox = conditionComboBoxes[index]
    conditionComboBox:clear()
    for i = 1, #conditionsSorted do
        conditionComboBox:addEntry(conditionsSorted[i])
    end
    conditionComboBox:setSelectedIndexNoCallback(condition)
    conditionComboBox.visible = true
    ComplexCraftOrders.onConditionBoxSelected(conditionComboBox, condition, row.argCondition)

    -- Operator
    local operatorComboBox = operatorComboBoxes[index]
    operatorComboBox:clear()
    for i = 1, #conditionOperators do
        operatorComboBox:addEntry(conditionOperators[i])
    end
    operatorComboBox:setSelectedIndexNoCallback(row.operator)
    operatorComboBox.visible = true
    ComplexCraftOrders.onOperatorBoxSelected(operatorComboBox, row.operator, true)
    
    -- Don't show "Insert Row" button for last row
    if index < config.maxRows then
        insertRowButtons[index].visible = true
    end
end

function ComplexCraftOrders.addActionRow(index, row)
    local action = 0
    if not row then
        row = {
          operator = ActionOperator.None
        }
    else
        action = actionSortedIndexes[row.action]-1
    end

    -- Target (used to remove row)
    local targetComboBox = targetComboBoxes[index]
    targetComboBox:clear()
    targetComboBox:addEntry("")
    targetComboBox:addEntry("- Remove row")
    targetComboBox.visible = true

    -- Action
    local conditionComboBox = conditionComboBoxes[index]
    conditionComboBox:clear()
    for i = 1, #actionsSorted do
        conditionComboBox:addEntry(actionsSorted[i])
    end
    conditionComboBox:setSelectedIndexNoCallback(action)
    conditionComboBox.visible = true
    ComplexCraftOrders.onConditionBoxSelected(conditionComboBox, action, row.argAction)

    -- Operator
    local operatorComboBox = operatorComboBoxes[index]
    operatorComboBox:clear()
    for i = 1, #actionOperators do
        operatorComboBox:addEntry(actionOperators[i])
    end
    operatorComboBox:setSelectedIndexNoCallback(row.operator)
    operatorComboBox.visible = true
    ComplexCraftOrders.onOperatorBoxSelected(operatorComboBox, row.operator, true)
    
    if index < config.maxRows then
        insertRowButtons[index].visible = true
    end
end

function ComplexCraftOrders.clear(rowStart)
    targetComboBoxesOldValue = {}
    conditionComboBoxesOldValue = {}
    operatorComboBoxesOldValue = {}
    otherComboBoxesOldValue = {}
    for i = rowStart or 1, rowsUsed do
        targetComboBoxes[i].visible = false
        targetArgComboBoxes[i].visible = false
        targetArgTextBoxes[i].visible = false
        notComboBoxes[i].visible = false
        conditionComboBoxes[i].visible = false
        conditionArgComboBoxes[i].visible = false
        conditionArgTextBoxes[i].visible = false
        operatorComboBoxes[i].visible = false
        insertRowButtons[i].visible = false
        rowLines[i].visible = false
        connectorLines[i].visible = false
        separatorLines[i].visible = false
    end
    rowsUsed = 0
    leftRowsLabel.caption = format("%u/%u rows used"%_t, 0, config.maxRows)
    
    -- move empty space
    local lastRow = targetComboBoxes[rowsUsed] or { upper = vec2(0,0) }
    emptySpace.rect = Rect(lastRow.upper + vec2(0, 10), lastRow.upper + vec2(0, 310))
    
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.serializeRules()
    local rules = {}
    local row, argData
    local nextAction = false
    for i = 1, rowsUsed do
        row = {}
        if not nextAction then -- is condition
            row.target = targetsSorted[targetComboBoxes[i].selectedIndex+1]
            argData = row.target and targets[row.target].argument
            if argData then
                row.argTarget = argData ~= true and targetArgComboBoxes[i].selectedIndex+1 or targetArgTextBoxes[i].text
            end
            row.invert = notComboBoxes[i].selectedIndex
            row.condition = conditionsSorted[conditionComboBoxes[i].selectedIndex+1]
            argData = conditions[row.condition].argument
            if argData then
                row.argCondition = argData ~= true and conditionArgComboBoxes[i].selectedIndex+1 or conditionArgTextBoxes[i].text
            end
            row.operator = operatorComboBoxes[i].selectedIndex
            
            nextAction = (currentOperatorValues[i] or ConditionOperator.And) == ConditionOperator.Action
        else
            row.action = actionsSorted[conditionComboBoxes[i].selectedIndex+1]
            argData = actions[row.action].argument
            if argData then
                row.argAction = argData ~= true and conditionArgComboBoxes[i].selectedIndex+1 or conditionArgTextBoxes[i].text
            end
            row.operator = operatorComboBoxes[i].selectedIndex
            
            nextAction = (currentOperatorValues[i] or ActionOperator.None) ~= ActionOperator.None
        end
        rules[#rules+1] = row
    end
    return {
      version = config.version.string,
      rules = rules
    }
end

function ComplexCraftOrders.deserializeRules(data) -- turn data into UI
    if not data or not data.rules or #data.rules == 0 then return end

    local rules = data.rules
    local row
    local isElseBranch = false
    for i = 1, #rules do
        row = rules[i]
        if row.action then
            ComplexCraftOrders.addActionRow(i, row)
            if row.operator == ActionOperator.None then -- last action in block = end of block
                separatorLines[i].visible = true
                rowsUsed = i
                ComplexCraftOrders.highlightBlock(i)
            end
        else
            ComplexCraftOrders.addConditionRow(i, row)
        end
    end
    rowsUsed = #rules
    leftRowsLabel.caption = format("%u/%u rows used"%_t, rowsUsed, config.maxRows)
    
    -- move empty space
    local lastRow = targetComboBoxes[rowsUsed]
    emptySpace.rect = Rect(lastRow.upper + vec2(0, 10), lastRow.upper + vec2(0, 310))
    
    -- show lines
    
    isUnsaved = true
    applyLabel.color = ColorInt(0xffffff4d)
end

function ComplexCraftOrders.highlightBlock(anyRowIndex) -- reapplies lines to block
    local start = 1
    -- search start of the block
    local stage = notComboBoxes[anyRowIndex].visible and 0 or 1
    for i = anyRowIndex, 1, -1 do
        if stage == 1 and notComboBoxes[i].visible then -- found last Condition
            stage = 0
        elseif stage == 0 and not notComboBoxes[i].visible then -- found end of the previous block
            start = i+1
            break
        end
    end
    -- get group number and the amount of conditions in each group
    local groupsWithoutYellow = 0 -- groups where yellow lines will be replaced with gray
    local groups = 1
    local groupConditionCount = {0}
    for i = start, rowsUsed do
        if not notComboBoxes[i].visible then -- action
            if groupConditionCount[groups] > 1 then
                groupsWithoutYellow = groups - 1
            end
            break
        end
        groupConditionCount[groups] = groupConditionCount[groups] + 1
        if operatorComboBoxes[i].selectedIndex == ConditionOperator.Or then
            if groupConditionCount[groups] > 1 then
                groupsWithoutYellow = groups - 1
            end
            groups = groups + 1
            groupConditionCount[groups] = 0
        end
    end

    local isElseBranch = false
    local groupStart
    for i = start, rowsUsed do
        if not notComboBoxes[i].visible then -- action
            groupStart = nil
            rowLines[i].color = isElseBranch and ColorInt(0xffb2b370) or ColorInt(0xff7270b3)
            rowLines[i].visible = true
            connectorLines[i].visible = false
            if not isElseBranch then
                isElseBranch = operatorComboBoxes[i].selectedIndex == ActionOperator.Else
            end
        else -- condition
            isElseBranch = false
            if groupStart == nil then
                groupStart = i
            end
            if groupStart and operatorComboBoxes[i].selectedIndex ~= ConditionOperator.And then -- 'or'/'action'
                rowLines[i].color = ColorInt(0xff7270b3)
                rowLines[i].visible = true
                connectorLines[i].visible = false
                for j = groupStart, i-1 do
                    if groupsWithoutYellow > 0 then
                        rowLines[j].color = ColorInt(0xff9c9bb3)
                        connectorLines[j].color = j+1 < i and ColorInt(0xff9c9bb3) or ColorInt(0xff7270b3)
                    else
                        rowLines[j].color = ColorInt(0xffb2b370)
                        connectorLines[j].color = j+1 < i and ColorInt(0xffb2b370) or ColorInt(0xff7270b3)
                    end
                    rowLines[j].visible = true
                    connectorLines[j].visible = true
                end
                groupStart = i+1
                groupsWithoutYellow = groupsWithoutYellow - 1
            end
        end
    end
end


end
end