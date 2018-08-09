local random = math.random
local randomseed = math.randomseed
local huge = math.huge
local match = string.match

-- Temp Escort/Follow fix
local isEscorting = true

-- API
local api

local function initialize(modAPI)
    api = modAPI
end

-- Helpers

local Argument = { Any = 1, Ship = 2, Station = 3 }

-- CraftOrders helpers

local AIAction =
{
  Escort = 1,
  Attack = 2,
  FlyThroughWormhole = 3,
  FlyToPosition = 4,
  Guard = 5,
  Patrol = 6,
  Aggressive = 7,
  Mine = 8,
  Salvage = 9
}

local function removeSpecialOrders()
    local entity = Entity()
    for index, name in pairs(entity:getScripts()) do
        if string.match(name, "/scripts/entity/ai/") then
            entity:removeScript(index)
        end
    end
end

local function fakeCallingPlayer() -- pretend that commands are given by the owner of the ship / leader of the alliance
    local entity = Entity()
    if entity.playerOwned then
        callingPlayer = entity.factionIndex
    elseif entity.allianceOwned then
        callingPlayer = Alliance(entity.factionIndex).leader
    end
end

-- Targets

local function targetSelf()
    api:log(api.Level.Debug, "targetSelf")
    return Entity()
end

local function targetAnyAlly(sector, arg)
    local selfIndex = Entity().index
    local faction = Faction()
    local entities, entity
    if arg ~= Argument.Station then -- 'ship' or ''
        entities = {sector:getEntitiesByType(EntityType.Ship)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
                api:log(api.Level.Debug, "targetAnyAlly(ship)")
                return entity
            end
        end
    end
    if arg ~= Argument.Ship then -- 'station' or ''
        entities = {sector:getEntitiesByType(EntityType.Station)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
                api:log(api.Level.Debug, "targetAnyAlly(station)")
                return entity
            end
        end
    end
    api:log(api.Level.Debug, "targetAnyAlly - nobody")
end

local function targetAnyEnemy(sector, arg)
    if arg == Argument.Any then
        local enemy = sector:getEnemies(Faction().index)
        api:log(api.Level.Debug, "targetAnyEnemy(any) - %s", tostring, enemy)
        return enemy
    end
    local entities = {sector:getEnemies(Faction().index)}
    local entity
    for i = 1, #entities do
        entity = entities[i]
        if(arg == Argument.Ship and entity.isShip) or (arg == Argument.Station and entity.isStation) then
            api:log(api.Level.Debug, "targetAnyEnemy")
            return entity
        end
    end
    api:log(api.Level.Debug, "targetAnyEnemy - nobody")
end

local function targetNearestAlly(sector, arg)
    local self = Entity()
    local faction = Faction()
    local entities, entity, distance, nearestAlly
    local nearestDistance = huge
    if arg ~= Argument.Station then -- 'ship' or ''
        entities = {sector:getEntitiesByType(EntityType.Ship)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= self.index and faction:getRelations(entity.factionIndex) > 40000 then
                distance = self:getNearestDistance(entity)
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestAlly = entity
                end
            end
        end
        if arg == Argument.Ship then
            api:log(api.Level.Debug, "targetNearestAlly(ship) - %s", tostring, nearestAlly)
            return nearestAlly
        end
    end
    -- 'station' or ''
    entities = {sector:getEntitiesByType(EntityType.Station)}
    for i = 1, #entities do
        entity = entities[i]
        if entity.index ~= self.index and faction:getRelations(entity.factionIndex) > 40000 then
            distance = self:getNearestDistance(entity)
            if distance < nearestDistance then
                nearestDistance = distance
                nearestAlly = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetNearestAlly - %s", tostring, nearestAlly)
    return nearestAlly
end

local function targetNearestEnemy(sector, arg)
    if arg == Argument.Any then
        local enemy = ShipAI():getNearestEnemy(-40000)
        api:log(api.Level.Debug, "targetNearestEnemy(any) - %s", tostring, enemy)
        return enemy
    end
    local self = Entity()
    local entities = {sector:getEnemies(Faction().index)}
    local nearestEnemy, entity, distance
    local nearestDistance = huge
    for i = 1, #entities do
        local entity = entities[i]
        if arg == 1 or (arg == 2 and entity.isShip) or (arg == 3 and entity.isStation) then
            distance = self:getNearestDistance(entity)
            if distance < nearestDistance then
                nearestDistance = distance
                nearestEnemy = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetNearestEnemy - %s", tostring, nearestEnemy)
    return nearestEnemy
end

local function targetMostHurtAlly(sector, arg) -- most hurt in terms of health percentage, not an actual value
    local selfIndex = Entity().index
    local faction = Faction()
    local entities, entity, ratio, mostHurtAlly
    local minHp = 2
    if arg ~= Argument.Station then -- 'ship' or ''
        entities = {sector:getEntitiesByType(EntityType.Ship)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
                ratio = entity.durability / entity.maxDurability
                if ratio < minHp then
                    minHp = ratio
                    mostHurtAlly = entity
                end
            end
        end
        if arg == Argument.Ship then
            api:log(api.Level.Debug, "targetMostHurtAlly(ship) - %s", tostring, mostHurtAlly)
            return mostHurtAlly
        end
    end
    -- 'station' or ''
    entities = {sector:getEntitiesByType(EntityType.Station)}
    for i = 1, #entities do
        entity = entities[i]
        if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
            ratio = entity.durability / entity.maxDurability
            if ratio < minHp then
                 minHp = ratio
                mostHurtAlly = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetMostHurtAlly - %s", tostring, mostHurtAlly)
    return mostHurtAlly
end

local function targetMostHurtEnemy(sector, arg)
    local entities = {sector:getEnemies(Faction().index)}
    local hurtEnemy, entity, ratio
    local minHp = 2
    for i = 1, #entities do
        local entity = entities[i]
        if arg == Argument.Any or (arg == Argument.Ship and entity.isShip) or (arg == Argument.Station and entity.isStation) then
            ratio = entity.durability / entity.maxDurability
            if ratio < minHp then
                minHp = ratio
                hurtEnemy = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetMostHurtEnemy - %s", tostring, hurtEnemy)
    return hurtEnemy
end

local function targetLeastHurtAlly(sector, arg)
    local selfIndex = Entity().index
    local faction = Faction()
    local entities
    local entity, ratio, leastHurtAlly
    local maxHp = 0
    if arg ~= Argument.Station then -- 'ship' or ''
        entities = {sector:getEntitiesByType(EntityType.Ship)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
                ratio = entity.durability / entity.maxDurability
                if ratio > maxHp then
                    maxHp = ratio
                    leastHurtAlly = entity
                end
            end
        end
        if arg == Argument.Ship then
            api:log(api.Level.Debug, "targetLeastHurtAlly(ship) - %s", tostring, leastHurtAlly)
            return leastHurtAlly
        end
    end
    -- 'station' or ''
    entities = {sector:getEntitiesByType(EntityType.Station)}
    for i = 1, #entities do
        entity = entities[i]
        if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
            ratio = entity.durability / entity.maxDurability
            if ratio > maxHp then
                maxHp = ratio
                leastHurtAlly = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetLeastHurtAlly - %s", tostring, leastHurtAlly)
    return leastHurtAlly
end

local function targetLeastHurtEnemy(sector, arg)
    local entities = {sector:getEnemies(Faction().index)}
    local hurtEnemy, entity, ratio
    local maxHp = 0
    for i = 1, #entities do
        local entity = entities[i]
        if arg == Argument.Any or (arg == Argument.Ship and entity.isShip) or (arg == Argument.Station and entity.isStation) then
            ratio = entity.durability / entity.maxDurability
            if ratio > maxHp then
                maxHp = ratio
                hurtEnemy = entity
            end
        end
    end
    api:log(api.Level.Debug, "targetLeastHurtEnemy - %s", tostring, hurtEnemy)
    return hurtEnemy
end

local function targetRandomAlly(sector, arg)
    randomseed(appTimeMs()) -- for some reason randomseed doesn't work if it's placed outside of the function
    local selfIndex = Entity().index
    local faction = Faction()
    local entities, entity
    local ships = {}
    local stations = {}
    local rand
    if arg ~= Argument.Station then --ship or ''
        entities = {sector:getEntitiesByType(EntityType.Ship)}
        for i = 1, #entities do
            entity = entities[i]
            if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
                ships[#ships+1] = entity
            end
        end
        if arg == Argument.Ship then -- ship
            rand = #ships > 0 and ships[random(#ships)]
            api:log(api.Level.Debug, "targetRandomAlly(ship) - %s", tostring, rand)
            return rand
        end
    end
    --station or ''
    entities = {sector:getEntitiesByType(EntityType.Station)}
    for i = 1, #entities do
        entity = entities[i]
        if entity.index ~= selfIndex and faction:getRelations(entity.factionIndex) > 40000 then
            stations[#stations+1] = entity
        end
    end
    if arg == Argument.Station then -- station
        rand = #stations > 0 and stations[random(#stations)]
        api:log(api.Level.Debug, "targetRandomAlly(station) - %s", tostring, rand)
        return rand
    end
    local totalLen = #ships + #stations
    if totalLen == 0 then
        api:log(api.Level.Debug, "targetRandomAlly(any) - nobody")
        return
    end
    totalLen = random(totalLen)
    if totalLen > #ships then
        rand = stations[totalLen-#ships]
        api:log(api.Level.Debug, "targetRandomAlly(any, station) - %s", tostring, rand)
        return rand
    end
    rand = ships[totalLen]
    api:log(api.Level.Debug, "targetRandomAlly(any, ships) - %s", tostring, rand)
    return rand
end

local function targetRandomEnemy(sector, arg)
    randomseed(appTimeMs()) -- for some reason randomseed doesn't work if it's placed outside of the function
    local enemies = {sector:getEnemies(Faction().index)}
    local rand
    if arg == Argument.Any then
        rand = #enemies > 0 and enemies[random(#enemies)]
        api:log(api.Level.Debug, "targetRandomEnemy(any) - %s", tostring, rand)
        return rand
    end
    local certainEnemies = {}
    local entity
    for i = 1, #enemies do
        entity = enemies[i]
        if (arg == Argument.Ship and entity.isShip) or (arg == Argument.Station and entity.isStation) then
            certainEnemies[#certainEnemies+1] = entity
        end
    end
    rand = #certainEnemies > 0 and certainEnemies[random(#certainEnemies)]
    api:log(api.Level.Debug, "targetRandomEnemy - %s", tostring, rand)
    return rand
end

-- Conditions

local function conditionInSector(target) -- accepts nil target, gives false if target is nil, true otherwise
    api:log(api.Level.Debug, "conditionInSector = %s", tostring, target)
    return target ~= nil
end

local function conditionHealthLessThan(target, arg)
    arg = tonumber(arg) or 0
    local result = target.durability / target.maxDurability < arg / 100
    api:log(api.Level.Debug, "conditionHealthLessThan < %s => %s", tostring, arg, tostring, result)
    return result
end

local function conditionShieldLessThan(target, arg)
    arg = tonumber(arg) or 0
    local result = target.shieldDurability / target.shieldMaxDurability < arg / 100
    api:log(api.Level.Debug, "conditionShieldLessThan < %s => %s", tostring, arg, tostring, result)
    return result
end

local function conditionDistanceLessThan(target, arg)
    arg = tonumber(arg) or 0
    local result = Entity():getNearestDistance(target) * 10 < arg
    api:log(api.Level.Debug, "conditionDistanceLessThan < %s => %s", tostring, arg, tostring, result)
    return result
end

local function conditionWithChance(target, arg)
    arg = tonumber(arg) or 0
    randomseed(appTimeMs()) -- for some reason randomseed doesn't work if it's placed outside of the function
    local result = random() < arg / 100
    api:log(api.Level.Debug, "conditionWithChance '%s' => %s", tostring, arg, tostring, result)
    return result
end

local function conditionAtCoordinates(target, arg)
    if not arg then return end
    local x, y = match(tostring(arg), "(-?%d+)[,;/ ](-?%d+)")
    local sx, sy = Sector():getCoordinates()
    return x == sx and y == sy
end

-- Actions

local function actionIdle()
    fakeCallingPlayer()
    CraftOrders.onIdleButtonPressed()
    callingPlayer = nil
end

local function actionPassive()
    fakeCallingPlayer()
    CraftOrders.stopFlying()
    callingPlayer = nil
end

local function actionGuardPosition()
    if CraftOrders.targetAction ~= AIAction.Guard then -- apply only if ship is not in the guard mode already
        fakeCallingPlayer()
        if CraftOrders.guardPosition then -- 0.18.2+
            CraftOrders.guardPosition(Entity().translationf)
        else -- 0.17.1+
            CraftOrders.onGuardButtonPressed()
        end
        callingPlayer = nil
    end
end

local function actionEscortTarget(target)
    if not target then return end
    -- apply only if ship is not escorting or escorting different target
    if CraftOrders.targetAction ~= AIAction.Escort or not isEscorting or CraftOrders.targetIndex ~= target.index then
        fakeCallingPlayer()
        isEscorting = true -- temp fix to distinguish escort/follow
        CraftOrders.escortEntity(target.index)
        callingPlayer = nil
    end
end

local function actionFollowTarget(target)
    if not target then return end
    if CraftOrders.targetAction ~= AIAction.Escort or isEscorting or CraftOrders.targetIndex ~= target.index then
        fakeCallingPlayer()
        isEscorting = false -- temp fix to distinguish escort/follow
        removeSpecialOrders()
        ShipAI():setFollow(target)
        CraftOrders.setAIAction(AIAction.Escort, target.index)
        callingPlayer = nil
    end
end

local function actionAttackTarget(target)
    if not target then return end
    if CraftOrders.targetAction ~= AIAction.Attack or CraftOrders.targetIndex ~= target.index then
        fakeCallingPlayer()
        CraftOrders.attackEntity(target.index)
        callingPlayer = nil
    end
end

local function actionAggressive()
    if CraftOrders.targetAction ~= AIAction.Aggressive then
        fakeCallingPlayer()
        if CraftOrders.attackEnemies then -- 0.18.2+
            CraftOrders.attackEnemies()
        else -- 0.17.1+
            CraftOrders.onAttackEnemiesButtonPressed()
        end
        callingPlayer = nil
    end
end

local function actionPatrol()
    if CraftOrders.targetAction ~= AIAction.Patrol then
        fakeCallingPlayer()
        if CraftOrders.patrolSector then -- 0.18.2+
            CraftOrders.patrolSector()
        else -- 0.17.1+
            CraftOrders.onPatrolButtonPressed()
        end
        callingPlayer = nil
    end
end

local function actionMine()
    if CraftOrders.targetAction ~= AIAction.Mine then
        fakeCallingPlayer()
        if CraftOrders.mine then -- 0.18.2+
            CraftOrders.mine()
        else -- 0.17.1+
            CraftOrders.onMineButtonPressed()
        end
        callingPlayer = nil
    end
end

local function actionSalvage()
    if CraftOrders.targetAction ~= AIAction.Salvage then
        fakeCallingPlayer()
        CraftOrders.onSalvageButtonPressed()
        callingPlayer = nil
    end
end

local function actionTogglePassiveShooting(target, arg)
    ShipAI():setPassiveShooting(arg == 1) -- 1 is 'On', 2 is 'Off' (table indexes)
end

local function actionJumpTo(target, arg)
    if not arg then return end
    local x, y = match(tostring(arg), "(-?%d+)[,;/ ](-?%d+)")
    if not x or not y then return end
    fakeCallingPlayer()
    removeSpecialOrders()
    ShipAI():setJump(tonumber(x), tonumber(y))
    CraftOrders.setAIAction(AIAction.FlyThroughWormhole)
    callingPlayer = nil
end
--


return {
  -- Init
  initialize = initialize,
  -- Who
  Target = {
    ["Self"] = {
      func = targetSelf,
      -- cache = true by default, will save result of a function for other condition blocks in current update
    },
    ["Any Ally"] = {
      func = targetAnyAlly,
      argument = { "", "Ship", "Station" } -- if you specify a table, CCO will create a ListBox instead of TextBox
    },
    ["Any Enemy"] = {
      func = targetAnyEnemy,
      argument = { "", "Ship", "Station" }
    },
    ["Nearest Ally"] = {
      func = targetNearestAlly,
      argument = { "", "Ship", "Station" }
    },
    ["Nearest Enemy"] = {
      func = targetNearestEnemy,
      argument = { "", "Ship", "Station" }
    },
    ["Most Hurt Ally"] = {
      func = targetMostHurtAlly,
      argument = { "", "Ship", "Station" }
    },
    ["Most Hurt Enemy"] = {
      func = targetMostHurtEnemy,
      argument = { "", "Ship", "Station" }
    },
    ["Least Hurt Ally"] = {
      func = targetLeastHurtAlly,
      argument = { "", "Ship", "Station" }
    },
    ["Least Hurt Enemy"] = {
      func = targetLeastHurtEnemy,
      argument = { "", "Ship", "Station" }
    },
    ["Random Ally"] = {
      func = targetRandomAlly,
      argument = { "", "Ship", "Station" },
      cache = false
    },
    ["Random Enemy"] = {
      func = targetRandomEnemy,
      argument = { "", "Ship", "Station" },
      cache = false
    }
  },
  -- When
  Condition = {
    ["In Sector"] = {
      func = conditionInSector,
      acceptsNil = true
    },
    ["Health Less Than"] = {
      func = conditionHealthLessThan,
      --acceptsNil = false -- by default mod doesn't check condition if target is nil
      argument = true -- has one argument - health percentage, will create TextBox
    },
    ["Shield Less Than"] = {
      func = conditionShieldLessThan,
      argument = true
    },
    ["With Chance"] = {
      func = conditionWithChance,
      argument = true,
      cache = false
    },
    ["Distance Less Than"] = {
      func = conditionDistanceLessThan,
      argument = true
    },
    ["At Coordinates"] = {
      func = conditionInSector,
      argument = true
    }
  },
  -- What to do
  Action = {
    ["Idle"] = {
      func = actionIdle
    },
    ["Passive"] = {
      func = actionPassive
    },
    ["Guard Position"] = {
      func = actionGuardPosition
    },
    ["Follow Target"] = {
      func = actionFollowTarget
    },
    ["Escort Target"] = {
      func = actionEscortTarget
    },
    ["Attack Target"] = {
      func = actionAttackTarget
    },
    ["Aggressive"] = {
      func = actionAggressive
    },
    ["Patrol"] = {
      func = actionPatrol
    },
    ["Mine"] = {
      func = actionMine
    },
    ["Salvage"] = {
      func = actionSalvage
    },
    ["Toggle Passive Shooting"] = {
      func = actionTogglePassiveShooting,
      argument = { "On", "Off" }
    },
    ["Jump To"] = {
      func = actionJumpTo,
      argument = true
    }
  }
}