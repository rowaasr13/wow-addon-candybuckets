if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
	return
end

---@alias CandyBucketsModuleName "brewfest"|"hallow"|"lunar"|"midsummer"

---@class CandyBucketsNS : table
---@field public modules table<CandyBucketsModuleName, CandyBucketsModule>
---@field public uimaps table<number, UiMapDetails[]>

---@class CandyBucketsQuest : table
---@field public quest number
---@field public side number `1` = Alliance, `2` = Horde, `3` = Neutral
---@field public extra? number
---@field public style? number `1` = Circle (Default), `2` = No Border and Plain Icon
---@field public waypoint? boolean
---@field public module? CandyBucketsModule

---@class CandyBucketsModule
---@field public event CandyBucketsModuleName
---@field public texture string[]
---@field public title string[]
---@field public quests CandyBucketsQuest[]
---@field public patterns string[]
---@field public loaded? boolean

---@class CandyBucketsMapCanvas : Frame
---@field public GetMap fun(): CandyBucketsMapPosition
---@field public GetMapID fun(): number
---@field public RemoveAllPinsByTemplate fun(self: CandyBucketsMapCanvas, template: string)
---@field public AcquirePin fun(self: CandyBucketsMapCanvas, template: string, ...)
---@field public RefreshAllData fun(self: CandyBucketsMapCanvas, fromOnShow?: boolean)
---@field public GetNumActivePinsByTemplate fun(self: CandyBucketsMapCanvas, template: string): number

---@class CandyBucketsMapPosition : CandyBucketsMapCanvas
---@field public name string
---@field public quest? CandyBucketsQuest
---@field public GetPosition fun(): x: number, y: number
---@field public SetPosition fun(self: CandyBucketsMapPosition, x: number, y: number)

---@class CandyBucketsWaypointAddOn
---@field public name string
---@field public standard? boolean
---@field public func fun(self: CandyBucketsWaypointAddOn, poi: CandyBucketsMapPosition, wholeModule?: boolean): boolean|string
---@field public funcAll fun(self: CandyBucketsWaypointAddOn, module: CandyBucketsModule): boolean|string
---@field public funcRemove? fun(self: CandyBucketsWaypointAddOn, questID: number): boolean
---@field public funcClosest? fun(self: CandyBucketsWaypointAddOn): boolean

---@class CandyBucketsDataProvider : CandyBucketsMapCanvas

---@class CandyBucketsPin : CandyBucketsMapPosition
---@field public SetScalingLimits fun(self: CandyBucketsPin, scaleFactor: number, startScale: number, endScale: number)
---@field public UseFrameLevelType fun(self: CandyBucketsPin, template: string, level: number)
---@field public HighlightTexture Texture
---@field public Texture Texture
---@field public Border Texture

---@class CandyBucketsStats : CandyBucketsPin
---@field public Text FontString

---@class CandyBucketsEvalPositionQuestInfo
---@field public module? CandyBucketsModule
---@field public quest? CandyBucketsEvalPositionQuestInfo
---@field public side? number `1` = Alliance, `2` = Horde, `3` = Neutral
---@field public missing? boolean
---@field public error? string
---@field public warning? string
---@field public success? string
---@field public name? string
---@field public uiMapID? number
---@field public x? number
---@field public y? number
---@field public distance? number

---@class CandyBucketsEvalPositionRetInfo
---@field public has? boolean
---@field public success? boolean
---@field public data? CandyBucketsEvalPositionQuestInfo

local addonName = ... ---@type string
local ns = select(2, ...) ---@class CandyBucketsNS

--
-- Debug
--

local DEBUG_MODULE = false
local DEBUG_FACTION = false
local DEBUG_LOCATION = false

--
-- Chat output
--

-- Outputs to the chat frame. Takes the same arguments as `format`.
---@param fmt string
---@param ... any
local function Output(fmt, ...)
	local text = format(fmt, ...)
	DEFAULT_CHAT_FRAME:AddMessage(text, 1, 1, 0)
end

--
-- Session
--

ns.FACTION = 0 --- `1` = Alliance, `2` = Horde, `3` = Neutral
ns.QUESTS = {} ---@type CandyBucketsQuest[]
ns.PROVIDERS = {} ---@type table<CandyBucketsDataProvider, true?>

---@type table<number, boolean>
ns.COMPLETED_QUESTS = setmetatable({}, {
	__index = function(self, questID)
		local isCompleted = C_QuestLog.IsQuestFlaggedCompleted(questID)
		if isCompleted then
			self[questID] = isCompleted
		end
		return isCompleted
	end
})

--
-- Map
--

ns.PARENT_MAP = ns.PARENT_MAP ---@type table<number, table<number, boolean>>
-- filled in parent_map.lua

---@param uiMapID number
---@param x number
---@param y number
---@return number uiMapID, number x, number y
local function GetLowestLevelMapFromMapID(uiMapID, x, y)
	if not uiMapID or not x or not y then
		return uiMapID, x, y
	end

	local child = C_Map.GetMapInfoAtPosition(uiMapID, x, y)
	if not child or not child.mapID then
		return uiMapID, x, y
	end

	local continentID, worldPos = C_Map.GetWorldPosFromMapPos(uiMapID, { x = x, y = y })
	if not continentID or not worldPos then
		return uiMapID, x, y
	end

	local _, mapPos = C_Map.GetMapPosFromWorldPos(continentID, worldPos, child.mapID)
	if mapPos and mapPos.x and mapPos.y then
		return child.mapID, mapPos.x, mapPos.y
	end

	return uiMapID, x, y
