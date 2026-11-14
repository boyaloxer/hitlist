-- Hitlist: sharing the list through guild chat.
--
-- Adding or removing someone says one plain line in guild chat:
--     Hitlist Add: Name Surname
--     Hitlist Remove: Name Surname
-- Every copy of Hitlist in the guild acts on those lines, both as they are
-- said and later, from the guild chat history the server keeps. A guild member
-- without the addon can type the same line by hand.
--
-- Each line carries the time it was said, and for any one name only the newest
-- add or remove counts (H.db.log), so the lines can be read in any order, more
-- than once, and long after the fact.
local ADDON, ns = ...
local H = ns.H
local Print = H.Print
local IsSecret = H.IsSecret

local G = {}
ns.G = G

local MICRO = 1000000
local PAGE = 100            -- lines per history request, as Blizzard's own chat window asks
local MAX_PAGES = 30        -- history requests per catch-up
local MAX_AGE = 30 * 86400  -- how far back a catch-up reads, in seconds
local REQUEST_GAP = 0.5     -- seconds between history requests
local MAX_RETRIES = 5       -- catch-ups restarted in a row because chat could not be read
local RETRY_GAP = 10        -- seconds between those restarts
local MAX_LETTERS = 80      -- longest line that is looked at
local NAME_WORD = "^[A-Za-z\128-\255][A-Za-z\128-\255'%-]*$" -- bytes from 128 up are letters outside ASCII

local state = "idle"   -- "idle", "waiting" (history asked for), "paging" or "done"
local cursor           -- id of the oldest line read so far in this catch-up
local floorEpoch = 0   -- the catch-up stops once it is back this far
local pages = 0
local askedFirst       -- the first batch of history was asked for
local newest           -- stamp of the newest line read from the history
local retry = false    -- something could not be read (chat locked); read it again later
local retries = 0
local lastRetry
local batch = {}       -- changes made by the catch-up, reported when it ends

local function AnySecret(...)
	for index = 1, select("#", ...) do
		if IsSecret((select(index, ...))) then
			return true
		end
	end
	return false
end

-- True while the game restricts chat (boss fights and the like): lines cannot
-- be sent and arrive unreadable.
local function Locked()
	local check = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	return check ~= nil and check() == true
end

local function InGuild()
	return IsInGuild ~= nil and IsInGuild() == true
end

local function Sharing()
	return H.db ~= nil and H.db.guild == true and InGuild()
end

-- ---------------------------------------------------------------------------
-- The lines
-- ---------------------------------------------------------------------------

-- "Hitlist Add: Gas Giant" -> "add", "Gas Giant". Nil for anything else.
function G.Parse(text)
	if not H.IsText(text) then
		return nil
	end
	local _, letters = text:gsub("[^\128-\191]", "") -- a letter outside ASCII is several bytes
	if letters > MAX_LETTERS then
		return nil
	end
	local verb, name = text:match("^[ \t]*[Hh][Ii][Tt][Ll][Ii][Ss][Tt][ \t]+([A-Za-z]+)[ \t]*:[ \t]*(.-)[ \t]*$")
	verb = verb and verb:lower()
	if verb ~= "add" and verb ~= "remove" then
		return nil
	end
	local words = 0
	for word in name:gmatch("[^ \t]+") do
		words = words + 1
		if words > 2 or not word:find(NAME_WORD) then
			return nil
		end
	end
	if words == 0 then
		return nil
	end
	return verb, name
end

function G.Line(op, name)
	return (op == "add" and "Hitlist Add: " or "Hitlist Remove: ") .. name
end

-- Says your own add or remove in guild chat. Always called straight from a
-- click or a key press, which is what the game wants for chat an addon sends.
-- Returns true when the line was said, false when it could not be, and nil
-- when there was nothing to say.
function G:Announce(op, name)
	if not Sharing() then
		return nil
	end
	local line = G.Line(op, name)
	if not G.Parse(line) then
		return nil -- not a name other copies would accept
	end
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	local failure
	if Locked() or not send then
		failure = ""
	else
		local ok, problem = pcall(send, line, "GUILD")
		if not ok then
			-- The game's own words for it, so a refusal can be told from a lockdown.
			failure = (not IsSecret(problem) and type(problem) == "string") and (" (" .. problem:sub(1, 120) .. ")") or ""
		end
	end
	if not failure then
		return true
	end
	Print("couldn't post to guild chat right now" .. failure .. ". "
		.. (op == "add" and "Add them again later to share it, or type" or "To share it, type")
		.. " this in guild chat:  " .. line)
	return false
