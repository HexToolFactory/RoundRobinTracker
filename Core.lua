-- Round Robin Tracker: counts chosen items looted by each group member, from the loot chat lines, until reset.
local _, ns = ...
local VERSION = "0.9.0"

local DB
local ITEMS = ns and ns.ITEMS or {} -- [itemID] = English name, from Items.lua (QuestieDB data)
local itemsLower -- [itemID] = lower-case name, built on the first search
local function lowerNames()
	if not itemsLower then
		itemsLower = {}
		for id, name in pairs(ITEMS) do
			itemsLower[id] = name:lower():gsub("'", "")
		end
	end
	return itemsLower
end

local function plain(v)
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function msg(text)
	print("|cff66ccffRR|r " .. text)
end

local function lower(s)
	return (s or ""):lower()
end

-- names: "Anna Berg", "Anna-Berg" and "Anna Berg-Realm" are one person
local function squash(name)
	return lower(name):gsub("[%s%-']", "")
end

local function me()
	return GetUnitName("player", true) or UnitName("player") or "?"
end

---------------------------------------------------------------------------------------------------------
-- saved data
---------------------------------------------------------------------------------------------------------

local function initDB()
	RoundRobinTrackerDB = RoundRobinTrackerDB or {}
	DB = RoundRobinTrackerDB
	DB.items = DB.items or {} -- { key, id, name, link }
	DB.counts = DB.counts or {} -- [player] = { [key] = n }
	DB.classes = DB.classes or {} -- [player] = classFile
	DB.since = DB.since or time()
	DB.missed = DB.missed or 0
	DB.seen = DB.seen or {} -- [itemID] = { name, link, t }: items in any loot line, for the add box suggestions
	DB.history = DB.history or {} -- [itemID] = { name, link, t }: items tracked before
	DB.rounds = DB.rounds or {} -- [item key] = last round announced
	DB.commission = DB.commission or {} -- [squashed name] = true / false: Argent Dawn Commission buff, last read
	DB.proven = DB.proven or {} -- [squashed name] = true: looted a Scourgestone since the last reset, so they have it
	if DB.announce == nil then
		DB.announce = true -- post "round N complete" to group chat
	end
	if DB.autoReport == nil then
		DB.autoReport = true -- post the report when a tracked item is up for roll
	end
	local ids = {}
	for id in pairs(DB.seen) do
		ids[#ids + 1] = id
	end
	if #ids > 300 then
		table.sort(ids, function(a, b)
			return (DB.seen[a].t or 0) > (DB.seen[b].t or 0)
		end)
		for i = 301, #ids do
			DB.seen[ids[i]] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------------
-- group
---------------------------------------------------------------------------------------------------------

local function groupUnits()
	local units = { "player" }
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			units[#units + 1] = "raid" .. i
		end
	elseif IsInGroup() then
		for i = 1, GetNumSubgroupMembers() do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

local function roster()
	local list, seen = {}, {}
	for _, unit in ipairs(groupUnits()) do
		local name = GetUnitName(unit, true)
		if name and not seen[squash(name)] then
			seen[squash(name)] = true
			list[#list + 1] = name
			local _, class = UnitClass(unit)
			if class then
				DB.classes[name] = class
			end
		end
	end
	return list
end

---------------------------------------------------------------------------------------------------------
-- Argent Dawn Commission: Scourgestones drop only for players wearing it, so players without it are left
-- out of the round robin for those items (shown as "-"). The buff is read out of combat only (aura data
-- is secret in combat on Forever); the last state read is kept. Never read = counts as having it.
---------------------------------------------------------------------------------------------------------

local COMMISSION_SPELL = 17670
local COMMISSION_NAME = "Argent Dawn Commission"
local COMMISSION_ITEMS = { [12840] = true, [12841] = true, [12843] = true } -- Minion's, Invader's, Corruptor's
local COMMISSION_NAMES = {
	["minion's scourgestone"] = true,
	["invader's scourgestone"] = true,
	["corruptor's scourgestone"] = true,
}

local function needsCommission(entry)
	if not entry then
		return false
	end
	if entry.id then
		return COMMISSION_ITEMS[entry.id] == true
	end
	return COMMISSION_NAMES[lower(entry.name)] == true
end

local function anyNeedsCommission()
	for _, entry in ipairs(DB.items) do
		if needsCommission(entry) then
			return true
		end
	end
	return false
end

-- true / false, or nil when it cannot be read now (combat, secret, offline, too far away)
local function readCommission(unit)
	if InCombatLockdown and InCombatLockdown() then
		return nil
	end
	if UnitIsConnected and not UnitIsConnected(unit) then
		return nil
	end
	local get = C_UnitAuras and C_UnitAuras.GetBuffDataByIndex
	if not get then
		return nil
	end
	local any = false
	for i = 1, 255 do
		local ok, aura = pcall(get, unit, i, "HELPFUL")
		if not ok or aura == nil then
			break
		end
		if plain(aura) == nil then
			return nil
		end
		local id, name = plain(aura.spellId), plain(aura.name)
		if id == nil and name == nil then
			return nil -- fields secret
		end
		any = true
		if id == COMMISSION_SPELL or name == COMMISSION_NAME then
			return true
		end
	end
	if not any and UnitIsVisible and not UnitIsVisible(unit) then
		return nil -- no aura data for far-away members
	end
	return false
end

local refresh -- UI, defined below

-- returns true when a state changed
local function scanUnit(unit)
	local name = GetUnitName(unit, true)
	if not name then
		return false
	end
	local has = readCommission(unit)
	if has == nil or DB.commission[squash(name)] == has then
		return false
	end
	DB.commission[squash(name)] = has
	return true
end

local function scanCommission()
	if not anyNeedsCommission() then
		return
	end
	local changed = false
	for _, unit in ipairs(groupUnits()) do
		if scanUnit(unit) then
			changed = true
		end
	end
	if changed then
		refresh()
	end
end

-- does this player take part in the round robin of this item
local function eligible(name, entry)
	return not needsCommission(entry) or DB.proven[squash(name)] or DB.commission[squash(name)] ~= false
end

local function leftOut(entry)
	local out = {}
	if needsCommission(entry) then
		for _, name in ipairs(roster()) do
			if not eligible(name, entry) then
				out[#out + 1] = name
			end
		end
	end
	return out
end

-- the name we file a looter under: group member first, then someone already counted, else as written
local function canonical(who)
	if not who or who == "" then
		return nil
	end
	local candidates = { squash(who) }
	local noRealm = who:match("^(.+ .+)%-[^%s%-]+$")
	if noRealm then
		candidates[2] = squash(noRealm)
	end
	for _, key in ipairs(candidates) do
		for _, name in ipairs(roster()) do
			if squash(name) == key then
				return name
			end
		end
		for name in pairs(DB.counts) do
			if squash(name) == key then
				return name
			end
		end
	end
	return noRealm or who
end

---------------------------------------------------------------------------------------------------------
-- tracked items
---------------------------------------------------------------------------------------------------------

local function itemInfo(id)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if not getInfo then
		return nil
	end
	local name, link = getInfo(id)
	return name, link
end

local function requestItem(id)
	if C_Item and C_Item.RequestLoadItemDataByID then
		pcall(C_Item.RequestLoadItemDataByID, id)
	end
end

local function itemIcon(entry)
	if entry.id then
		local icon
		if C_Item and C_Item.GetItemIconByID then
			icon = C_Item.GetItemIconByID(entry.id)
		elseif GetItemIcon then
			icon = GetItemIcon(entry.id)
		end
		if icon then
			return icon
		end
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function entryLabel(entry)
	return entry.link or entry.name or ("item " .. tostring(entry.id))
end

-- item ID, item link or item name -> entry
local function resolve(input)
	input = (input or ""):match("^%s*(.-)%s*$")
	if input == "" then
		return nil
	end
	local id = tonumber(input) or tonumber(input:match("item:(%d+)"))
	local name = input:match("|h%[(.-)%]|h") or input:match("^%[(.-)%]$")
	local link = input:match("(|c%x+|Hitem:.-|h|r)") or input:match("(|Hitem:.-|h)")
	if id then
		local n, l = itemInfo(id)
		if not n then
			requestItem(id)
		end
		return { key = "i" .. id, id = id, name = n or name or ITEMS[id], link = l or link }
	end
	name = name or input
	local n, l = itemInfo(name) -- only works when the client knows the item
	if l then
		local found = tonumber(l:match("item:(%d+)"))
		if found then
			return { key = "i" .. found, id = found, name = n, link = l }
		end
	end
	local wanted = lower(name)
	local wantedNorm = wanted:gsub("'", "")
	for itemID, low in pairs(lowerNames()) do
		if low == wantedNorm then
			local n2, l2 = itemInfo(itemID)
			if not n2 then
				requestItem(itemID)
			end
			return { key = "i" .. itemID, id = itemID, name = n2 or ITEMS[itemID], link = l2 }
		end
	end
	return { key = "n" .. wanted, name = name }
end

local function findTracked(link)
	local id = tonumber(link:match("item:(%d+)"))
	local name = lower(link:match("%[(.-)%]"))
	for _, entry in ipairs(DB.items) do
		if (id and entry.id == id) or (not entry.id and name ~= "" and lower(entry.name) == name) then
			if id and not entry.id then
				entry.id = id -- learned from the loot line; the key stays the same
			end
			if not entry.link and link:find("|H") then
				entry.link = link
			end
			return entry
		end
	end
	return nil
end


local function addItem(input)
	local entry = resolve(input)
	if not entry then
		msg("Usage: /rrt add <item link, ID or name>")
		return
	end
	for _, e in ipairs(DB.items) do
		if e.key == entry.key or (entry.id and e.id == entry.id) then
			msg("Already tracked: " .. entryLabel(e))
			return
		end
	end
	DB.items[#DB.items + 1] = entry
	if entry.id and entry.name then
		DB.history[entry.id] = { name = entry.name, link = entry.link, t = time() }
	end
	msg("Tracking " .. entryLabel(entry))
	scanCommission()
	refresh()
end

local function removeItem(index)
	local entry = table.remove(DB.items, index)
	if entry then
		msg("Stopped tracking " .. entryLabel(entry))
	end
	refresh()
end

local function count(player, key)
	return DB.counts[player] and DB.counts[player][key] or 0
end

local function total(player)
	local sum = 0
	for _, entry in ipairs(DB.items) do
		sum = sum + count(player, entry.key)
	end
	return sum
end

local checkRound -- announces a finished round, defined with the group chat code below
local checkBreak -- announces a loot out of turn, defined there too

local function addCount(player, key, n)
	DB.counts[player] = DB.counts[player] or {}
	local value = math.max(0, (DB.counts[player][key] or 0) + n)
	DB.counts[player][key] = value
	refresh()
	if n > 0 then
		checkRound(key)
	end
end

local function setCount(player, key, n)
	DB.counts[player] = DB.counts[player] or {}
	DB.counts[player][key] = math.max(0, math.floor(n))
	refresh()
	checkRound(key)
end

local function reset()
	wipe(DB.counts)
	wipe(DB.rounds)
	wipe(DB.proven)
	DB.since = time()
	DB.missed = 0
	msg("Counts reset.")
	refresh()
end

---------------------------------------------------------------------------------------------------------
-- loot lines (the client's own localized formats)
---------------------------------------------------------------------------------------------------------

local function fmtPattern(fmt)
	if type(fmt) ~= "string" then
		return nil
	end
	local order, n = {}, 0
	local p = fmt:gsub("%%(%d?)%$?([sd])", function(pos, kind)
		n = n + 1
		order[#order + 1] = tonumber(pos) or n
		return kind == "d" and "\001" or "\002"
	end)
	p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	p = p:gsub("\001", "(%%d+)"):gsub("\002", "(.+)")
	if p:sub(-2) == "%." then
		p = p:sub(1, -3) .. "%.?" -- "You receive loot: [x]" can arrive without the final period
	end
	return "^" .. p .. "$", order
end

-- { global, English fallback, about you, fields in argument order }
local LOOT_LINES = {
	{ "LOOT_ITEM_SELF_MULTIPLE", "You receive loot: %sx%d.", true, { "item", "n" } },
	{ "LOOT_ITEM_SELF", "You receive loot: %s.", true, { "item" } },
	{ "LOOT_ITEM_MULTIPLE", "%s receives loot: %sx%d.", false, { "who", "item", "n" } },
	{ "LOOT_ITEM", "%s receives loot: %s.", false, { "who", "item" } },
	-- roll wins: the "receives loot" line does not always follow, so the win counts and that line is skipped
	{ "LOOT_ROLL_YOU_WON", "You won: %s", true, { "item" }, true },
	{ "LOOT_ROLL_WON", "%s won: %s", false, { "who", "item" }, true },
}
local WON_WINDOW = 120 -- seconds a win waits for its "receives loot" line
local patterns

local function parseLootLine(text)
	if not patterns then
		patterns = {}
		for _, def in ipairs(LOOT_LINES) do
			local pattern, order = fmtPattern(_G[def[1]] or def[2])
			if pattern then
				patterns[#patterns + 1] =
					{ pattern = pattern, order = order, self = def[3], fields = def[4], won = def[5] }
			end
		end
	end
	for _, lp in ipairs(patterns) do
		local caps = { text:match(lp.pattern) }
		if #caps > 0 then
			local out = {}
			for j, value in ipairs(caps) do
				local field = lp.fields[lp.order[j] or j]
				if field then
					out[field] = value
				end
			end
			if lp.self then
				out.who = me()
			end
			out.won = lp.won
			return out
		end
	end
	return nil
end

local function rememberSeen(link)
	local id = tonumber(link:match("item:(%d+)"))
	local name = link:match("%[(.-)%]")
	if id and name then
		DB.seen[id] = { name = name, link = link:find("|H") and link or nil, t = time() }
	end
end

local wins = {} -- ["player|item key"] = times of counted roll wins still waiting for their loot line

local function onLootChat(text)
	text = plain(text)
	if type(text) ~= "string" then
		if #DB.items > 0 then
			DB.missed = DB.missed + 1
			refresh()
		end
		return
	end
	local line = parseLootLine(text)
	if not line or not line.item then
		return
	end
	rememberSeen(line.item)
	if #DB.items == 0 then
		return
	end
	local entry = findTracked(line.item)
	if not entry then
		return
	end
	local who = canonical(line.who)
	if not who then
		return
	end
	local n = tonumber(line.n) or 1
	local wonKey = squash(who) .. "|" .. entry.key
	local now = GetTime()
	if line.won then
		wins[wonKey] = wins[wonKey] or {}
		table.insert(wins[wonKey], now)
	else
		-- the "receives loot" line of a win that was already counted
		local list = wins[wonKey]
		while list and list[1] and now - list[1] > WON_WINDOW do
			table.remove(list, 1)
		end
		if list and list[1] then
			table.remove(list, 1)
			n = n - 1
			if n <= 0 then
				return
			end
		end
	end
	if needsCommission(entry) then
		DB.proven[squash(who)] = true -- a Scourgestone drops only with the commission, whatever the buff read says
	end
	checkBreak(who, entry, count(who, entry.key))
	addCount(who, entry.key, n)
end

---------------------------------------------------------------------------------------------------------
-- report to group chat (only on your click or slash command)
---------------------------------------------------------------------------------------------------------

local function players()
	local list, seen = {}, {}
	for _, name in ipairs(roster()) do
		seen[name] = true
		list[#list + 1] = name
	end
	for name in pairs(DB.counts) do
		if not seen[name] and total(name) > 0 then
			list[#list + 1] = name
		end
	end
	-- alphabetical, ignoring case
	table.sort(list, function(a, b)
		local la, lb = lower(a), lower(b)
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return list
end

local function groupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	end
	if IsInRaid() then
		return "RAID"
	end
	if IsInGroup() then
		return "PARTY"
	end
	return nil
end

local function chatLocked()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and plain(C_ChatInfo.InChatMessagingLockdown()) and true
		or false
end

local function sendChat(text, channel)
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	pcall(send, text, channel)
end

-- group messages wait here while chat is locked (combat on Forever); a waiting report is built when it is sent,
-- so it shows the counts of that moment and several requests post one report
local outbox, outboxTicker = {}, nil
local reportPending = false
local reportLines -- defined below

local function sendReportNow(channel)
	local lines = reportLines()
	sendChat(lines[1], channel)
	-- one line per player, spaced out like Details so the chat throttle keeps them in order
	for i = 2, #lines do
		C_Timer.After((i - 1) * 0.25, function()
			sendChat(lines[i], channel)
		end)
	end
end

local function flushOutbox()
	local channel = groupChannel()
	if not channel then
		wipe(outbox) -- left the group: nobody to tell
		reportPending = false
	elseif not chatLocked() then
		while #outbox > 0 do
			sendChat(table.remove(outbox, 1), channel)
		end
		if reportPending then
			reportPending = false
			if #DB.items > 0 then
				sendReportNow(channel)
			end
		end
	end
	if #outbox == 0 and not reportPending and outboxTicker then
		outboxTicker:Cancel()
		outboxTicker = nil
	end
end

local function waitForChat()
	if (#outbox > 0 or reportPending) and not outboxTicker then
		outboxTicker = C_Timer.NewTicker(1, flushOutbox)
	end
end

local function sendToGroup(text)
	outbox[#outbox + 1] = text
	flushOutbox()
	waitForChat()
end

local function queueReport()
	reportPending = true
	flushOutbox()
	waitForChat()
end

local function nameList(names)
	return table.concat(names, ", ", 1, math.min(#names, 3)) .. (#names > 3 and ", ..." or "")
end

-- every name, as long as it fits one chat line
local function fullNameList(names)
	local text, shown = "", 0
	for _, name in ipairs(names) do
		local nextText = shown == 0 and name or (text .. ", " .. name)
		if #nextText > 120 then
			break
		end
		text, shown = nextText, shown + 1
	end
	if shown < #names then
		text = text .. " +" .. (#names - shown) .. " more"
	end
	return text
end

local function entryByKey(key)
	for _, entry in ipairs(DB.items) do
		if entry.key == key then
			return entry
		end
	end
end

-- round N of an item is complete once everyone in the group who takes part has at least N
checkRound = function(key)
	if not DB.announce or not groupChannel() then
		return
	end
	local entry = entryByKey(key)
	if not entry then
		return
	end
	scanCommission()
	local low, taking = nil, 0
	for _, name in ipairs(roster()) do
		if eligible(name, entry) then
			local n = count(name, key)
			low = low and math.min(low, n) or n
			taking = taking + 1
		end
	end
	if taking < 2 or low <= (DB.rounds[key] or 0) then
		return
	end
	DB.rounds[key] = low
	local text = "Round Robin: " .. entryLabel(entry) .. " round " .. low .. " complete"
	local out = leftOut(entry)
	if #out > 0 then
		text = text .. " (left out: " .. fullNameList(out) .. " - no " .. COMMISSION_NAME .. ")"
	end
	sendToGroup(text)
end

-- the lowest count of an item among those who take part (leaving out one player): low, names with it,
-- whether that player is in the group, how many take part
local function lowest(entry, except)
	local key = entry.key
	local low, inGroup, taking = nil, false, 0
	local function skip(name)
		return except and squash(name) == squash(except)
	end
	for _, name in ipairs(roster()) do
		if skip(name) then
			inGroup = true
		elseif eligible(name, entry) then
			local n = count(name, key)
			low = low and math.min(low, n) or n
		end
		if eligible(name, entry) then
			taking = taking + 1
		end
	end
	local names = {}
	for _, name in ipairs(roster()) do
		if not skip(name) and eligible(name, entry) and count(name, key) == low then
			names[#names + 1] = name
		end
	end
	return low, names, inGroup, taking
end

-- someone loots while they already have more than the lowest member: out of turn
checkBreak = function(who, entry, before)
	if not DB.announce or not groupChannel() then
		return
	end
	local low, owed, inGroup, size = lowest(entry, who)
	if size < 2 or not inGroup or not low or before <= low or not eligible(who, entry) then
		return
	end
	sendToGroup(("Round Robin: %s broke the round on %s (had %d, %s %s %d)"):format(
		who, entryLabel(entry), before, nameList(owed), #owed == 1 and "has" or "have", low))
end

-- a tracked item is up for rolling: say whose turn it is, then the report (the only automatic report)
local rollTimer

local function onRollStart(rollID)
	if not DB.autoReport or #DB.items == 0 or not groupChannel() or not GetLootRollItemLink then
		return
	end
	local ok, link = pcall(GetLootRollItemLink, rollID)
	link = ok and plain(link)
	if type(link) ~= "string" then
		return
	end
	rememberSeen(link)
	local entry = findTracked(link)
	if not entry then
		return
	end
	scanCommission()
	local low, turn, _, size = lowest(entry)
	if size >= 2 and low then
		sendToGroup(("Round Robin: %s up for roll, turn: %s (%d)"):format(entryLabel(entry), nameList(turn), low))
	end
	-- several items roll at once: one report after the last of them
	if rollTimer then
		rollTimer:Cancel()
	end
	rollTimer = C_Timer.NewTimer(0.5, function()
		rollTimer = nil
		queueReport()
	end)
end


-- Details-style table: a header with the items, then "1. Name ....... 5 / 3" per player.
-- The dots are measured in the chat font so the numbers start in one column.
local measure

local function textWidth(text)
	if not measure then
		local holder = CreateFrame("Frame")
		holder:Hide()
		measure = holder:CreateFontString(nil, "BACKGROUND", ChatFontNormal and "ChatFontNormal" or "GameFontNormal")
		local size = FCF_GetChatWindowInfo and select(2, FCF_GetChatWindowInfo(1))
		local face, _, flags = measure:GetFont()
		if face and size and size >= 1 then
			measure:SetFont(face, size, flags)
		end
	end
	measure:SetText(text)
	return measure:GetStringWidth() or 0
end

local function padTo(text, width)
	text = text .. " "
	for _ = 1, 80 do
		if textWidth(text) >= width then
			break
		end
		text = text .. "."
	end
	return text
end

reportLines = function()
	local labels, names = {}, {}
	for _, entry in ipairs(DB.items) do
		labels[#labels + 1] = entryLabel(entry)
		names[#names + 1] = entry.name or ("item " .. tostring(entry.id))
	end
	local since = " (since " .. date("%H:%M", DB.since) .. ")"
	local header = "Round Robin: " .. table.concat(labels, " / ") .. since
	if #header > 250 then
		header = "Round Robin: " .. table.concat(names, " / ") .. since -- links too long for one message
	end
	if #header > 255 then
		header = header:sub(1, 252) .. "..."
	end
	local lines = { header }
	local list = players()
	local rows, widest = {}, textWidth("DEFAULT NAME")
	for i, name in ipairs(list) do
		local left = i .. ". " .. name
		rows[i] = left
		widest = math.max(widest, textWidth(left .. " "))
	end
	widest = math.min(widest, 160) + textWidth("....") -- the longest name gets a few dots too
	for i, name in ipairs(list) do
		local values = {}
		for _, entry in ipairs(DB.items) do
			values[#values + 1] = eligible(name, entry) and tostring(count(name, entry.key)) or "-"
		end
		lines[#lines + 1] = padTo(rows[i], widest) .. " " .. table.concat(values, " / ")
	end
	return lines
end

local function report()
	if #DB.items == 0 then
		msg("No items tracked.")
		return
	end
	if not groupChannel() then
		for _, line in ipairs(reportLines()) do
			msg(line)
		end
		return
	end
	if chatLocked() then
		msg("Chat locked (combat). Report posts when it opens.")
	end
	queueReport()
end

---------------------------------------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------------
-- add box suggestions: your bags, items in recent loot lines, items tracked before
---------------------------------------------------------------------------------------------------------

local MAX_SUGGEST = 500 -- matches kept for the dropdown (it scrolls)
local DROP_ROWS = 12 -- rows shown at once

-- lower case without apostrophes: "corruptors" finds "Corruptor's"
local function norm(name)
	return (lower(name):gsub("'", ""))
end

-- 0 = name starts with it, 1 = a word starts with it, 2 = inside a word, 3 = every typed word somewhere
local function matchClass(name, text, words)
	local at = name:find(text, 1, true)
	if at == 1 then
		return 0
	end
	while at do
		if not name:sub(at - 1, at - 1):match("%w") then
			return 1
		end
		at = name:find(text, at + 1, true)
	end
	if #words < 2 then
		return nil
	end
	for _, w in ipairs(words) do
		if not name:find(w, 1, true) then
			return nil
		end
	end
	return 3
end

local function bagItems(out)
	local container = C_Container
	if not container or not container.GetContainerNumSlots then
		return
	end
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		for slot = 1, container.GetContainerNumSlots(bag) or 0 do
			local info = container.GetContainerItemInfo and container.GetContainerItemInfo(bag, slot)
			local link = info and plain(info.hyperlink)
			local id = info and plain(info.itemID)
			if id and link and not out[id] then
				out[id] = { id = id, name = link:match("%[(.-)%]"), link = link, rank = 1, t = 0 }
			end
		end
	end
end

local function suggestions(text)
	if text:find("|", 1, true) or tonumber(text) then
		return {} -- a link or an item ID: nothing to complete
	end
	text = norm(text):match("^%s*(.-)%s*$"):gsub("%s+", " ")
	local words = {}
	for w in text:gmatch("%S+") do
		words[#words + 1] = w
	end
	local all = {}
	for id, s in pairs(DB.seen) do
		all[id] = { id = id, name = s.name, link = s.link, rank = 2, t = s.t or 0 }
	end
	for id, s in pairs(DB.history) do
		if not all[id] then
			all[id] = { id = id, name = s.name, link = s.link, rank = 3, t = s.t or 0 }
		end
	end
	bagItems(all)
	local tracked = {}
	for _, e in ipairs(DB.items) do
		if e.id then
			tracked[e.id] = true
		end
	end
	local list = {}
	for id, s in pairs(all) do
		local class = s.name and (text == "" and 0 or matchClass(norm(s.name), text, words))
		if class and not tracked[id] then
			s.class = class
			list[#list + 1] = s
		end
	end
	-- every item of the game, from 2 letters on
	if #text >= 2 then
		for id, low in pairs(lowerNames()) do
			if not all[id] and not tracked[id] then
				local class = matchClass(low, text, words)
				if class then
					list[#list + 1] = { id = id, name = ITEMS[id], rank = 4, t = 0, class = class }
				end
			end
		end
	end
	for _, s in ipairs(list) do
		s.exact = (norm(s.name) == text) and 0 or 1
		s.known = (s.rank < 4) and 0 or 1
	end
	-- exact name, then your bags / loot / past items, then the rest; name start, word start, inside
	table.sort(list, function(a, b)
		if a.exact ~= b.exact then
			return a.exact < b.exact
		end
		if a.known ~= b.known then
			return a.known < b.known
		end
		if a.class ~= b.class then
			return a.class < b.class
		end
		if text == "" and a.t ~= b.t then
			return a.t > b.t -- empty box: newest loot first
		end
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		if #a.name ~= #b.name then
			return #a.name < #b.name -- "Runecloth" before "Runecloth Bag"
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	for i = #list, MAX_SUGGEST + 1, -1 do
		list[i] = nil
	end
	return list
end

local NAME_W, COL_W, ROW_H, MAX_ROWS = 110, 36, 16, 20
local frame, addBox, plusButton, emptyText, sinceText, resetButton, cellEdit
local iconButtons, rows = {}, {}
local scroll = 0

local function classColor(name)
	local class = DB.classes[name]
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then
		return c.r, c.g, c.b
	end
	return 1, 1, 1
end

local function showItemTooltip(owner, entry)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	if entry.link and entry.link:find("|H") then
		GameTooltip:SetHyperlink(entry.link:match("|H(.-)|h") or entry.link)
	elseif entry.id then
		GameTooltip:SetItemByID(entry.id)
	else
		GameTooltip:AddLine(entry.name or "?")
	end
	GameTooltip:AddLine("Rounds done: " .. (DB.rounds[entry.key] or 0), 1, 0.82, 0)
	GameTooltip:AddLine("Right-click: stop tracking", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function takeCursorItem()
	local kind, id, link = GetCursorInfo()
	if kind == "item" then
		ClearCursor()
		addItem(link or tostring(id))
		return true
	end
	return false
end

local function makeButton(parent, text, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 20)
	b:SetText(text)
	return b
end

local function buildFrame()
	frame = CreateFrame("Frame", "RoundRobinTrackerFrame", UIParent, "BackdropTemplate")
	frame:SetSize(300, 200)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, rel, x, y = self:GetPoint()
		DB.pos = { point, rel, x, y }
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.85)
	if DB.pos then
		frame:ClearAllPoints()
		frame:SetPoint(DB.pos[1], UIParent, DB.pos[2], DB.pos[3], DB.pos[4])
	end
	frame:SetScript("OnHide", function()
		DB.shown = false
	end)
	frame:SetScript("OnShow", function()
		DB.shown = true
		refresh()
	end)
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		scroll = scroll - delta
		refresh()
	end)
	frame:Hide() -- toggle() shows it

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -9)
	title:SetText("Round Robin")
	sinceText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sinceText:SetPoint("LEFT", title, "RIGHT", 8, 0)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	plusButton = CreateFrame("Button", nil, frame)
	plusButton:SetSize(22, 22)
	plusButton:SetNormalTexture("Interface\\PaperDollInfoFrame\\Character-Plus")
	plusButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	plusButton:RegisterForClicks("LeftButtonUp")
	plusButton:SetScript("OnClick", function()
		if takeCursorItem() then
			return
		end
		if addBox:IsShown() then
			addBox:Hide()
		else
			addBox:Show()
			addBox:SetFocus()
		end
	end)
	plusButton:SetScript("OnReceiveDrag", takeCursorItem)
	plusButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Add item")
		GameTooltip:AddLine("Drop an item here", 1, 1, 1)
		GameTooltip:AddLine("or click, then Shift-click an item", 1, 1, 1)
		GameTooltip:AddLine("or type ID / name + Enter", 1, 1, 1)
		GameTooltip:Show()
	end)
	plusButton:SetScript("OnLeave", GameTooltip_Hide)

	addBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	addBox:SetSize(200, 20)
	addBox:SetAutoFocus(false)
	addBox:Hide()
	-- dropdown with suggestions under the add box
	local drop = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	addBox.drop = drop
	drop:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", -6, 0)
	drop:SetFrameStrata("DIALOG")
	drop:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	drop:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
	drop:Hide()
	drop.buttons, drop.list, drop.sel, drop.offset = {}, {}, 0, 0
	drop.more = drop:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	drop.more:SetPoint("BOTTOMRIGHT", -6, 4)

	local function accept(s)
		addBox:SetText("")
		addBox:Hide()
		addItem(s.link or tostring(s.id))
	end

	local function getButton(i)
		local b = drop.buttons[i]
		if not b then
			b = CreateFrame("Button", nil, drop)
			b:SetHeight(18)
			b.icon = b:CreateTexture(nil, "ARTWORK")
			b.icon:SetSize(16, 16)
			b.icon:SetPoint("LEFT", 2, 0)
			b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
			b.text:SetPoint("RIGHT", -2, 0)
			b.text:SetJustifyH("LEFT")
			b.selected = b:CreateTexture(nil, "BACKGROUND")
			b.selected:SetAllPoints()
			b.selected:SetColorTexture(1, 0.82, 0, 0.25)
			b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			b:SetScript("OnClick", function(self)
				local item = drop.list[self.index]
				if item then
					accept(item)
				end
			end)
			-- the wheel over a row scrolls the list too
			b:EnableMouseWheel(true)
			b:SetScript("OnMouseWheel", function(_, delta)
				local onWheel = drop:GetScript("OnMouseWheel")
				if onWheel then
					onWheel(drop, delta)
				end
			end)
			drop.buttons[i] = b
		end
		return b
	end

	-- draws rows offset+1 .. offset+DROP_ROWS of drop.list
	local function drawDrop()
		local list = drop.list
		local shown = math.min(#list, DROP_ROWS)
		drop.offset = math.max(0, math.min(drop.offset, #list - shown))
		local w = math.max(220, addBox:GetWidth() + 12)
		for i = 1, shown do
			local s = list[drop.offset + i]
			local b = getButton(i)
			b.index = drop.offset + i
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 18)
			b:SetWidth(w - 8)
			b.icon:SetTexture(itemIcon(s))
			local label = s.link or s.name
			if not s.link and C_Item and C_Item.GetItemQualityByID then
				local q = C_Item.GetItemQualityByID(s.id) -- only known for items the client has seen
				local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
				if color and color.hex then
					label = color.hex .. s.name .. "|r"
				end
			end
			b.text:SetText(label)
			b.selected:SetShown(b.index == drop.sel)
			b:Show()
		end
		for i = shown + 1, #drop.buttons do
			drop.buttons[i]:Hide()
		end
		local footer = 0
		if #list > shown then
			drop.more:SetText((drop.offset + 1) .. "-" .. (drop.offset + shown) .. " of " .. #list
				.. (#list >= MAX_SUGGEST and "+" or "") .. "  (scroll)")
			drop.more:Show()
			footer = 14
		else
			drop.more:Hide()
		end
		drop:SetSize(w, shown * 18 + 8 + footer)
	end

	local function updateDrop()
		local list = addBox:IsShown() and suggestions(addBox:GetText()) or {}
		drop.list = list
		drop.offset = 0
		drop.sel = (#list > 0 and addBox:GetText() ~= "") and 1 or 0
		if #list == 0 then
			drop:Hide()
			return
		end
		drawDrop()
		drop:Show()
	end
	addBox.updateDrop = updateDrop

	drop:EnableMouseWheel(true)
	drop:SetScript("OnMouseWheel", function(_, delta)
		drop.offset = drop.offset - delta * 3
		drawDrop()
	end)

	addBox:SetScript("OnTextChanged", function()
		updateDrop()
	end)
	addBox:SetScript("OnArrowPressed", function(_, key)
		local n = #drop.list
		if n == 0 then
			return
		end
		if key == "DOWN" then
			drop.sel = drop.sel % n + 1
		elseif key == "UP" then
			drop.sel = (drop.sel - 2) % n + 1
		end
		-- keep the selection on screen
		if drop.sel <= drop.offset then
			drop.offset = drop.sel - 1
		elseif drop.sel > drop.offset + DROP_ROWS then
			drop.offset = drop.sel - DROP_ROWS
		end
		drawDrop()
	end)
	addBox:SetScript("OnTabPressed", function()
		local s = drop.list[math.max(drop.sel, 1)]
		if s then
			accept(s)
		end
	end)
	addBox:SetScript("OnEnterPressed", function(self)
		local s = drop:IsShown() and drop.list[drop.sel]
		if s then
			accept(s)
			return
		end
		local text = self:GetText()
		self:SetText("")
		self:Hide()
		if text ~= "" then
			addItem(text)
		end
	end)
	addBox:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:Hide()
	end)
	addBox:SetScript("OnHide", function()
		drop:Hide()
		refresh()
	end)
	addBox:SetScript("OnShow", function()
		refresh()
		updateDrop()
	end)

	-- typing a corrected number into a cell
	cellEdit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	cellEdit:SetSize(COL_W - 8, ROW_H)
	cellEdit:SetAutoFocus(false)
	cellEdit:SetNumeric(true)
	cellEdit:SetMaxLetters(5)
	cellEdit:SetJustifyH("CENTER")
	cellEdit:SetFrameLevel(frame:GetFrameLevel() + 10)
	cellEdit:Hide()
	cellEdit:SetScript("OnEnterPressed", function(self)
		local n = tonumber(self:GetText())
		local player, key = self.player, self.key
		self:Hide()
		if n and player and key then
			setCount(player, key, n)
		end
	end)
	cellEdit:SetScript("OnEscapePressed", function(self)
		self:Hide()
	end)
	cellEdit:SetScript("OnEditFocusLost", function(self)
		self:Hide()
	end)

	emptyText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	emptyText:SetText("Add an item with +")

	resetButton = makeButton(frame, "Reset", 70)
	resetButton:SetPoint("BOTTOMLEFT", 8, 8)
	resetButton:SetScript("OnClick", function(self)
		if self.armed and GetTime() - self.armed < 4 then
			self.armed = nil
			self:SetText("Reset")
			reset()
		else
			self.armed = GetTime()
			self:SetText("Sure?")
			C_Timer.After(4, function()
				if self.armed and GetTime() - self.armed >= 4 then
					self.armed = nil
					self:SetText("Reset")
				end
			end)
		end
	end)
	local reportButton = makeButton(frame, "Report", 70)
	reportButton:SetPoint("LEFT", resetButton, "RIGHT", 4, 0)
	reportButton:SetScript("OnClick", report)
	reportButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Post counts to group chat")
		GameTooltip:Show()
	end)
	reportButton:SetScript("OnLeave", GameTooltip_Hide)
end

local function iconButton(i)
	local b = iconButtons[i]
	if not b then
		b = CreateFrame("Button", nil, frame)
		b:SetSize(22, 22)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetAllPoints()
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				GameTooltip:Hide()
				removeItem(self.index)
			elseif IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then
				local entry = DB.items[self.index]
				if entry and entry.link then
					HandleModifiedItemClick(entry.link)
				end
			end
		end)
		b:SetScript("OnEnter", function(self)
			local entry = DB.items[self.index]
			if entry then
				showItemTooltip(self, entry)
			end
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		iconButtons[i] = b
	end
	return b
end

local function cell(row, i)
	local c = row.cells[i]
	if not c then
		c = CreateFrame("Button", nil, row)
		c:SetSize(COL_W, ROW_H)
		c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		c.text:SetAllPoints()
		c.text:SetJustifyH("CENTER")
		c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		c:SetScript("OnClick", function(self, button)
			local entry = DB.items[self.index]
			if not entry or not self.player then
				return
			end
			if button == "RightButton" then
				addCount(self.player, entry.key, -1)
			elseif IsShiftKeyDown() then
				addCount(self.player, entry.key, 1)
			else
				GameTooltip:Hide()
				cellEdit.player, cellEdit.key = self.player, entry.key
				cellEdit:ClearAllPoints()
				cellEdit:SetPoint("CENTER", self, "CENTER", 2, 0)
				cellEdit:SetText(tostring(count(self.player, entry.key)))
				cellEdit:Show()
				cellEdit:SetFocus()
				cellEdit:HighlightText()
			end
		end)
		c:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if self.leftOut then
				GameTooltip:AddLine("No " .. COMMISSION_NAME, 1, 0.5, 0.5)
				GameTooltip:AddLine("Left out of this round robin", 1, 1, 1)
			end
			GameTooltip:AddLine("Click: type a number", 1, 1, 1)
			GameTooltip:AddLine("Shift-click +1, right-click -1", 1, 1, 1)
			GameTooltip:Show()
		end)
		c:SetScript("OnLeave", GameTooltip_Hide)
		row.cells[i] = c
	end
	return c
end

local function getRow(i)
	local row = rows[i]
	if not row then
		row = CreateFrame("Frame", nil, frame)
		row:SetHeight(ROW_H)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(1, 1, 1, 0.05)
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetWidth(NAME_W - 6)
		row.name:SetJustifyH("LEFT")
		row.cells = {}
		rows[i] = row
	end
	return row
end

refresh = function()
	if not frame or not frame:IsShown() then
		return
	end
	local items = DB.items
	local width = math.max(200, 10 + NAME_W + COL_W * #items + 10)
	local since = date("%H:%M", DB.since)
	sinceText:SetText("since " .. since .. (DB.missed > 0 and ("  |cffff6060" .. DB.missed .. " lines unreadable|r") or ""))

	-- item header
	local top = -30
	for i, entry in ipairs(items) do
		local b = iconButton(i)
		b.index = i
		b.icon:SetTexture(itemIcon(entry))
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 10 + NAME_W + COL_W * (i - 1) + (COL_W - 22) / 2, top)
		b:Show()
	end
	for i = #items + 1, #iconButtons do
		iconButtons[i]:Hide()
	end
	plusButton:ClearAllPoints()
	if #items == 0 then
		plusButton:SetPoint("TOPLEFT", 10, top)
		emptyText:ClearAllPoints()
		emptyText:SetPoint("LEFT", plusButton, "RIGHT", 6, 0)
		emptyText:Show()
	else
		plusButton:SetPoint("TOPLEFT", 10 + NAME_W - 30, top)
		emptyText:Hide()
	end
	top = top - 26
	if addBox:IsShown() then
		addBox:ClearAllPoints()
		addBox:SetPoint("TOPLEFT", 16, top)
		addBox:SetWidth(width - 32)
		top = top - 24
	end

	-- players
	local list = #items > 0 and players() or {}
	-- highest / lowest per item column, over everyone listed
	local lo, hi = {}, {}
	local function note(col, n)
		lo[col] = math.min(lo[col] or n, n)
		hi[col] = math.max(hi[col] or n, n)
	end
	for _, player in ipairs(list) do
		for i, entry in ipairs(items) do
			if eligible(player, entry) then
				note(i, count(player, entry.key))
			end
		end
	end
	local function paint(fs, col, n)
		if n == nil then
			fs:SetTextColor(0.5, 0.5, 0.5) -- left out: no Argent Dawn Commission
		elseif #list > 1 and hi[col] ~= lo[col] and n == hi[col] then
			fs:SetTextColor(0.2, 1, 0.2)
		elseif #list > 1 and hi[col] ~= lo[col] and n == lo[col] then
			fs:SetTextColor(1, 0.25, 0.25)
		else
			fs:SetTextColor(1, 1, 1)
		end
	end
	local visible = math.min(#list, MAX_ROWS)
	scroll = math.max(0, math.min(scroll, #list - visible))
	for r = 1, visible do
		local player = list[r + scroll]
		local row = getRow(r)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 8, top - (r - 1) * ROW_H)
		row:SetWidth(width - 16)
		row.bg:SetShown(r % 2 == 1)
		row.name:SetText(player)
		row.name:SetTextColor(classColor(player))
		for i, entry in ipairs(items) do
			local c = cell(row, i)
			c.index = i
			c.player = player
			c:ClearAllPoints()
			c:SetPoint("LEFT", NAME_W + COL_W * (i - 1), 0)
			local n = eligible(player, entry) and count(player, entry.key) or nil
			c.leftOut = n == nil
			c.text:SetText(n or "-")
			paint(c.text, i, n)
			c:Show()
		end
		for i = #items + 1, #row.cells do
			row.cells[i]:Hide()
		end
		row:Show()
	end
	for r = visible + 1, #rows do
		rows[r]:Hide()
	end
	local height = -top + visible * ROW_H + 36
	frame:SetSize(width, height)
end

local function toggle()
	if not frame then
		buildFrame()
	end
	frame:SetShown(not frame:IsShown())
end

-- Shift-click an item while the add box has focus puts its link there
local function onInsertLink(text)
	if addBox and addBox:IsShown() and addBox:HasFocus() and type(text) == "string" and text:find("item:", 1, true) then
		addBox:SetText(text)
	end
end

---------------------------------------------------------------------------------------------------------
-- slash
---------------------------------------------------------------------------------------------------------

local function listItems()
	if #DB.items == 0 then
		msg("No items tracked.")
		return
	end
	for _, line in ipairs(reportLines()) do
		msg(line)
	end
end

SLASH_ROUNDROBINTRACKER1 = "/rrt"
SLASH_ROUNDROBINTRACKER2 = "/roundrobin"
SlashCmdList.ROUNDROBINTRACKER = function(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = lower(cmd)
	if cmd == "" then
		toggle()
	elseif cmd == "add" then
		addItem(rest)
	elseif cmd == "remove" or cmd == "del" then
		local index = tonumber(rest)
		if not index then
			local entry = resolve(rest)
			for i, e in ipairs(DB.items) do
				if entry and (e.key == entry.key or (entry.id and e.id == entry.id)) then
					index = i
				end
			end
		end
		if index and DB.items[index] then
			removeItem(index)
		else
			msg("Not tracked: " .. rest)
		end
	elseif cmd == "reset" then
		reset()
	elseif cmd == "report" then
		report()
	elseif cmd == "list" then
		listItems()
	elseif cmd == "announce" then
		if rest == "on" or rest == "off" then
			DB.announce = rest == "on"
		else
			DB.announce = not DB.announce
		end
		msg("Round announce " .. (DB.announce and "on" or "off"))
	elseif cmd == "autoreport" or cmd == "auto" then
		if rest == "on" or rest == "off" then
			DB.autoReport = rest == "on"
		else
			DB.autoReport = not DB.autoReport
		end
		msg("Auto report " .. (DB.autoReport and "on" or "off"))
	elseif cmd == "commission" or cmd == "ad" then
		DB.items[#DB.items + 1] = { key = "probe:commission", id = 12843 } -- read even when no Scourgestone is tracked
		local ok = pcall(scanCommission)
		table.remove(DB.items)
		if not ok or (InCombatLockdown and InCombatLockdown()) then
			msg("Buffs not readable in combat, last known:")
		end
		for _, name in ipairs(roster()) do
			local k = squash(name)
			local state = DB.proven[k] and "yes (looted one)"
				or DB.commission[k] == true and "yes"
				or DB.commission[k] == false and "|cffff6060no|r"
				or "unknown (counts)"
			msg(name .. ": " .. state)
		end
	else
		msg("v" .. VERSION .. " commands:")
		msg("/rrt - window")
		msg("/rrt add <item> - track (link, ID or name)")
		msg("/rrt remove <item|number>")
		msg("/rrt list | report | reset")
		msg("/rrt announce on|off - round done to group (" .. (DB.announce and "on" or "off") .. ")")
		msg("/rrt autoreport on|off - report when up for roll (" .. (DB.autoReport and "on" or "off") .. ")")
		msg("/rrt commission - who has the Argent Dawn Commission")
	end
end

---------------------------------------------------------------------------------------------------------
-- events
---------------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_LOOT")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("START_LOOT_ROLL")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == "RoundRobinTracker" then
			initDB()
		end
	elseif event == "PLAYER_LOGIN" then
		initDB()
		if ChatFrameUtil and ChatFrameUtil.InsertLink then
			hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
		end
		if ChatEdit_InsertLink then
			hooksecurefunc("ChatEdit_InsertLink", onInsertLink)
		end
		for _, entry in ipairs(DB.items) do
			if entry.id and not entry.link then
				requestItem(entry.id)
			end
		end
		if DB.shown then
			toggle()
		end
	elseif not DB then
		return
	elseif event == "CHAT_MSG_LOOT" then
		local ok, err = pcall(onLootChat, ...)
		if not ok then
			DB.lastError = tostring(err)
		end
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		pcall(scanCommission)
		refresh()
	elseif event == "UNIT_AURA" then
		local unit = ...
		if type(unit) == "string" and (unit == "player" or unit:match("^party%d") or unit:match("^raid%d"))
			and anyNeedsCommission() and not (InCombatLockdown and InCombatLockdown()) then
			local ok, changed = pcall(scanUnit, unit)
			if ok and changed then
				refresh()
			end
		end
	elseif event == "START_LOOT_ROLL" then
		local ok, err = pcall(onRollStart, ...)
		if not ok then
			DB.lastError = tostring(err)
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		pcall(scanCommission) -- aura data readable again
		flushOutbox() -- combat over: post what waited without waiting for the next tick
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		local id = ...
		for _, entry in ipairs(DB.items) do
			if entry.id == id and not entry.link then
				entry.name, entry.link = itemInfo(id)
				refresh()
			end
		end
	end
end)