end

---@return number? uiMapID, Vector2DMixin? pos
local function GetPlayerMapAndPosition()
	local unit = "player"

	local uiMapID = C_Map.GetBestMapForUnit(unit)
	if not uiMapID then
		return
	end

	local pos = C_Map.GetPlayerMapPosition(uiMapID, unit)
	if not pos or not pos.x or not pos.y then
		return uiMapID
	end

	return uiMapID, pos
end

--
-- Waypoint
--

-- ns:GetWaypointAddon()
-- ns:AutoWaypoint(poi, wholeModule, silent)
do

	---@class TomTomWaypointOptionsPolyfill
	---@field public quest? CandyBucketsQuest
	---@field public from string
	---@field public title string
	---@field public minimap boolean
	---@field public crazy boolean

	-- TomTom (v80001-1.0.2)
	---@type CandyBucketsWaypointAddOn
	local tomtomWaypointAddon = {
		name = "TomTom",
		func = function(self, poi, wholeModule)
			if wholeModule then
				self:funcAll(poi.quest.module)
				TomTom:SetClosestWaypoint()
			else
				local uiMapID = poi:GetMap():GetMapID()
				local x, y = poi:GetPosition()
				local childUiMapID, childX, childY = GetLowestLevelMapFromMapID(uiMapID, x, y)
				local mapInfo = C_Map.GetMapInfo(childUiMapID)
				---@type TomTomWaypointOptionsPolyfill
				local options = {
					from = addonName,
					quest = poi.quest,
					title = string.format("%s (%s, %d)", poi.name, mapInfo.name or ("Map " .. childUiMapID), poi.quest.quest),
					minimap = true,
					crazy = true,
				}
				TomTom:AddWaypoint(childUiMapID, childX, childY, options)
			end
			return true
		end,
		funcAll = function(self, module)
			for i = 1, #ns.QUESTS do
				local quest = ns.QUESTS[i]
				if quest.module == module and quest.waypoint ~= false then
					for uiMapID, coords in pairs(quest) do
						if type(uiMapID) == "number" and type(coords) == "table" then
							local name = module.title[quest.extra or 1]
							local mapInfo = C_Map.GetMapInfo(uiMapID)
							---@type TomTomWaypointOptionsPolyfill
							local options = {
								from = addonName,
								quest = quest,
								title = string.format("%s (%s, %d)", name, mapInfo.name or ("Map " .. uiMapID), quest.quest),
								minimap = true,
								crazy = true,
							}
							TomTom:AddWaypoint(uiMapID, coords[1]/100, coords[2]/100, options)
						end
					end
				end
			end
			return true
		end,
		funcRemove = function(self, questID)
			local remove ---@type table<TomTomWaypointOptionsPolyfill, true>?
			for _, mapWaypoints in pairs(TomTom.waypoints) do
				for _, mapWaypoint in pairs(mapWaypoints) do
					---@type TomTomWaypointOptionsPolyfill
					local waypoint = mapWaypoint
					if waypoint.from == addonName and type(waypoint.quest) == "table" and waypoint.quest.quest == questID then
						if not remove then
							remove = {}
						end
						remove[waypoint] = true
					end
				end
			end
			if not remove then
				return false
			end
			for waypoint, _ in pairs(remove) do
				TomTom:RemoveWaypoint(waypoint)
			end
			return true
		end,
		funcClosest = function(self)
			---@type TomTomWaypointOptionsPolyfill?
			local waypoint = TomTom:GetClosestWaypoint()
			if not waypoint then
				return false
			end
			TomTom:SetCrazyArrow(waypoint, TomTom.profile.arrow.arrival, waypoint.title)
			return true
		end,
	}

	-- C_Map.SetUserWaypoint (9.0.1)
	---@type CandyBucketsWaypointAddOn
	local standardWaypointAddon = {
		name = "Waypoint",
		standard = true,
		func = function(self, poi, wholeModule)
			if wholeModule then
				self:funcAll(poi.quest.module)
			else
				local uiMapID = poi:GetMap():GetMapID()
				local x, y = poi:GetPosition()
				local childUiMapID, childX, childY = GetLowestLevelMapFromMapID(uiMapID, x, y)
				local mapInfo = C_Map.GetMapInfo(childUiMapID)
				if not C_Map.CanSetUserWaypointOnMap(childUiMapID) then
					return format("Can't make a waypoint to %s. Enter the continent then try again.", mapInfo.name)
				end
				C_Map.SetUserWaypoint({ uiMapID = childUiMapID, position = { x = childX, y = childY } })
			end
			return true
		end,
		funcAll = function(self, module)
			for i = 1, #ns.QUESTS do
				local quest = ns.QUESTS[i]
				if quest.module == module and quest.waypoint ~= false then
					for uiMapID, coords in pairs(quest) do
						if type(uiMapID) == "number" and type(coords) == "table" then
							if C_Map.CanSetUserWaypointOnMap(uiMapID) then
								C_Map.SetUserWaypoint({ uiMapID = uiMapID, position = { x = coords[1]/100, y = coords[2]/100 } })
								return true
							end
						end
					end
				end
			end
			return "Can't make a waypoint to any destination."
		end,
		funcRemove = function(self, questID)
			local waypoint = C_Map.GetUserWaypoint()
			if not waypoint then
				return false
			end
			for i = 1, #ns.QUESTS do
				local quest = ns.QUESTS[i]
				if quest.quest == questID then
					for uiMapID, coords in pairs(quest) do
						if type(uiMapID) == "number" and type(coords) == "table" then
							if waypoint.uiMapID == uiMapID and waypoint.position.x == coords[1] and waypoint.position.y == coords[2] then
								C_Map.ClearUserWaypoint()
								return true
							end
						end
					end
				end
			end
			return false
		end,
	}

	---@type CandyBucketsWaypointAddOn[]
	local waypointAddons = {
		tomtomWaypointAddon,
		standardWaypointAddon
	}

	local supportedAddons = {} ---@type string[]
	local supportedAddonsWarned = false
	for k, v in ipairs(waypointAddons) do supportedAddons[k] = v.name end
	supportedAddons = table.concat(supportedAddons, " ") ---@diagnostic disable-line: cast-local-type

	---@return CandyBucketsWaypointAddOn? waypoint
	function ns:GetWaypointAddon()
		for i = 1, #waypointAddons do
			local waypoint = waypointAddons[i]
			if waypoint.standard or C_AddOns.IsAddOnLoaded(waypoint.name) then
				return waypoint
			end
		end
	end

	---@param poi CandyBucketsMapPosition
	---@param wholeModule? boolean
	---@param silent? boolean
	---@return boolean success
	function ns:AutoWaypoint(poi, wholeModule, silent)
		local waypoint = ns:GetWaypointAddon()
		if not waypoint then
			if not silent then
				if not supportedAddonsWarned and supportedAddons ~= "" then
					supportedAddonsWarned = true
					Output("You need to install one of these supported waypoint addons: %s", supportedAddons)
				end
			end
			return false
		end
		local status, err = pcall(function() return waypoint:func(poi, wholeModule) end)
		if not status or err ~= true then
			if not silent then
				Output("Unable to set waypoint%s%s", waypoint.standard and "" or format(" using %s", waypoint.name), type(err) == "string" and format(": %s", err) or ".")
			end
			return false
		end
		return true
	end

	---@param questID number
	---@return boolean success
	function ns:RemoveQuestWaypoint(questID)
		local waypoint = ns:GetWaypointAddon()
		if not waypoint then
			return false
		end
		if not waypoint.funcRemove then
			return false
		end
		local status, err = pcall(function() return waypoint:funcRemove(questID) end)
		if not status or err ~= true then
			return false
		end
		return true
	end

	---@return boolean success
	function ns:AutoWaypointClosest()
		local waypoint = ns:GetWaypointAddon()
		if not waypoint then
			return false
		end
		if not waypoint.funcClosest then
			return false
		end
		local status, err = pcall(function() return waypoint:funcClosest() end)
		if not status or err ~= true then
			return false
		end
		return true
	end

