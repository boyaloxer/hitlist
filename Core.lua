-- Hitlist: the list itself, slash commands, popups and sightings.
-- The Social window tab lives in Social.lua.
local ADDON, ns = ...

local H = {}
ns.H = H
Hitlist = H

local TAG = "|cffff4d4dHitlist|r: "
local ALERT_COOLDOWN = 120 -- seconds between "nearby" alerts for the same player
local MICRO = 1000000      -- guild chat stamps its lines in microseconds
local LOCAL_LEAD = MICRO   -- your own changes are stamped a second ahead, so their echo in guild chat is old news
local SEEN_REFRESH = 5     -- seconds between list refreshes caused by sightings

local function Print(message)
	print(TAG .. message)
end
H.Print = Print

-- ---------------------------------------------------------------------------
-- Secret values
-- This client can hand addons "secret" unit names and classes (mostly in
-- combat). They cannot be compared or stored, so anything read from a unit is
-- checked first and treated as unknown when it is secret.
-- ---------------------------------------------------------------------------

local function IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

H.IsSecret = IsSecret

local function Plain(value)
	if IsSecret(value) then
		return nil
	end
	return value
end

-- ---------------------------------------------------------------------------
-- Letters
-- A name can hold letters outside plain ASCII (accents, Cyrillic, Vietnamese
-- and so on), each stored as two or more bytes. The game's own upper() and
-- lower() are only ever given ASCII here: handed part of such a letter they
-- can break it, and a broken name can be neither posted nor matched. Case is
-- changed a whole letter at a time, and a letter that is not recognised is
-- left exactly as it is.
-- ---------------------------------------------------------------------------

local WORD = "[^ \t\r\n]+"
local BLANKS = "[ \t\r\n]+"

-- True for text made of whole, well-formed letters (valid UTF-8).
local function IsText(text)
	if type(text) ~= "string" then
		return false
	end
	local at, size = 1, #text
	while at <= size do
		local lead = text:byte(at)
		local more
		if lead >= 1 and lead <= 127 then
			more = 0
		elseif lead >= 194 and lead <= 223 then
			more = 1
		elseif lead >= 224 and lead <= 239 then
			more = 2
		elseif lead >= 240 and lead <= 244 then
			more = 3
		else
			return false
		end
		for index = at + 1, at + more do
			local byte = text:byte(index)
			if not byte or byte < 128 or byte > 191 then
				return false
			end
		end
		at = at + more + 1
	end
	return true
end
H.IsText = IsText

-- Capital letters outside ASCII, as { first, last, step } ranges of code
-- points. The small letter is `step` after its capital; a step of 1 means
-- capitals and small letters alternate through the range.
local CAPITALS = {
	{ 0x00C0, 0x00D6, 32 }, { 0x00D8, 0x00DE, 32 }, { 0x0178, 0x0178, -121 }, -- accented Latin
	{ 0x0100, 0x012F, 1 }, { 0x0132, 0x0137, 1 }, { 0x0139, 0x0148, 1 }, { 0x014A, 0x0177, 1 }, { 0x0179, 0x017E, 1 },
	{ 0x01CD, 0x01DC, 1 }, { 0x01DE, 0x01EF, 1 }, { 0x01F8, 0x021F, 1 }, { 0x0222, 0x0233, 1 },
	{ 0x0391, 0x03A1, 32 }, { 0x03A3, 0x03A9, 32 }, -- Greek
	{ 0x0400, 0x040F, 80 }, { 0x0410, 0x042F, 32 }, -- Cyrillic
	{ 0x1E00, 0x1E95, 1 }, { 0x1EA0, 0x1EFF, 1 }, -- Vietnamese and other marked Latin
}

local function Recode(code, up)
	for index = 1, #CAPITALS do
		local first, last, step = CAPITALS[index][1], CAPITALS[index][2], CAPITALS[index][3]
		if step == 1 then
			if code >= first and code <= last then
				local isSmall = (code - first) % 2 == 1
				if isSmall == up then
					return up and code - 1 or code + 1
				end
				return code
			end
		elseif up then
			if code >= first + step and code <= last + step then
				return code - step
			end
		elseif code >= first and code <= last then
			return code + step
		end
	end
	return code
end