end

-- Acts on one guild chat line said by `author` at `when` (microseconds).
-- Changes to the list are appended to `changes`. The caller has made sure
-- that neither the text nor the author is secret.
function G:Read(text, author, when, changes)
	if not H.db then
		return
	end
	local op, name = G.Parse(text)
	local key = op and H.Key(name)
	if not key then
		return
	end
	local last = H.db.log[key]
	if last and last.t > when then
		return -- something newer is already known about this name
	end
	if type(author) ~= "string" or author == "" then
		author = "a guild member"
	end
	if op == "add" then
		if H:IsMe(name) then
			return
		end
		local listed = H:GetByKey(key)
		if listed then
			listed.unshared = nil -- the guild has been told now
			H:Stamp(key, "add", author, when)
			return
		end
		local entry = H:Add(H.CleanName(name), nil, nil, author, when)
		changes[#changes + 1] = { op = "add", name = entry.name, by = author }
	else
		local entry = H:RemoveByKey(key, author, when)
		if entry then
			changes[#changes + 1] = { op = "remove", name = entry.name, by = author }
		else
			H:Stamp(key, "remove", author, when)
		end
	end
end

local function Report(changes)
	if #changes == 0 then
		return
	end
	if #changes > 3 then
		local added, removed = 0, 0
		for _, change in ipairs(changes) do
			if change.op == "add" then
				added = added + 1
			else
				removed = removed + 1
			end
		end
		Print("caught up with guild chat: " .. added .. " added, " .. removed .. " removed.")
		return
	end
	for _, change in ipairs(changes) do
		local who = H:IsMe(change.by) and "you" or change.by
		if change.op == "add" then
			Print("|cffffffff" .. change.name .. "|r was put on the hitlist by " .. who .. ".")
		else
			Print("|cffffffff" .. change.name .. "|r was taken off the hitlist by " .. who .. ".")
		end
	end
end

-- ---------------------------------------------------------------------------
-- The guild chat history the server keeps (C_Club)
-- ---------------------------------------------------------------------------

-- Calls C_Club[name]; nil when the client has no such call or it raises.
local function Club(name, ...)
	local call = C_Club and C_Club[name]
	if not call then
		return nil
	end
	local ok, result = pcall(call, ...)
	if ok then
		return result
	end
	return nil
end

local clubId, streamId

-- The guild's club and its guild chat stream, or nil while they are unknown.
local function Stream()
	if Locked() then
		return nil
	end
	local club = Club("GetGuildClubId")
	if IsSecret(club) or not club then
		return nil
	end
	if club == clubId and streamId then
		return clubId, streamId
	end
	local streams = Club("GetStreams", club)
	if IsSecret(streams) or type(streams) ~= "table" then
		return nil
	end
	local guildType = Enum and Enum.ClubStreamType and Enum.ClubStreamType.Guild or 1
	for _, stream in ipairs(streams) do
		if not IsSecret(stream) and not AnySecret(stream.streamType, stream.streamId)
			and stream.streamType == guildType then
			clubId, streamId = club, stream.streamId
			return clubId, streamId
		end
	end
	return nil
end

local function SameId(a, b)
	return a.epoch == b.epoch and a.position == b.position
end

local function IsUsableId(id)
	return not IsSecret(id) and type(id) == "table" and not AnySecret(id.epoch, id.position)
		and type(id.epoch) == "number"
end

-- Reads one message from the history. Returns its id, or nil when it could
-- not be read.
local function Take(message, changes)
	if IsSecret(message) then
		retry = true
		return nil
	end
	if type(message) ~= "table" then
		return nil
	end
	local id, author = message.messageId, message.author
	if not IsUsableId(id) or AnySecret(message.content, message.destroyed, author) then
		retry = true
		return nil
	end
	if not message.destroyed then
		local name
		if type(author) == "table" then
			name = author.name
		end
		if IsSecret(name) then
			retry = true
		else
			G:Read(message.content, name, id.epoch, changes)
		end
	end
	if not newest or id.epoch > newest then
		newest = id.epoch
	end
	return id
end

local function Finish()
	state = "done"
	local sync = H.db.sync
	if newest and not retry and newest > (sync.upTo or 0) then
		sync.upTo = newest -- the next catch-up only has to come back this far
	end
	if not retry then
		retries = 0
	end
	local changes = batch
	batch = {}
	Report(changes)
end

-- Reads the page of history ending at `newestId` (the cursor itself the
-- first time round). False when there was nothing older to read.
local function TakePage(newestId)
	local messages = Club("GetMessagesBefore", clubId, streamId, newestId, PAGE)
	if IsSecret(messages) or type(messages) ~= "table" then
		retry = true
		state = "idle"
		return false
	end
	local oldest
	for index = #messages, 1, -1 do -- newest first: an older line never undoes a newer one
		oldest = Take(messages[index], batch) or oldest
	end
	if not oldest or (cursor and SameId(oldest, cursor)) then
		Finish()
		return false
	end
	cursor = oldest
	return true
end

-- Walks back through the history, a page at a time, until it reaches what was
-- read last time.
local function Continue()
	while state == "paging" do
		if Locked() then
			retry = true
			state = "idle"
			return
		end
		local atStart = Club("IsBeginningOfStream", clubId, streamId, cursor)
		if cursor.epoch <= floorEpoch or pages >= MAX_PAGES or (not IsSecret(atStart) and atStart == true) then
			return Finish()
		end
		pages = pages + 1
		local have = Club("RequestMoreMessagesBefore", clubId, streamId, cursor, PAGE)
		if IsSecret(have) or have ~= true then
			state = "waiting" -- CLUB_MESSAGE_HISTORY_RECEIVED carries on from here
			return
		end
		if not TakePage(cursor) then
			return
		end
	end
end

local function RangeIsEmpty(range)
	local oldest, latest = range.oldestMessageId, range.newestMessageId
	if not IsUsableId(oldest) or not IsUsableId(latest) then
		return true
	end
	return latest.epoch < oldest.epoch or (latest.epoch == oldest.epoch and latest.position < oldest.position)
end

-- Starts a catch-up: everything said in guild chat since the last one.
function G:Sync()
	if state ~= "idle" or not Sharing() or not H.db then
		return
	end
	if Locked() then
		retry = true
		return
	end
	if not Stream() then
		return -- the guild's chat is not loaded yet; an event or timer tries again
	end
	local ranges = Club("GetMessageRanges", clubId, streamId)
	if IsSecret(ranges) then
		retry = true
		return
	end
	local range
	if type(ranges) == "table" then
		range = ranges[#ranges]
	end
	if IsSecret(range) then
		retry = true
		return
	end
	if not range or RangeIsEmpty(range) then
		if askedFirst then
			return Finish() -- the server answered and there is nothing to read
		end
		askedFirst = true
		state = "waiting"
		Club("RequestMoreMessagesBefore", clubId, streamId, nil)
		return
	end

	local sync = H.db.sync
	local club = tostring(clubId)
	if sync.club ~= club then
		sync.club = club
		sync.upTo = nil -- a different guild: all of its history is news
	end
	local horizon = ((GetServerTime and GetServerTime() or time()) - MAX_AGE) * MICRO
	floorEpoch = math.max(sync.upTo or 0, horizon)

	retry = false -- everything missed so far is about to be read
	state = "paging"
	if TakePage(range.newestMessageId) then
		Continue()
	end
end

function G:State()
	return state, pages
end

-- Forgets the catch-up in progress and starts over.
function G:Restart()
	state, cursor, pages, askedFirst, newest, retry = "idle", nil, 0, nil, nil, false
	batch = {}
	self:Sync()
end

-- Chat was locked when something should have been read: read it now.
local function RetryIfDue()
	if not retry or retries >= MAX_RETRIES or (state ~= "idle" and state ~= "done") or Locked() then
		return
	end
	local now = GetTime()
	if lastRetry and now - lastRetry < RETRY_GAP then
		return
	end
	lastRetry = now
	retries = retries + 1
	G:Restart()
end

local function IsOurStream(club, stream)
	if AnySecret(club, stream) then
		return false
	end
	if not streamId then
		Stream()
	end
	return clubId ~= nil and club == clubId and stream == streamId
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local function OnHistoryReceived(club, stream)
	if state ~= "waiting" or not IsOurStream(club, stream) then
		return
	end
	if not cursor then
		state = "idle"
		return G:Sync() -- the first batch has arrived
	end
	state = "paging"
	if TakePage(cursor) then
		C_Timer.After(REQUEST_GAP, Continue)
	end
end

local function OnMessageAdded(club, stream, messageId)
	if not Sharing() or not IsOurStream(club, stream) then
		return
	end
	if Locked() then
		retry = true
		return
	end
	local changes = {}
	local message = Club("GetMessageInfo", club, stream, messageId)
	if Take(message, changes) and state == "done" and not retry then
		H.db.sync.upTo = math.max(H.db.sync.upTo or 0, newest)
	end
	Report(changes)
end

local function OnGuildChat(text, author)
	if not Sharing() then
		return
	end
	if AnySecret(text, author) then
		retry = true
		return
	end
	local changes = {}
	G:Read(text, author, H.Now(), changes)
	Report(changes)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_GUILD" then
		OnGuildChat(...)
	elseif event == "CLUB_MESSAGE_ADDED" then
		OnMessageAdded(...)
	elseif event == "CLUB_MESSAGE_HISTORY_RECEIVED" then
		OnHistoryReceived(...)
	else
		-- Guild data arriving, a zone change, or combat ending.
		G:Sync()
	end
	RetryIfDue()
end)

function G:Start()
	for _, event in ipairs({
		"CHAT_MSG_GUILD", "CLUB_MESSAGE_ADDED", "CLUB_MESSAGE_HISTORY_RECEIVED",
		"INITIAL_CLUBS_LOADED", "CLUB_STREAMS_LOADED", "PLAYER_GUILD_UPDATE",
		"PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
	}) do
		pcall(frame.RegisterEvent, frame, event) -- not every client has every one
	end
	-- The guild's chat can take a while to load after login.
	for _, delay in ipairs({ 5, 20, 60 }) do
		C_Timer.After(delay, function()
			G:Sync()
		end)
	end
end

-- ---------------------------------------------------------------------------
-- /hit guild and /hit sync
-- ---------------------------------------------------------------------------

function G:Toggle()
	H.db.guild = not H.db.guild
	if H.db.guild then
		Print("guild sharing is on: your adds and removes are posted in guild chat, and Hitlist lines in guild chat change your list.")
		self:Restart()
	else
		Print("guild sharing is off: nothing is posted in guild chat and guild chat no longer changes your list.")
	end
end

function G:Status()
	if not H.db.guild then
		Print("guild sharing is off. Turn it on with  /hit guild")
		return
	end
	if not InGuild() then
		Print("this character is not in a guild, so there is nothing to read.")
		return
	end
	if not (C_Club and C_Club.GetGuildClubId and C_Club.GetMessagesBefore) then
		Print("this client keeps no guild chat history; only lines said while you are online are read.")
		return
	end
	local upTo = H.db.sync.upTo
	local last = upTo and ("read up to " .. date("%b %d %H:%M", math.floor(upTo / MICRO))) or "nothing read yet"
	Print("guild chat history: " .. last .. " (" .. state .. ", " .. pages .. " requests). Reading it again now.")
	self:Restart()
	if state == "idle" then
		Print(Locked() and "chat is locked right now; it will be read when that ends."
			or "the guild's chat isn't loaded yet; it will be read when it is.")
	end
end