end

--
-- Mixin
--

---@class CandyBucketsDataProvider
CandyBucketsDataProviderMixin = CreateFromMixins(MapCanvasDataProviderMixin)

function CandyBucketsDataProviderMixin:OnShow()
end

function CandyBucketsDataProviderMixin:OnHide()
end

---@param event WowEvent
---@param ... any
function CandyBucketsDataProviderMixin:OnEvent(event, ...)
	-- self:RefreshAllData()
end

function CandyBucketsDataProviderMixin:RemoveAllData()
	local map = self:GetMap()
	map:RemoveAllPinsByTemplate("CandyBucketsPinTemplate")
	map:RemoveAllPinsByTemplate("CandyBucketsStatsTemplate")
end

---@param fromOnShow boolean?
function CandyBucketsDataProviderMixin:RefreshAllData(fromOnShow)
	self:RemoveAllData()

	local map = self:GetMap()
	local uiMapID = map:GetMapID()
	local childUiMapIDs = ns.PARENT_MAP[uiMapID]
	local tempVector = {} ---@type Vector2DMixin
	local questPOIs ---@type table<CandyBucketsQuest, Vector2DMixin>?

	if IsModifierKeyDown() then
		questPOIs = {}
	end

	for i = 1, #ns.QUESTS do
		local quest = ns.QUESTS[i]
		local poi ---@type Vector2DMixin?
		local poi2 ---@type Vector2DMixin?

		if not childUiMapIDs then
			poi = quest[uiMapID] ---@type Vector2DMixin?

		else
			for childUiMapID, _ in pairs(childUiMapIDs) do
				poi = quest[childUiMapID] ---@type Vector2DMixin?

				if poi then
					local translateKey = uiMapID .. "," .. childUiMapID

					if poi[translateKey] ~= nil then
						poi = poi[translateKey]

					else
						tempVector.x, tempVector.y = poi[1]/100, poi[2]/100
						local continentID, worldPos = C_Map.GetWorldPosFromMapPos(childUiMapID, tempVector)
						poi, poi2 = nil, poi

						if continentID and worldPos then
							local _, mapPos = C_Map.GetMapPosFromWorldPos(continentID, worldPos, uiMapID)

							if mapPos then
								poi = mapPos
								poi2[translateKey] = mapPos
							end
						end

						if not poi then
							poi2[translateKey] = false
						end
					end

					break
				end
			end
		end

		if poi then
			map:AcquirePin("CandyBucketsPinTemplate", quest, poi)
			if questPOIs then
				questPOIs[quest] = poi
			end
		end
	end

	if questPOIs and next(questPOIs) then
		map:AcquirePin("CandyBucketsStatsTemplate", questPOIs)
	end
