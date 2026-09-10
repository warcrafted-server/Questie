---@class AutoRoute
local AutoRoute = QuestieLoader:CreateModule("AutoRoute")

---@type TrackerUtils
local TrackerUtils = QuestieLoader:ImportModule("TrackerUtils")
---@type QuestieMap
local QuestieMap = QuestieLoader:ImportModule("QuestieMap")
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer")
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib")

local tinsert, tremove = table.insert, table.remove

-- Quests this far above the player's level are treated as unreachable rather than
-- merely expensive, so they never win on proximity alone.
local LEVEL_ABOVE_CUTOFF = 5

-- Yard cost added per level of mismatch. Roughly "one level of difference is worth
-- walking this much further", which is what keeps a grey quest next door from
-- outranking an on-level quest one zone over.
local YARDS_PER_LEVEL_ABOVE = 900
local YARDS_PER_LEVEL_BELOW = 220

local UNREACHABLE = math.huge

---@return QuestId[]
local function _GetRoute()
    return Questie.db.char.autoRouteOrder or {}
end

---Returns the route position of a quest, or nil when it is not part of the route.
---@param questId QuestId
---@return number?
function AutoRoute.GetRoutePosition(questId)
    for position, routeQuestId in ipairs(_GetRoute()) do
        if routeQuestId == questId then
            return position
        end
    end
end

---@param questId QuestId
---@return boolean
function AutoRoute.IsInRoute(questId)
    return AutoRoute.GetRoutePosition(questId) ~= nil
end

---Appends a quest to the end of the route.
---@param questId QuestId
function AutoRoute.AddToRoute(questId)
    if AutoRoute.IsInRoute(questId) then
        return
    end

    local route = _GetRoute()
    tinsert(route, questId)
    Questie.db.char.autoRouteOrder = route

    AutoRoute.Update(true)
end

---@param questId QuestId
function AutoRoute.RemoveFromRoute(questId)
    local route = _GetRoute()
    local position = AutoRoute.GetRoutePosition(questId)
    if not position then
        return
    end

    tremove(route, position)
    Questie.db.char.autoRouteOrder = route

    AutoRoute.Update(true)
end

---Moves a quest one step towards the front (delta -1) or back (delta 1) of the route.
---@param questId QuestId
---@param delta number
function AutoRoute.MoveInRoute(questId, delta)
    local route = _GetRoute()
    local position = AutoRoute.GetRoutePosition(questId)
    if not position then
        return
    end

    local target = position + delta
    if target < 1 or target > #route then
        return
    end

    route[position], route[target] = route[target], route[position]
    Questie.db.char.autoRouteOrder = route

    AutoRoute.Update(true)
end

function AutoRoute.ClearRoute()
    Questie.db.char.autoRouteOrder = {}
    AutoRoute.Update(true)
end

---Level-weighted travel cost for a quest, in yards. Lower is better.
---@param questId QuestId
---@param distance number
---@return number
local function _ScoreQuest(questId, distance)
    local playerLevel = QuestiePlayer.GetPlayerLevel()
    -- Resolves the -1 "scales to player" level, so those quests score as on-level.
    local questLevel = QuestieLib.GetEffectiveQuestLevel(questId, playerLevel)
    if not questLevel or questLevel == 0 then
        return distance
    end

    local difference = questLevel - playerLevel

    if difference > LEVEL_ABOVE_CUTOFF then
        return UNREACHABLE
    end

    if difference > 0 then
        return distance + difference * YARDS_PER_LEVEL_ABOVE
    end

    return distance - difference * YARDS_PER_LEVEL_BELOW
end

---Picks the quest the player should head to next, preferring the manual route.
---@return Quest? quest
---@return table? spawn
---@return AreaId? zone
---@return string? name
local function _PickNextQuest()
    local questLog = QuestiePlayer.currentQuestlog or {}

    for _, questId in ipairs(_GetRoute()) do
        local quest = questLog[questId]
        if quest then
            local spawn, zone, name = QuestieMap:GetNearestQuestSpawn(quest)
            if spawn then
                return quest, spawn, zone, name
            end
        end
    end

    local bestQuest, bestSpawn, bestZone, bestName
    local bestScore = UNREACHABLE

    for questId, quest in pairs(questLog) do
        if not Questie.db.char.AutoUntrackedQuests[questId] then
            local spawn, zone, name, _, _, distance = QuestieMap:GetNearestQuestSpawn(quest)
            if spawn then
                local score = _ScoreQuest(questId, distance)
                if score < bestScore then
                    bestScore = score
                    bestQuest = quest
                    bestSpawn = spawn
                    bestZone = zone
                    bestName = name
                end
            end
        end
    end

    return bestQuest, bestSpawn, bestZone, bestName
end

---Re-picks the auto-route target and moves the TomTom arrow to it.
---@param force boolean? @Retarget even when the current target is still valid.
function AutoRoute.Update(force)
    if not Questie.db.profile.autoRouteEnabled then
        return
    end

    local quest, spawn, zone, name = _PickNextQuest()
    if (not quest) or (not spawn) or (not zone) then
        return
    end

    -- A waypoint the player set by hand outranks the automatic pick until the quest it
    -- points at is gone (completed, turned in or abandoned), which clears it elsewhere.
    local current = Questie.db.char._tom_waypoint_quest
    if (not force) and current and QuestiePlayer.currentQuestlog[current.questId] then
        return
    end

    Questie.Debug(Questie.DEBUG_DEVELOP, "[AutoRoute] Targeting quest", quest.Id, name)
    TrackerUtils:SetTomTomTarget(name, zone, spawn[1], spawn[2], quest.Id)
end