-- One letter of two or three bytes as a capital (`up`) or a small letter.
local function Recase(letter, up)
	local a, b, c = letter:byte(1, 3)
	local code
	if #letter == 2 and a >= 194 and a <= 223 then
		code = (a - 192) * 64 + (b - 128)
	elseif #letter == 3 and a >= 224 and a <= 239 then
		code = (a - 224) * 4096 + (b - 128) * 64 + (c - 128)
	else
		return letter
	end
	local recoded = Recode(code, up)
	if recoded == code then
		return letter
	elseif recoded < 2048 then
		return string.char(192 + math.floor(recoded / 64), 128 + recoded % 64)
	end
	return string.char(224 + math.floor(recoded / 4096), 128 + math.floor(recoded / 64) % 64, 128 + recoded % 64)
end

local function Small(letter)
	return Recase(letter, false)
end

local function Lower(text)
	text = text:gsub("[A-Z]+", string.lower)
	return (text:gsub("[\194-\239][\128-\191]+", Small))
end
H.Lower = Lower

-- A word with its first letter as a capital.
local function Capitalise(word)
	if word:find("^[a-z]") then
		return word:sub(1, 1):upper() .. word:sub(2)
	end
	local first = word:match("^[\194-\239][\128-\191]+")
	if not first then
		return word
	end
	return Recase(first, true) .. word:sub(#first + 1)
end

-- ---------------------------------------------------------------------------
-- Names
-- Forever characters are "Name Surname" with no realm, so a full name can
-- contain a space. Other clients give "Name" plus an optional realm.
-- ---------------------------------------------------------------------------

local function Separators()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	local surname = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
	local realm = consts and consts.CHARACTERNAME_REALMNAME_SEPARATOR or "-"
	return surname, realm
end

function H.JoinName(first, second)
	if type(first) ~= "string" or first == "" then
		return nil
	end
	if type(second) ~= "string" or second == "" then
		return first
	end
	local surnameSeparator, realmSeparator = Separators()
	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		return first .. surnameSeparator .. second
	end
	if GetNormalizedRealmName and second == GetNormalizedRealmName() then
		return first
	end
	return first .. realmSeparator .. second
end

-- Full name of a unit, or nil when it is unknown or secret.
function H.UnitName(unit)
	local read = UnitNameUnmodified or UnitName
	local first, second = read(unit)
	if IsSecret(first) or IsSecret(second) then
		return nil
	end
	if first == UNKNOWNOBJECT then
		return nil
	end
	return H.JoinName(first, second)
end

-- The key a name is stored under: lower case, single spaces.
function H.Key(name)
	if type(name) ~= "string" then
		return nil
	end
	local surnameSeparator = Separators()
	if surnameSeparator ~= " " and surnameSeparator ~= "" then
		name = name:gsub(surnameSeparator:gsub("%p", "%%%0"), " ")
	end
	name = strtrim(name):gsub(BLANKS, " ")
	if name == "" then
		return nil
	end
	return Lower(name)
end

-- Tidies a typed name for display: single spaces, each word capitalised.
local function CleanName(text)
	if type(text) ~= "string" then
		return nil
	end
	local name = strtrim(text):gsub(BLANKS, " ")
	if name == "" then
		return nil
	end
	return (name:gsub(WORD, Capitalise))
end
H.CleanName = CleanName

local function Zone()
	local zone = GetRealZoneText and GetRealZoneText() or (GetZoneText and GetZoneText())
	zone = Plain(zone)
	if zone == "" then
		return nil
	end
	return zone
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

local function ClassHex(classToken)
	local color = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
	if not color then
		return nil
	end
	return color.colorStr or format("ff%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
end

function H:ColorName(entry)
	local hex = ClassHex(entry.class)
	if hex then
		return "|c" .. hex .. entry.name .. "|r"
	end
	return "|cffffffff" .. entry.name .. "|r"
end

-- "Lvl 42 Orc Shaman", or nil when nothing is known about them yet.
function H:Describe(entry, colored)
	local parts = {}
	if entry.level then
		parts[#parts + 1] = "Lvl " .. entry.level
	end
	if entry.race then
		parts[#parts + 1] = entry.race
	end
	if entry.classLoc then
		local hex = colored and ClassHex(entry.class)
		parts[#parts + 1] = hex and ("|c" .. hex .. entry.classLoc .. "|r") or entry.classLoc
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

function H.Date(timestamp, long)
	if not timestamp then
		return "?"
	end
	return date(long and "%b %d, %Y" or "%b %d", timestamp)
end

-- Server time in microseconds, the unit guild chat lines are stamped in.
function H.Now()
	return (GetServerTime and GetServerTime() or time()) * MICRO
end

-- "Added by you on Nov 11, 2026 in Tanaris" for the tooltip; the short form
-- for a card is "Added Nov 11 in Tanaris" or "Added Nov 11 by Some Guildie".
function H:AddedLine(entry, long)
	local mine = not entry.addedBy or self:IsMe(entry.addedBy)
	local line
	if long then
		line = "Added by " .. (mine and "you" or entry.addedBy) .. " on " .. H.Date(entry.added, true)
	else
		line = "Added " .. H.Date(entry.added)
		if not mine then
			line = line .. " by " .. entry.addedBy
		end
	end
	if entry.addedZone then
		line = line .. " in " .. entry.addedZone
	end
	return line
end

function H.Ago(timestamp)
	local seconds = time() - (timestamp or 0)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. " min ago"
	elseif seconds < 172800 then
		return math.floor(seconds / 3600) .. " hr ago"
	end
	return math.floor(seconds / 86400) .. " days ago"
end

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

local listeners = {}

function H:OnChange(callback)
	listeners[#listeners + 1] = callback
end

function H:Changed()
	for index = 1, #listeners do
		listeners[index]()
	end
end

-- Lists saved before version 1.1.3 were keyed with the game's own lower(), and
-- a name starting with a letter outside ASCII could be saved broken. Files
-- everything under the keys used now and takes out the names that cannot be
-- read. Returns the names it took out.
local function Rekey(db)
	local players, log, moved, dropped = {}, {}, {}, {}
	for old, entry in pairs(db.players) do
		local key = type(entry) == "table" and IsText(entry.name) and H.Key(entry.name) or nil
		if key then
			if not players[key] or (entry.added or 0) > (players[key].added or 0) then
				players[key] = entry
			end
			moved[old] = key
		else
			local name = type(entry) == "table" and type(entry.name) == "string" and entry.name or tostring(old)
			name = name:gsub("[\128-\255]+", "?")
			if type(entry) == "table" and type(entry.note) == "string" then
				name = name .. " (" .. entry.note .. ")"
			end
			dropped[#dropped + 1] = name
			moved[old] = false
		end
	end
	for old, record in pairs(db.log) do
		local key = moved[old]
		if key == nil and IsText(old) then
			key = H.Key(old)
		end
		if key and type(record) == "table" and (not log[key] or (record.t or 0) > (log[key].t or 0)) then
			log[key] = record
		end
	end
	db.players, db.log = players, log
	return dropped
end

function H:InitDB()
	if type(HitlistDB) ~= "table" then
		HitlistDB = {}
	end
	local db = HitlistDB
	if type(db.players) ~= "table" then
		db.players = {}
	end
	if db.alert == nil then
		db.alert = true
	end
	if db.guild == nil then
		db.guild = true -- share adds and removes through guild chat
	end
	if type(db.sync) ~= "table" then
		db.sync = {}
	end
	-- log[key] = the last add or remove known for that name, by anyone:
	-- { op = "add" | "remove", by = who, t = when in microseconds }. An older
	-- line read from guild chat later never undoes a newer change.
	if type(db.log) ~= "table" then
		db.log = {}
	end
	for key, entry in pairs(db.players) do
		if not db.log[key] then
			db.log[key] = { op = "add", by = entry.addedBy, t = (entry.added or 0) * MICRO }
		end
	end
	if (tonumber(db.version) or 1) < 2 then
		self.dropped = Rekey(db)
	end
	db.version = 2
	self.db = db
end

-- Says which names InitDB had to take out, once.
function H:ReportDropped()
	local dropped = self.dropped
	self.dropped = nil
	if dropped and #dropped > 0 then
		Print("names an older version saved wrongly were taken off your hitlist: " .. table.concat(dropped, ", ")
			.. ". Add them again when you next see them.")
	end
end

function H:GetByKey(key)
	return key and self.db and self.db.players[key] or nil
end

function H:Get(name)
	local key = H.Key(name)
	return self:GetByKey(key), key
end

function H:Has(name)
	return self:Get(name) ~= nil
end

function H:Count()
	local count = 0
	if self.db then
		for _ in pairs(self.db.players) do
			count = count + 1
		end
	end
	return count
end

function H:IsMe(name)
	local key = H.Key(name)
	return key ~= nil and key == H.Key(self.myName)
end

-- Copies what can be read from a visible unit onto its entry.
function H:Capture(entry, unit)
	local name = H.UnitName(unit)
	if name then
		entry.name = name
	end

	local classLoc, classToken = UnitClass(unit)
	classLoc, classToken = Plain(classLoc), Plain(classToken)
	if classToken then
		entry.class = classToken
		entry.classLoc = classLoc
	end

	local race = Plain((UnitRace(unit)))
	if race then
		entry.race = race
	end

	local level = Plain(UnitLevel(unit))
	if type(level) == "number" and level > 0 then
		entry.level = level
	end

	if GetGuildInfo then
		local guild = GetGuildInfo(unit)
		if not IsSecret(guild) then
			entry.guild = guild ~= "" and guild or nil
		end
	end

	entry.seen = time()
	entry.seenZone = Zone()
end

-- Keys of everyone on the list (optionally only those matching a search),
-- newest first.
function H:Sorted(search)
	local keys = {}
	if not self.db then
		return keys
	end
	search = search and search ~= "" and Lower(search) or nil
	for key, entry in pairs(self.db.players) do
		local matches = true
		if search then
			local haystack = Lower(table.concat({
				key,
				entry.note or "",
				entry.guild or "",
				entry.classLoc or "",
				entry.race or "",
			}, "\n"))
			matches = haystack:find(search, 1, true) ~= nil
		end
		if matches then
			keys[#keys + 1] = key
		end
	end
	local players = self.db.players
	table.sort(keys, function(a, b)
		local addedA, addedB = players[a].added or 0, players[b].added or 0
		if addedA ~= addedB then
			return addedA > addedB
		end
		return a < b
	end)
	return keys
end

local lastAlert = {}

-- Records the latest add or remove for a name. Without `when` it is your own
-- change, happening now.
function H:Stamp(key, op, by, when)
	self.db.log[key] = { op = op, by = by or self.myName, t = when or (H.Now() + LOCAL_LEAD) }
end

-- Adds a player (or updates the note of one already listed). `by` and `when`
-- (microseconds) are given for an add read from guild chat.
-- Returns entry, isNew, key.
function H:Add(name, note, unit, by, when)
	local key = H.Key(name)
	if not key or not self.db then
		return nil
	end
	local entry = self.db.players[key]
	local isNew = entry == nil
	if isNew then
		entry = {
			name = name,
			added = when and math.floor(when / MICRO) or time(),
			addedZone = not by and Zone() or nil,
			addedBy = by or self.myName,
		}
		self.db.players[key] = entry
		self:Stamp(key, "add", by, when)
	end
	if note and note ~= "" then
		entry.note = note
	end
	if unit then
		self:Capture(entry, unit)
		lastAlert[key] = GetTime() -- you are looking right at them; no need to announce it
	end
	self:Changed()
	return entry, isNew, key
end

function H:RemoveByKey(key, by, when)
	local entry = self:GetByKey(key)
	if not entry then
		return nil
	end
	self.db.players[key] = nil
	self:Stamp(key, "remove", by, when)
	lastAlert[key] = nil
	self:Changed()
	return entry
end

function H:SetNoteByKey(key, note)
	local entry = self:GetByKey(key)
	if not entry then
		return nil
	end
	note = note and strtrim(note) or ""
	entry.note = note ~= "" and note or nil
	self:Changed()
	return entry
end

-- ---------------------------------------------------------------------------
-- Adding and removing, with chat feedback
-- ---------------------------------------------------------------------------

-- The unit token to read details from if `name` is the player's current target.
local function TargetUnitFor(name)
	if UnitExists("target") and UnitIsPlayer("target") then
		local targetKey = H.Key(H.UnitName("target"))
		if targetKey and targetKey == H.Key(name) then
			return "target"
		end
	end
	return nil
end

-- Posts an add in guild chat. One that could not be posted is remembered on
-- the entry and tried again the next time that player is added.
function H:Share(entry)
	local posted = ns.G:Announce("add", entry.name)
	if posted ~= nil then
		entry.unshared = not posted or nil
	end
end

-- Adds a typed name. Returns the entry's key when someone new was added.
function H:AddTyped(text, note)
	local name = CleanName(text)
	if not name then
		Print("type a character name, for example  /hit add Gas Giant")
		return nil
	end
	if not IsText(name) then
		Print("that name has letters the game can't read. Target the player and use  /hit add")
		return nil
	end
	if self:IsMe(name) then
		Print("you can't put yourself on the hitlist.")
		return nil
	end
	note = note and strtrim(note) or nil
	local entry, isNew, key = self:Add(name, note, TargetUnitFor(name))
	if not entry then
		return nil
	end
	if isNew then
		Print(self:ColorName(entry) .. " is on your hitlist.")
		self:Share(entry)
		return key
	end
	if note and note ~= "" then
		Print("note updated for " .. self:ColorName(entry) .. ".")
	else
		Print(self:ColorName(entry) .. " is already on your hitlist.")
	end
	if entry.unshared then
		self:Share(entry)
	end
	return nil
end

-- Adds the current target. Returns the entry's key when someone new was added.
function H:AddTarget(note)
	if not UnitExists("target") or not UnitIsPlayer("target") then
		Print("target a player first, or type  /hit add Name")
		return nil
	end
	local name = H.UnitName("target")
	if not name then
		Print("the game is hiding that player's name right now. Try again out of combat.")
		return nil
	end
	return self:AddTyped(name, note)
end

-- Takes someone off the list because you said so, and tells the guild.
function H:Remove(key)
	local entry = self:RemoveByKey(key)
	if not entry then
		return nil
	end
	Print(self:ColorName(entry) .. " is off your hitlist.")
	ns.G:Announce("remove", entry.name)
	return entry
end

function H:RemoveTyped(text)
	local entry, key = self:Get(text)
	if not entry then
		Print("nobody called \"" .. tostring(text) .. "\" is on your hitlist.")
		return false
	end
	self:Remove(key)
	return true
end

function H:PrintList()
	local keys = self:Sorted()
	if #keys == 0 then
		Print("your hitlist is empty.")
		return
	end
	Print(#keys .. (#keys == 1 and " player" or " players") .. " on your hitlist:")
	for _, key in ipairs(keys) do
		local entry = self.db.players[key]
		local line = "  " .. self:ColorName(entry)
		local description = self:Describe(entry, true)
		if description then
			line = line .. "  " .. description
		end
		if entry.note then
			line = line .. "  |cffffd100" .. entry.note .. "|r"
		end
		print(line)
	end
end

function H:Open()
	local social = ns.S
	if social and social:Open() then
		return
	end
	if social and social.failure then
		Print("the Hitlist tab is unavailable (" .. social.failure .. ").")
	else
		Print("the Social window isn't available right now.")
	end
	self:PrintList()
end

-- ---------------------------------------------------------------------------
-- Popups
-- ---------------------------------------------------------------------------

local function EditBoxOf(dialog)
	if dialog.GetEditBox then
		return dialog:GetEditBox()
	end
	return dialog.editBox or dialog.EditBox
end

local function HidePopupFromEditBox(editBox)
	editBox:GetParent():Hide()
end

-- Asks for a name, pre-filled with the current target when that is a player
-- who is not listed yet.
function H:PromptAdd()
	local suggestion
	if UnitExists("target") and UnitIsPlayer("target") then
		local name = H.UnitName("target")
		if name and not self:IsMe(name) and not self:Has(name) then
			suggestion = name
		end
	end
	StaticPopup_Show("HITLIST_ADD", nil, nil, { name = suggestion })
end

function H:PromptNote(key)
	local entry = self:GetByKey(key)
	if entry then
		StaticPopup_Show("HITLIST_NOTE", entry.name, nil, { key = key })
	end
end

function H:PromptRemove(key)
	local entry = self:GetByKey(key)
	if entry then
		StaticPopup_Show("HITLIST_REMOVE", entry.name, nil, { key = key })
	end
end

local function AcceptAdd(text)
	local key = H:AddTyped(text)
	if key and not H:GetByKey(key).note then
		-- Ask why straight away; wait a frame so this popup can close first.
		C_Timer.After(0, function()
			H:PromptNote(key)
		end)
	end
end

local function AcceptNote(data, text)
	if data and data.key then
		H:SetNoteByKey(data.key, text)
	end
end

StaticPopupDialogs["HITLIST_ADD"] = {
	text = "Who goes on the hitlist?",
	button1 = ADD or "Add",
	button2 = CANCEL or "Cancel",
	hasEditBox = 1,
	maxLetters = 64,
	editBoxWidth = 260,
	OnShow = function(dialog, data)
		local editBox = EditBoxOf(dialog)
		editBox:SetText(data and data.name or "")
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(dialog)
		AcceptAdd(EditBoxOf(dialog):GetText())
	end,
	EditBoxOnEnterPressed = function(editBox)
		AcceptAdd(editBox:GetText())
		HidePopupFromEditBox(editBox)
	end,
	EditBoxOnEscapePressed = HidePopupFromEditBox,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["HITLIST_NOTE"] = {
	text = "What did %s do?",
	button1 = SAVE or "Save",
	button2 = CANCEL or "Cancel",
	hasEditBox = 1,
	maxLetters = 120,
	editBoxWidth = 350,
	OnShow = function(dialog, data)
		local entry = data and H:GetByKey(data.key)
		local editBox = EditBoxOf(dialog)
		editBox:SetText(entry and entry.note or "")
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(dialog, data)
		AcceptNote(data, EditBoxOf(dialog):GetText())
	end,
	EditBoxOnEnterPressed = function(editBox, data)
		AcceptNote(data, editBox:GetText())
		HidePopupFromEditBox(editBox)
	end,
	EditBoxOnEscapePressed = HidePopupFromEditBox,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["HITLIST_REMOVE"] = {
	text = "Take %s off your hitlist?",
	button1 = REMOVE or "Remove",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, data)
		if data then
			H:Remove(data.key)
		end
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- ---------------------------------------------------------------------------
-- Sightings: targeting, mousing over or getting a nameplate for someone on the
-- list updates what is known about them and raises an alert.
-- ---------------------------------------------------------------------------

function H:Alert(entry)
	local line = self:ColorName(entry) .. " is nearby"
	if entry.seenZone then
		line = line .. " in " .. entry.seenZone
	end
	local description = self:Describe(entry, true)
	if description then
		line = line .. " (" .. description .. ")"
	end
	if entry.note then
		line = line .. " - |cffffd100" .. entry.note .. "|r"
	end
	Print(line)

	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
		RaidNotice_AddMessage(RaidWarningFrame, "Hitlist: " .. entry.name .. " is nearby", ChatTypeInfo["RAID_WARNING"])
	end
	if SOUNDKIT and SOUNDKIT.RAID_WARNING then
		PlaySound(SOUNDKIT.RAID_WARNING)
	end
end

function H:Sight(unit)
	local db = self.db
	if not db or not unit or next(db.players) == nil then
		return
	end
	if not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end
	local key = H.Key(H.UnitName(unit))
	local entry = key and db.players[key]
	if not entry then
		return
	end

	local previous = entry.seen
	self:Capture(entry, unit)

	local now = GetTime()
	if db.alert and (not lastAlert[key] or now - lastAlert[key] >= ALERT_COOLDOWN) then
		lastAlert[key] = now
		self:Alert(entry)
	end
	if not previous or entry.seen - previous >= SEEN_REFRESH then
		self:Changed()
	end
end

-- ---------------------------------------------------------------------------
-- Right-click menu on player unit frames
-- ---------------------------------------------------------------------------

local function ModifyUnitMenu(_, rootDescription, contextData)
	local unit = contextData and contextData.unit
	if not unit or not H.db or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end
	local name = H.UnitName(unit)
	if not name or H:IsMe(name) then
		return
	end
	rootDescription:CreateDivider()
	if H:Has(name) then
		rootDescription:CreateButton("Remove from Hitlist", function()
			H:RemoveTyped(name)
		end)
	else
		rootDescription:CreateButton("Add to Hitlist", function()
			local key = H:AddTyped(name)
			if key then
				H:PromptNote(key)
			end
		end)
	end
end

local function HookUnitMenus()
	if not (Menu and Menu.ModifyMenu) then
		return
	end
	for _, tag in ipairs({ "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER" }) do
		Menu.ModifyMenu(tag, ModifyUnitMenu)
	end
end

-- ---------------------------------------------------------------------------
-- Unit tooltip: a red "Hitlist" line under anyone who is on the list
-- ---------------------------------------------------------------------------

local function OnUnitTooltip(tooltip)
	if tooltip ~= GameTooltip or not H.db or next(H.db.players) == nil then
		return
	end
	if tooltip.IsForbidden and tooltip:IsForbidden() then
		return
	end
	local unit
	if tooltip.GetUnit then
		local _, token = tooltip:GetUnit()
		if not IsSecret(token) and type(token) == "string" then
			unit = token
		end
	end
	unit = unit or "mouseover"
	if not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end
	if H:Has(H.UnitName(unit)) then
		tooltip:AddLine("Hitlist", 1, 0.1, 0.1)
	end
end

local function HookUnitTooltip()
	local unitType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
	if unitType and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
		TooltipDataProcessor.AddTooltipPostCall(unitType, OnUnitTooltip)
	elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetUnit") then
		GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

-- "Gas Giant: camped me" -> "Gas Giant", "camped me". Names can contain a
-- space here, so the note needs its own separator.
local function SplitNameAndNote(text)
	local name, note = text:match("^(.-)[ \t]*:[ \t]*(.*)$")
	if name then
		return name, note
	end
	return text, nil
end

local function PrintHelp()
	Print("commands")
	print("  /hit  -  open the Hitlist tab")
	print("  /hit add  -  add your target")
	print("  /hit add Name  -  add by name (add a reason with  /hit add Name: reason)")
	print("  /hit note Name: reason  -  set or change the reason")
	print("  /hit remove Name  -  take someone off the list")
	print("  /hit list  -  print the list in chat")
	print("  /hit alert  -  turn the nearby alert on or off")
	print("  /hit guild  -  turn sharing through guild chat on or off")
	print("  /hit sync  -  read guild chat again for Hitlist lines")
end

SLASH_HITLIST1 = "/hitlist"
SLASH_HITLIST2 = "/hit"
SlashCmdList["HITLIST"] = function(message)
	if not H.db then
		return
	end
	message = strtrim(message or "")
	local command, rest = message:match("^([^ \t]+)[ \t]*(.-)$")
	command = command and Lower(command) or ""
	rest = rest or ""

	if command == "" or command == "show" or command == "open" then
		H:Open()
	elseif command == "add" then
		if rest == "" then
			H:AddTarget()
		else
			local name, note = SplitNameAndNote(rest)
			H:AddTyped(name, note)
		end
	elseif command == "remove" or command == "delete" or command == "del" then
		if rest == "" then
			Print("who? For example  /hit remove Gas Giant")
		else
			H:RemoveTyped(rest)
		end
	elseif command == "note" then
		local name, note = SplitNameAndNote(rest)
		local entry, key = H:Get(name)
		if rest == "" then
			Print("whose note? For example  /hit note Gas Giant: camped me")
		elseif not entry then
			Print("nobody called \"" .. name .. "\" is on your hitlist.")
		elseif not note then
			H:PromptNote(key)
		else
			H:SetNoteByKey(key, note)
			Print("note updated for " .. H:ColorName(entry) .. ".")
		end
	elseif command == "list" then
		H:PrintList()
	elseif command == "alert" or command == "alerts" then
		H.db.alert = not H.db.alert
		Print("nearby alerts are " .. (H.db.alert and "on." or "off."))
	elseif command == "guild" then
		ns.G:Toggle()
	elseif command == "sync" then
		ns.G:Status()
	else
		PrintHelp()
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then
			H:InitDB()
		elseif H.loggedIn then
			-- The Social window can load after login; attach as soon as it exists.
			ns.S:TrySetup()
		end
	elseif event == "PLAYER_LOGIN" then
		H.loggedIn = true
		H.myName = H.UnitName("player")
		H:ReportDropped()
		HookUnitMenus()
		HookUnitTooltip()
		ns.S:TrySetup()
		ns.G:Start()
		events:RegisterEvent("PLAYER_TARGET_CHANGED")
		events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
		events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	elseif event == "PLAYER_TARGET_CHANGED" then
		H:Sight("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		H:Sight("mouseover")
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		H:Sight(arg1)
	end
end)