end

--
-- Pin
--

local PIN_BORDER_TRANSPARENT = 918860

local PIN_BORDER_COLOR = {
	[0] = "Interface\\Buttons\\GREYSCALERAMP64",
	[1] = "Interface\\Buttons\\BLUEGRAD64",
	[2] = "Interface\\Buttons\\REDGRAD64",
	[3] = "Interface\\Buttons\\YELLOWORANGE64",
}

---@class CandyBucketsPin
---@field public quest? any
---@field public name? string
---@field public description? string

---@class CandyBucketsPin
CandyBucketsPinMixin = CreateFromMixins(MapCanvasPinMixin)

function CandyBucketsPinMixin:OnLoad()
	self:SetScalingLimits(1, 1.0, 1.2)
	self.HighlightTexture:Hide()
	self.hasTooltip = true
	self:EnableMouse(self.hasTooltip)
	self.Texture:ClearAllPoints()
	self.Texture:SetAllPoints()
end

---@param texture number|string
---@param border number|string
---@param noBorderPlainIcon? boolean
function CandyBucketsPinMixin:SetTextureAndBorder(texture, border, noBorderPlainIcon)
	if noBorderPlainIcon then
		self.Texture:SetMask("")
		self.Border:SetMask("")
		self.Border:Hide()
	else
		self.Texture:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
		self.Border:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
		self.Border:Show()
	end
	self.Texture:SetTexture(texture)
	self.Border:SetTexture(border)
end

---@param quest CandyBucketsQuest
---@param poi Vector2DMixin
function CandyBucketsPinMixin:OnAcquired(quest, poi)
	self.quest = quest
	self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI", self:GetMap():GetNumActivePinsByTemplate("CandyBucketsPinTemplate"))
	self:SetSize(12, 12)
	local texture = quest.module.texture[quest.extra or 1]
	if quest.style == 2 then
		self:SetTextureAndBorder(texture, PIN_BORDER_TRANSPARENT, true)
	else
		self:SetTextureAndBorder(texture, PIN_BORDER_COLOR[quest.side or 0])
	end
	self.name = quest.module.title[quest.extra or 1]
	if poi.GetXY then
		self:SetPosition(poi:GetXY())
	else
		self:SetPosition(poi[1]/100, poi[2]/100)
	end
	local uiMapID = self:GetMap():GetMapID()
	if uiMapID then
		local x, y = self:GetPosition()
		local childUiMapID, childX, childY = GetLowestLevelMapFromMapID(uiMapID, x, y)
		local mapInfo = C_Map.GetMapInfo(childUiMapID)
		if mapInfo and mapInfo.name and childX and childY then
			self.description = string.format("%s (%.2f, %.2f)", mapInfo.name, childX * 100, childY * 100)
		end
	end
end

function CandyBucketsPinMixin:OnReleased()
	self.quest = nil
	self.name = nil
	self.description = nil
end

function CandyBucketsPinMixin:OnMouseEnter()
	if not self.hasTooltip then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	self.UpdateTooltip = self.OnMouseEnter
	GameTooltip_SetTitle(GameTooltip, self.name)
	if self.description and self.description ~= "" then
		GameTooltip_AddNormalLine(GameTooltip, self.description, true)
	end
	GameTooltip_AddNormalLine(GameTooltip, "Quest ID: " .. self.quest.quest, false)
	if ns:GetWaypointAddon() then
		GameTooltip_AddNormalLine(GameTooltip, "<Click to show waypoint.>", false)
	end
	GameTooltip:Show()
end

function CandyBucketsPinMixin:OnMouseLeave()
	if not self.hasTooltip then return end
	GameTooltip:Hide()
end

function CandyBucketsPinMixin:OnClick(button)
	if button ~= "LeftButton" then return end
	ns:AutoWaypoint(self, IsModifierKeyDown())
end

--
-- Stats
--

---@class CandyBucketsStats
---@field public hasTooltip boolean
---@field public name? string
---@field public description? string

---@class CandyBucketsStats
CandyBucketsStatsMixin = CreateFromMixins(MapCanvasPinMixin)

function CandyBucketsStatsMixin:OnLoad()
	self:SetScalingLimits(1, 1.0, 1.2)
	self.HighlightTexture:Hide()
	self.hasTooltip = false
	self:EnableMouse(self.hasTooltip)
	self.Texture:Hide()
end

---@param questPOIs table<CandyBucketsQuest, Vector2DMixin>
function CandyBucketsStatsMixin:OnAcquired(questPOIs)
	local map = self:GetMap()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI", map:GetNumActivePinsByTemplate("CandyBucketsStatsTemplate"))
	self:SetSize(map:GetSize())
	self:SetPosition(.5, .5)
	--self:ClearAllPoints()
	--self:SetPoint("TOPLEFT", map:GetCanvasContainer(), "TOPLEFT", 0, 0)
	self.name = nil
	self.description = nil
	local text
	local i = 0
	local uiMapID = map:GetMapID()
	if uiMapID then
		text = {}
		for quest, poi in pairs(questPOIs) do
			local x, y
			if poi.GetXY then
				x, y = poi:GetXY()
			else
				x, y = poi[1]/100, poi[2]/100
			end
			local childUiMapID, childX, childY = GetLowestLevelMapFromMapID(uiMapID, x, y)
			if childX > 0 and childX < 1 and childY > 0 and childY < 1 then
				local mapInfo = C_Map.GetMapInfo(childUiMapID)
				i = i + 1
				if mapInfo and mapInfo.name then
					text[i] = string.format("%s (%.2f, %.2f)", mapInfo.name, childX * 100, childY * 100)
				else
					text[i] = string.format("#%d", quest.quest)
				end
			end
		end
		table.sort(text)
		text = table.concat(text, "\r\n")
	end
	self.Text:SetText(text)
end

function CandyBucketsStatsMixin:OnReleased()
	self.name = nil
	self.description = nil
end

function CandyBucketsStatsMixin:OnMouseEnter()
	if not self.hasTooltip then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	self.UpdateTooltip = self.OnMouseEnter
	GameTooltip_SetTitle(GameTooltip, self.name)
	if self.description and self.description ~= "" then
		GameTooltip_AddNormalLine(GameTooltip, self.description, true)
	end
	GameTooltip:Show()
end

function CandyBucketsStatsMixin:OnMouseLeave()
	if not self.hasTooltip then return end
	GameTooltip:Hide()
end

function CandyBucketsStatsMixin:OnClick(button)
	if button ~= "LeftButton" then return end
	-- TODO: ?
end

--
-- Modules
--

ns.modules = ns.modules or {}

---@type table<number, CandyBucketsModuleName>
local MODULE_FROM_TEXTURE = {
	[235461] = "hallow",
	[235462] = "hallow",
	[235460] = "hallow",
	[235470] = "lunar",
	[235471] = "lunar",
	[235469] = "lunar",
	[235473] = "midsummer",
	[235474] = "midsummer",
	[235472] = "midsummer",
	[235442] = "brewfest",
	[235441] = "brewfest",
	[235440] = "brewfest",
}

--
-- Addon
--

local addon = CreateFrame("Frame") ---@class CandyBucketsAddOn : Frame
addon:SetScript("OnEvent", function(addon, event, ...) addon[event](addon, event, ...) end)
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")

local InjectDataProvider do
	local function WorldMapMixin_OnLoad(self)
		local dataProvider = CreateFromMixins(CandyBucketsDataProviderMixin)
		ns.PROVIDERS[dataProvider] = true
		self:AddDataProvider(dataProvider)
	end

	function InjectDataProvider()
		hooksecurefunc(WorldMapMixin, "OnLoad", WorldMapMixin_OnLoad)
		WorldMapMixin_OnLoad(WorldMapFrame)
	end
end

---@param onlyShownMaps boolean
---@param fromOnShow? boolean
function addon:RefreshAllWorldMaps(onlyShownMaps, fromOnShow)
	for dataProvider, _ in pairs(ns.PROVIDERS) do
		if not onlyShownMaps or dataProvider:GetMap():IsShown() then
			dataProvider:RefreshAllData(fromOnShow)
		end
	end
end

---@param questID number
function addon:RemoveQuestPois(questID)
	local removed = 0

	for i = #ns.QUESTS, 1, -1 do
		local quest = ns.QUESTS[i]

		if quest.quest == questID then
			removed = removed + 1
			table.remove(ns.QUESTS, i)
		end
	end

	return removed > 0
end

---@param name CandyBucketsModuleName
function addon:CanLoadModule(name)
	return type(ns.modules[name]) == "table" and ns.modules[name].loaded ~= true
end

---@param name CandyBucketsModuleName
function addon:CanUnloadModule(name)
	return type(ns.modules[name]) == "table" and ns.modules[name].loaded == true
end

---@param name CandyBucketsModuleName
function addon:LoadModule(name)
	local module = ns.modules[name]
	module.loaded = true

	local i = #ns.QUESTS
	for j = 1, #module.quests do
		local quest = module.quests[j]

		if (not quest.side or quest.side == 3 or quest.side == ns.FACTION or DEBUG_FACTION) and not ns.COMPLETED_QUESTS[quest.quest] then
			quest.module = module
			i = i + 1
			ns.QUESTS[i] = quest
		end
	end

	addon:RefreshAllWorldMaps(true)
end

---@param name CandyBucketsModuleName
function addon:UnloadModule(name)
	local module = ns.modules[name]
	module.loaded = false

	for i = #ns.QUESTS, 1, -1 do
		local quest = ns.QUESTS[i]

		if quest.module.event == name then
			table.remove(ns.QUESTS, i)
		end
	end

	addon:RefreshAllWorldMaps(true)
end

function addon:CheckCalendar()
	local curDate = C_DateAndTime.GetCurrentCalendarTime()
	local month, day, year = curDate.month, curDate.monthDay, curDate.year
	local curHour, curMinute = curDate.hour, curDate.minute

	local calDate = C_Calendar.GetMonthInfo()
	local monthOffset = -12 * (curDate.year - calDate.year) + calDate.month - curDate.month -- convert difference between calendar and the realm time

	if monthOffset ~= 0 then
		return -- we only care about the current events, so we need the view to be on the current month (otherwise we unload the ongoing events if we change the month manually...)
	end

	local numEvents = C_Calendar.GetNumDayEvents(monthOffset, day)
	local loadedEvents, numLoaded, numLoadedRightNow = {}, 0, 0

	for i = 1, numEvents do
		local event = C_Calendar.GetDayEvent(monthOffset, day, i)

		if event and event.calendarType == "HOLIDAY" then
			local ongoing = event.sequenceType == "ONGOING" -- or event.sequenceType == "INFO"
			local moduleName = MODULE_FROM_TEXTURE[event.iconTexture]

			if event.sequenceType == "START" then
				ongoing = curHour >= event.startTime.hour and (curHour > event.startTime.hour or curMinute >= event.startTime.minute)
			elseif event.sequenceType == "END" then
				ongoing = curHour <= event.endTime.hour and (curHour < event.endTime.hour or curMinute <= event.endTime.minute)
				-- TODO: linger for 12 hours extra just in case event is active but not in the calendar due to timezone differences
				if not ongoing then
					local paddingHour = max(0, curHour - 12)
					ongoing = paddingHour <= event.endTime.hour and (paddingHour < event.endTime.hour or curMinute <= event.endTime.minute)
				end
			end

			if ongoing and addon:CanLoadModule(moduleName) then
				Output("|cffFFFFFF%s|r has loaded the module for |cffFFFFFF%s|r!", addonName, tostring(event.title))
				addon:LoadModule(moduleName)
				numLoadedRightNow = numLoadedRightNow + 1
			elseif not ongoing and addon:CanUnloadModule(moduleName) then
				Output("|cffFFFFFF%s|r has unloaded the module for |cffFFFFFF%s|r because the event has ended.", addonName, tostring(event.title))
				addon:UnloadModule(moduleName)
			end

			if moduleName and ongoing then
				loadedEvents[moduleName] = true
			end
		end
	end

	if DEBUG_MODULE then
		for name, module in pairs(ns.modules) do
			if addon:CanLoadModule(name) then
				Output("|cffFFFFFF%s|r has loaded the module for |cffFFFFFF[DEBUG] %s|r!", addonName, name)
				addon:LoadModule(name)
				numLoadedRightNow = numLoadedRightNow + 1
			end
			loadedEvents[name] = true
		end
	end

	for name, module in pairs(ns.modules) do
		if addon:CanUnloadModule(name) and not loadedEvents[name] then
			Output("|cffFFFFFF%s|r couldn't find |cffFFFFFF%s|r in the calendar so we consider the event expired.", addonName, name)
			addon:UnloadModule(name)
		end
	end

	for name, module in pairs(ns.modules) do
		if addon:CanUnloadModule(name) then
			numLoaded = numLoaded + 1
		end
	end

	if numLoaded > 0 then
		addon:RegisterEvent("QUEST_TURNED_IN")
	else
		addon:UnregisterEvent("QUEST_TURNED_IN")
	end

	if numLoadedRightNow > 0 then
		Output("|cffFFFFFF%s|r has |cffFFFFFF%d|r locations for you to visit.", addonName, #ns.QUESTS)
	end
end

---@param check? boolean
function addon:QueryCalendar(check)
	local function DelayedUpdate()
		if type(CalendarFrame) ~= "table" or not CalendarFrame:IsShown() then
			local curDate = C_DateAndTime.GetCurrentCalendarTime()
			C_Calendar.SetAbsMonth(curDate.month, curDate.year)
			C_Calendar.OpenCalendar()
		end
	end

	addon:RegisterEvent("CALENDAR_UPDATE_EVENT")
	addon:RegisterEvent("CALENDAR_UPDATE_EVENT_LIST")
	addon:RegisterEvent("INITIAL_CLUBS_LOADED")
	addon:RegisterEvent("GUILD_ROSTER_UPDATE")
	addon:RegisterEvent("PLAYER_GUILD_UPDATE")
	addon:RegisterEvent("PLAYER_ENTERING_WORLD")

	DelayedUpdate()
	C_Timer.After(10, DelayedUpdate)

	if check then
		addon:CheckCalendar()
	end
end

---@param questID number
---@return boolean? success, CandyBucketsEvalPositionQuestInfo? info, number? poiCount
function addon:IsDeliveryLocationExpected(questID)
	local questCollection = {} ---@type CandyBucketsEvalPositionQuestInfo[]
	local questName ---@type string?

	for i = 1, #ns.QUESTS do
		local quest = ns.QUESTS[i]
		if quest.quest == questID then
			table.insert(questCollection, quest)
		end
	end

	if not questCollection[1] then
		questName = C_QuestLog.GetTitleForQuestID(questID)

		if questName then
			local missingFromModule ---@type CandyBucketsModule?

			for _, module in pairs(ns.modules) do
				if module.loaded == true then
					for _, pattern in pairs(module.patterns) do
						if questName:match(pattern) then
							missingFromModule = module
							break
						end
					end
					if missingFromModule then
						break
					end
				end
			end

			if missingFromModule then
				table.insert(questCollection, { missing = true, module = missingFromModule, quest = questID, side = 3 })
			end
		end
	end

	if not questCollection[1] then
		return nil, DEBUG_LOCATION and { error = "Quest not part of any module.", name = questName } or nil, nil
	end

	local uiMapID, pos = GetPlayerMapAndPosition()
	if not uiMapID then
		return nil, DEBUG_LOCATION and { error = "Player has no uiMapID." } or nil, nil
	elseif not pos then
		return nil, DEBUG_LOCATION and { error = "Player is on map " .. uiMapID .. " but not coordinates." } or nil, nil
	end

	if questCollection[1].missing then
		for i = 1, #questCollection do
			questCollection[i][uiMapID] = { pos.x * 100, pos.y * 100 }
		end
	end

	local returnCount = 0
	local returns = {} ---@type CandyBucketsEvalPositionRetInfo[]

	for i = 1, #questCollection do
		local quest = questCollection[i]
		local qpos = quest[uiMapID] ---@type CandyBucketsMapPosition

		local ret = {} ---@type CandyBucketsEvalPositionRetInfo
		returnCount = returnCount + 1
		returns[returnCount] = ret

		repeat
			if type(qpos) == "table" then
				local distance = quest.missing and 1 or 0

				if not quest.missing then
					local dx = qpos[1]/100 - pos.x
					local dy = qpos[2]/100 - pos.y

					local dd = dx*dx + dy*dy
					if dd < 0 then
						ret.has, ret.success, ret.data = true, nil, DEBUG_LOCATION and { error = "Distance calculated is negative. Can't sqrt negative numbers." } or nil
						break
					end

					distance = sqrt(dd)
				end

				local mapWidth, mapHeight = C_Map.GetMapWorldSize(uiMapID)
				local mapSize = min(mapWidth, mapHeight)
				local mapScale = mapSize > 0 and 100/mapSize or 0
				local warnDistanceForMap = mapScale > 0 and mapScale or 0.05 -- we convert the actual map size into the same scale as we use for the distance - fallback to 0.05 if we're missing data

				if distance > warnDistanceForMap then
					ret.has, ret.success, ret.data = true, false, { quest = quest, uiMapID = uiMapID, x = pos.x, y = pos.y, distance = distance }
				elseif DEBUG_LOCATION then
					ret.has, ret.success, ret.data = true, true, { success = "Player turned in quest at an acceptable distance.", quest = quest, uiMapID = uiMapID, x = pos.x, y = pos.y, distance = distance }
				else
					ret.has, ret.success = true, true
				end

			elseif not quest.missing then
				ret.has, ret.success, ret.data = true, false, { quest = quest, uiMapID = uiMapID, x = pos.x, y = pos.y, distance = 1 }
			end
		until true
	end

	for i = 1, returnCount do
		local ret = returns[i]
		if ret.has and ret.success then
			return ret.success, ret.data, returnCount
		end
	end

	for i = 1, returnCount do
		local ret = returns[i]
		if ret.has then
			return ret.success, ret.data, returnCount
		end
	end

	return true, DEBUG_LOCATION and { warning = "Player is not on appropriate map for this quest and can't calculate distance." } or nil, returnCount
end

function addon:CanUseAddonLinks()
	local _, _, _, build = GetBuildInfo()
	return build >= 100100
end

---@param entry string
function addon:CreateAddonCopyLink(entry)
	return format("|cFFFF5555|Haddon:%s:%s|h[Click here to copy this message]|h|r", addonName, entry)
end

---@param text string
function addon:ShowCopyDialog(text)
	local key = format("%s Copy Dialog", addonName)

	if not StaticPopupDialogs[key] then
		StaticPopupDialogs[key] = {
			text = "",
			button1 = "",
			-- button2 = "",
			hasEditBox = 1,
			OnShow = function(self, data)
				if data.text_arg1 ~= nil then
					self.text:SetFormattedText(data.text, data.text_arg1, data.text_arg2)
				else
					self.text:SetText(data.text)
				end
				if data.acceptText ~= false then
					self.button1:SetText(data.acceptText or DONE)
				else
					self.button1:Hide()
				end
				if data.cancelText ~= false then
					self.button2:SetText(data.cancelText or CANCEL)
				else
					self.button2:Hide()
				end
				self.editBox:SetMaxLetters(data.maxLetters or 255)
				self.editBox:SetCountInvisibleLetters(not not data.countInvisibleLetters)
				if data.editBox then
					self.editBox:SetText(data.editBox)
					self.editBox:HighlightText()
				end
			end,
			OnAccept = function(self, data)
				if data.callback then
					data.callback(self.editBox:GetText())
				end
			end,
			OnCancel = function(self, data)
				if data.cancelCallback then
					data.cancelCallback()
				end
			end,
			EditBoxOnEnterPressed = function(self, data)
				local parent = self:GetParent();
				if parent.button1:IsEnabled() then
					if data.callback then
						data.callback(parent.editBox:GetText())
					end
					parent:Hide()
				end
			end,
			EditBoxOnTextChanged = function(self)
				-- local parent = self:GetParent()
				-- parent.button1:SetEnabled(parent.editBox:GetText():trim() ~= "")
			end,
			EditBoxOnEscapePressed = function(self)
				self:GetParent():Hide()
			end,
			hideOnEscape = 1,
			timeout = 0,
			exclusive = 1,
			whileDead = 1,
		}
	end

	return StaticPopup_Show(key, nil, nil, {
		text = "The contents below contain the required information to update the quest with a more accurate location.",
		editBox = text,
		acceptText = CLOSE,
	})
end

-- hook `SetItemRef` if addon links are supported (and call `ShowCopyDialog` when the links are clicked)
if addon:CanUseAddonLinks() then
	local function HandleAddonLinkClick(link)
		local linkType, prefix, param1 = strsplit(":", link, 3)
		if linkType ~= "addon" or prefix ~= addonName then
			return
		end
		addon:ShowCopyDialog(param1)
	end

	hooksecurefunc("SetItemRef", HandleAddonLinkClick)
end

--
-- Events
--

function addon:ADDON_LOADED(event, name)
	if name == addonName then
		addon:UnregisterEvent(event)
		InjectDataProvider()
	end
end

function addon:PLAYER_LOGIN(event)
	addon:UnregisterEvent(event)

	local faction = UnitFactionGroup("player")
	if faction == "Alliance" then
		ns.FACTION = 1
	elseif faction == "Horde" then
		ns.FACTION = 2
	else
		ns.FACTION = 3
	end

	addon:QueryCalendar(true)
end

function addon:CALENDAR_UPDATE_EVENT()
	addon:CheckCalendar()
end

function addon:CALENDAR_UPDATE_EVENT_LIST()
	addon:CheckCalendar()
end

function addon:INITIAL_CLUBS_LOADED()
	addon:CheckCalendar()
end

function addon:GUILD_ROSTER_UPDATE()
	addon:CheckCalendar()
end

function addon:PLAYER_GUILD_UPDATE()
	addon:CheckCalendar()
end

function addon:PLAYER_ENTERING_WORLD()
	addon:CheckCalendar()
end

function addon:QUEST_TURNED_IN(event, questID)
	ns.COMPLETED_QUESTS[questID] = true

	local success, info, checkedNumQuestPOIs = addon:IsDeliveryLocationExpected(questID)
	if DEBUG_LOCATION then
		Output("|cffFFFFFF%s|r quest |cffFFFFFF%d|r turned in%s", addonName, questID, info and ":" or ".")
		if info then
			if info.error then
				Output("|cffFF0000Error!|r |cffFFFFFF%s|r", info.error)
			end
			if info.warning then
				Output("|cffFFFF00Warning!|r |cffFFFFFF%s|r", info.warning)
			end
			if info.success then
				Output("|cff00FF00Success!|r |cffFFFFFF%s|r", info.success)
			end
			if info.name then
				Output("|cff00FF00Quest|r: |cffFFFFFF%s|r", info.name)
			end
			if info.distance then
				Output("|cff00FF00Distance|r: |cffFFFFFF%s|r", info.distance)
			end
			if info.x and info.y then
				Output("|cffFFFFFFmxy|r = |cffFFFFFF%s|r @ |cffFFFFFF%.2f|r, |cffFFFFFF%.2f|r", info.uiMapID and tostring(info.uiMapID) or "?", info.x * 100, info.y * 100)
			end
		end
	elseif success == false and info then
		local suffix = "Please screenshot this message and report it to the author."
		if addon:CanUseAddonLinks() then
			local entry = format("{ quest = %d, side = %d, [%d] = {%.2f, %.2f} }, -- %.2f, %s", questID, ns.FACTION, info.uiMapID, info.x * 100, info.y * 100, info.distance * 100, GetMinimapZoneText() or "N/A")
			local link = addon:CreateAddonCopyLink(entry)
			suffix = format("%s, then report it to the author.", link)
		end
		Output("|cffFFFFFF%s|r quest |cffFFFFFF%s#%d|r turned in at the wrong location. You were at |cffFFFFFF%d/%d/%.2f/%.2f|r roughly |cffFFFFFF%.2f|r units away from the expected %s. %s Thanks!", addonName, info.quest.module.event, questID, ns.FACTION, info.uiMapID, info.x * 100, info.y * 100, info.distance * 100, checkedNumQuestPOIs and checkedNumQuestPOIs > 1 and checkedNumQuestPOIs .. " locations" or "location", suffix)
	end

	if addon:RemoveQuestPois(questID) then
		if ns:RemoveQuestWaypoint(questID) then
			ns:AutoWaypointClosest()
		end
		addon:RefreshAllWorldMaps(true)
	end
end
