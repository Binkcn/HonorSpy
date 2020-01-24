HonorSpy = LibStub("AceAddon-3.0"):NewAddon("HonorSpy", "AceConsole-3.0", "AceHook-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")

local L = LibStub("AceLocale-3.0"):GetLocale("HonorSpy", true)

local addonName = GetAddOnMetadata("HonorSpy", "Title");
local commPrefix = addonName .. "4";

local paused = false; -- pause all inspections when user opens inspect frame
local playerName = UnitName("player");
local callback = nil
local nameToTest = nil
local startRemovingFakes = false

function HonorSpy:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("HonorSpyDB", {
		factionrealm = {
			currentPlayerNumber = 0,
			currentStandings = {},
			lastStandings = {},
			last_reset = 0,
			minimapButton = {hide = false},
			actualCommPrefix = "",
			fakePlayers = {},
			corruptPlayers = {},
			goodPlayers = {}
		},
		char = {
			today_kills = {},
			estimated_honor = 0,
			original_honor = 0
		}
	}, true)

	self:SecureHook("InspectUnit");
	self:SecureHook("UnitPopup_ShowMenu");

	self:RegisterEvent("PLAYER_TARGET_CHANGED");
	self:RegisterEvent("UPDATE_MOUSEOVER_UNIT");
	self:RegisterEvent("INSPECT_HONOR_UPDATE");
	self:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN", CHAT_MSG_COMBAT_HONOR_GAIN_EVENT);
	ChatFrame_AddMessageEventFilter("CHAT_MSG_COMBAT_HONOR_GAIN", CHAT_MSG_COMBAT_HONOR_GAIN_FILTER);
	self:RegisterComm(commPrefix, "OnCommReceive")
	self:RegisterEvent("PLAYER_DEAD");
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FAKE_PLAYERS_FILTER);

	DrawMinimapIcon();
	HS_wait(5, function() HonorSpy:CheckNeedReset() end)
	HonorSpyGUI:PrepareGUI()
	PrintWelcomeMsg();
	DBHealthCheck()
end

local inspectedPlayers = {}; -- stores last_checked time of all players met
local inspectedPlayerName = nil; -- name of currently inspected player

local function StartInspecting(unitID)
	local name, realm = UnitName(unitID);
	local level = UnitLevel(unitID);

	if (paused or (realm and realm ~= "")) then
		return
	end
	if (name ~= inspectedPlayerName) then -- changed target, clear currently inspected player
		ClearInspectPlayer();
		inspectedPlayerName = nil;
	end
	if (name == nil
		or name == inspectedPlayerName
		or not UnitIsPlayer(unitID)
		or not UnitIsFriend("player", unitID)
		or not CheckInteractDistance(unitID, 1)
		or not CanInspect(unitID)) then
		return
	end
	local player = HonorSpy.db.factionrealm.currentStandings[name] or inspectedPlayers[name];
	if (player == nil) then
		inspectedPlayers[name] = {last_checked = 0};
		player = inspectedPlayers[name];
	end
	if (GetServerTime() - player.last_checked < 30) then -- 30 seconds until new inspection request
		return
	end
	-- we gonna inspect new player, clear old one
	ClearInspectPlayer();
	inspectedPlayerName = name;
	player.unitID = unitID;
	NotifyInspect(unitID);
	RequestInspectHonorData();
	_, player.rank = GetPVPRankInfo(UnitPVPRank(player.unitID)); -- rank must be get asap while mouse is still over a unit
	_, player.class = UnitClass(player.unitID); -- same
end

function HonorSpy:INSPECT_HONOR_UPDATE()
	if (inspectedPlayerName == nil or paused or not HasInspectHonorData()) then
		return;
	end
	local player = self.db.factionrealm.currentStandings[inspectedPlayerName] or inspectedPlayers[inspectedPlayerName];
	if (player == nil) then return end
	if (player.class == nil) then player.class = "nil" end

	local todayHK, _, _, _, thisweekHK, thisWeekHonor, _, lastWeekHonor, standing = GetInspectHonorData();
	player.thisWeekHonor = thisWeekHonor;
	player.lastWeekHonor = lastWeekHonor;
	player.standing = standing;

	player.rankProgress = GetInspectPVPRankProgress();
	ClearInspectPlayer();
	NotifyInspect("target"); -- change real target back to player's target, broken by prev NotifyInspect call
	ClearInspectPlayer();
	
	player.last_checked = GetServerTime();
	player.RP = 0;

	if (todayHK >= 15 or thisweekHK >= 15) then
		if (player.rank >= 3) then
			player.RP = math.ceil((player.rank-2) * 5000 + player.rankProgress * 5000)
		elseif (player.rank == 2) then
			player.RP = math.ceil(player.rankProgress * 3000 + 2000)
		end

		if (lastPlayer and lastPlayer.honor == thisWeekHonor and lastPlayer.name ~= inspectedPlayerName) then
			return
		end
		lastPlayer = {name = inspectedPlayerName, honor = thisWeekHonor}
		store_player(inspectedPlayerName, player)
		broadcast(self:Serialize(inspectedPlayerName, player))
	else
		self.db.factionrealm.currentStandings[inspectedPlayerName] = nil
	end
	inspectedPlayers[inspectedPlayerName] = {last_checked = player.last_checked};
	inspectedPlayerName = nil;
	if callback then
		callback()
		callback = nil
	end
end

-- parse message
-- COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)";
-- COMBATLOG_HONORAWARD = "You have been awarded %d honor points.";
local function parseHonorMessage(msg)
	local honor_gain_pattern = string.gsub(COMBATLOG_HONORGAIN, "%(", "%%(")
	honor_gain_pattern = string.gsub(honor_gain_pattern, "%)", "%%)")
	honor_gain_pattern = string.gsub(honor_gain_pattern, "(%%s)", "(.+)")
	honor_gain_pattern = string.gsub(honor_gain_pattern, "(%%d)", "(%%d+)")
    local victim, rank, est_honor = msg:match(honor_gain_pattern)
    if (victim) then
    	est_honor = math.max(0, math.floor(est_honor * (1-0.25*((HonorSpy.db.char.today_kills[victim] or 1)-1)) + 0.5))
    end

    local honor_award_pattern = string.gsub(COMBATLOG_HONORAWARD, "(%%d)", "(%%d+)")
    local awarded_honor = msg:match(honor_award_pattern)
    return victim, est_honor, awarded_honor
end

-- this is called before filter
function CHAT_MSG_COMBAT_HONOR_GAIN_EVENT(e, msg)
	local victim, _, awarded_honor = parseHonorMessage(msg)
    if victim then
        HonorSpy.db.char.today_kills[victim] = (HonorSpy.db.char.today_kills[victim] or 0) + 1
        local _, est_honor = parseHonorMessage(msg)
        HonorSpy.db.char.estimated_honor = HonorSpy.db.char.estimated_honor + est_honor
    elseif awarded_honor then
        HonorSpy.db.char.estimated_honor = HonorSpy.db.char.estimated_honor + awarded_honor
    end
end

-- this is called after eventg	ww
function CHAT_MSG_COMBAT_HONOR_GAIN_FILTER(_s, e, msg, ...)
	HonorSpy:CheckNeedReset()
	local victim, est_honor, awarded_honor = parseHonorMessage(msg)
	if (not victim) then
		return
	end
	return false, format("%s %s: %d, %s: |cff00FF96%d", msg, L["Today Kills"], HonorSpy.db.char.today_kills[victim] or 0, L["Estimated Honor"], est_honor), ...
end

-- INSPECT HOOKS pausing to not mess with native inspect calls
-- pause when use opens target right click menu, as it breaks "inspect" button sometimes
function HonorSpy:UnitPopup_ShowMenu(s, menu, frame, name, id)
	if (menu == "PLAYER" and not self:IsHooked(_G["DropDownList1"], "OnHide")) then
			self:SecureHookScript(_G["DropDownList1"], "OnHide", "CloseDropDownMenu")
			paused = true
		return
	end
end
function HonorSpy:CloseDropDownMenu()
	self:Unhook(_G["DropDownList1"], "OnHide")
	paused = false
end
-- pause when use opens inspect frame
function HonorSpy:InspectUnit(unitID)
	paused = true;
	if (not self:IsHooked(InspectFrame, "OnHide")) then
		self:SecureHookScript(InspectFrame, "OnHide", "InspectFrameClose");
	end
end
function HonorSpy:InspectFrameClose()
	paused = false;
end

-- INSPECTION TRIGGERS
function HonorSpy:UPDATE_MOUSEOVER_UNIT()
	StartInspecting("mouseover")
end
function HonorSpy:PLAYER_TARGET_CHANGED()
	StartInspecting("target")
end

function HonorSpy:UpdatePlayerData(cb)
	if (paused) then 
		return
	end
	callback = cb
	StartInspecting("player")
end

-- CHAT COMMANDS
local options = {
	name = 'HonorSpy',
	type = 'group',
	args = {
		show = {
			type = 'execute',
			name = L['Show HonorSpy Standings'],
			desc = L['Show HonorSpy Standings'],
			func = function() HonorSpyGUI:Toggle() end
		},
		search = {
			type = 'input',
			name = L['Report specific player standings'],
			desc = L['Report specific player standings'],
			usage = L['player_name'],
			get = false,
			set = function(info, playerName) HonorSpy:Report(playerName) end
		},
	}
}
LibStub("AceConfig-3.0"):RegisterOptionsTable("HonorSpy", options, {"honorspy", "hs"})

function HonorSpy:BuildStandingsTable(sort_by)
	local t = { }
	local sort_type = 'desc';
	local sort_column = 3; -- ThisWeekHonor

	if (sort_by == L["Standing"]) then
		sort_column = 5;
		sort_type = 'asc';
	end
	if (sort_by == L["Rank"]) then
		sort_column = 7;
		sort_type = 'desc';
	end

	for playerName, player in pairs(HonorSpy.db.factionrealm.currentStandings) do
		-- Add today honor
		thisWeekHonor = player.thisWeekHonor or 0;
		if (playerName == UnitName("player")) then
			thisWeekHonor = HonorSpy.db.char.estimated_honor;
		end

		table.insert(t, {playerName, player.class, thisWeekHonor, player.lastWeekHonor or 0, player.standing or 0, player.RP or 0, player.rank or 0, player.last_checked or 0});
	end

	local sort_func_desc = function(a,b)
		return a[sort_column] > b[sort_column];
	end

	local sort_func_asc = function(a,b)
		return a[sort_column] < b[sort_column];
	end

	if (sort_type == 'desc') then
		table.sort(t, sort_func_desc);
	else
		table.sort(t, sort_func_asc);
	end

	if (sort_type == 'asc') then
		for i = #t, 1, -1 do
			if (t[i][sort_column] == 0) then
				table.remove(t, i);
			end
		end
	end

	return t
end

-- REPORT
function HonorSpy:GetPoolSize(pool_size)
	local currentPlayerNumber = HonorSpy.db.factionrealm.currentPlayerNumber;

	if (currentPlayerNumber and type(currentPlayerNumber) == "number" and currentPlayerNumber > pool_size) then
		pool_size = currentPlayerNumber;
	end
	
	return pool_size;
end

function HonorSpy:GetBracketsByStanding(pool_size)
			  -- 1   2       3      4	  5		 6		7	   8		9	 10		11		12		13	14
	local brk =  {1, 0.845, 0.697, 0.566, 0.436, 0.327, 0.228, 0.159, 0.100, 0.060, 0.035, 0.020, 0.008, 0.003} -- brackets percentage
	local brackets = {}

	if (not pool_size) then
		return brk
	end

	pool_size = HonorSpy:GetPoolSize(pool_size);

	for i = 14, 1, -1 do
		standing = math.floor(brk[i]*pool_size+.5);
		honor = HonorSpy:EstimateQuery('Standing', standing);

		table.insert(brackets, {i, honor or 0, standing or 0})
	end

	return brackets
end

function HonorSpy:GetBrackets(pool_size)
			  -- 1   2       3      4	  5		 6		7	   8		9	 10		11		12		13	14
	local brk =  {1, 0.845, 0.697, 0.566, 0.436, 0.327, 0.228, 0.159, 0.100, 0.060, 0.035, 0.020, 0.008, 0.003} -- brackets percentage

	if (not pool_size) then
		return brk
	end

	pool_size = HonorSpy:GetPoolSize(pool_size);

	for i = 1,14 do
		brk[i] = math.floor(brk[i]*pool_size+.5)
	end
	return brk
end

function HonorSpy:EstimateQuery(queryType, queryValue)
	local tableCurr = { }
	local tableLast = { }

	local prevRowValue = 0;

	for playerName, player in pairs(HonorSpy.db.factionrealm.currentStandings) do
		table.insert(tableCurr, {playerName, player.lastWeekHonor or 0, player.standing or 0})
	end
	for playerName, player in pairs(HonorSpy.db.factionrealm.lastStandings) do
		table.insert(tableLast, {playerName, player.lastWeekHonor or 0, player.standing or 0})
	end

	if (queryType == 'Honor') then
		query_column = 2;
		get_column = 3;
		sort_column = 2;
	else
		query_column = 3;
		get_column = 2;
		sort_column = 3;
	end

	local sort_func_asc = function(a, b)
		return a[sort_column] < b[sort_column]
	end

	table.sort(tableCurr, sort_func_asc)
	table.sort(tableLast, sort_func_asc)

	local lastRowValue = 0;
	local lastRowValueDiff = 0;
	for i = 1, #tableLast do
		if (tableLast[i][query_column] > 0 and queryValue <= tableLast[i][query_column]) then
			lastRowValue = tableLast[i][get_column]
			lastRowValueDiff =  math.abs(prevRowValue - tableLast[i][query_column]);
			break
		end

		prevRowValue = tableLast[i][query_column];
	end

	local currRowValue = 0;
	local currRowValueDiff = 0;
	for i = 1, #tableCurr do
		if (tableCurr[i][query_column] > 0 and queryValue <= tableCurr[i][query_column]) then
			currRowValue = tableCurr[i][get_column]
			currRowValueDiff = math.abs(prevRowValue - tableCurr[i][query_column]);
			break
		end

		prevRowValue = tableCurr[i][query_column];
	end

	if (lastRowValue == 0 and currRowValue == 0) then
		return false
	end

	if (lastRowValue > 0 and currRowValue > 0) then
		if (lastRowValueDiff < currRowValueDiff) then
			return lastRowValue;
		else
			return currRowValue;
		end
	else
		if (lastRowValue > 0) then
			return lastRowValue;
		end

		if (currRowValue > 0) then
			return currRowValue;
		end
	end
end

function HonorSpy:Estimate(playerOfInterest)
	if (not playerOfInterest) then
		playerOfInterest = playerName
	end
	playerOfInterest = string.utf8upper(string.utf8sub(playerOfInterest, 1, 1))..string.utf8lower(string.utf8sub(playerOfInterest, 2))

	local t = HonorSpy:BuildStandingsTable()
	local standing = -1;
	local index = -1;
	local avg_lastchecked = 0;
	local pool_size = #t;

	for i = 1, pool_size do
		if (playerOfInterest == t[i][1]) then
			index = i
		end
	end

	if (index == -1) then
		return
	end;

	local thisWeekHonor = HonorSpy.db.factionrealm.currentStandings[playerOfInterest].thisWeekHonor;

	-- Add today honor
	if (playerOfInterest == UnitName("player")) then
		thisWeekHonor = HonorSpy.db.char.estimated_honor;
	end

	local estStanding = HonorSpy:EstimateQuery('Honor', thisWeekHonor);
	if (estStanding == false) then
		standing = index;
	else
		standing = estStanding;
	end

	local RP  = {0, 400} -- RP for each bracket
	local Ranks = {0, 2000} -- RP for each rank

	local bracket = 1;
	local inside_br_progress = 0;
	local brk = self:GetBrackets(pool_size)

	for i = 2,14 do
		if (standing > brk[i]) then
			inside_br_progress = (brk[i-1] - standing)/(brk[i-1] - brk[i])
			break
		end;
		bracket = i;
	end
	if (bracket == 14 and standing == 1) then inside_br_progress = 1 end;
	for i = 3,14 do
		RP[i] = (i-2) * 1000;
		Ranks[i] = (i-2) * 5000;
	end
	local award = RP[bracket] + 1000 * inside_br_progress;
	local RP = HonorSpy.db.factionrealm.currentStandings[playerOfInterest].RP;
	local EstRP = math.floor(RP*0.8+award+.5);
	local Rank = HonorSpy.db.factionrealm.currentStandings[playerOfInterest].rank;
	local EstRank = 14;
	local Progress = math.floor(HonorSpy.db.factionrealm.currentStandings[playerOfInterest].rankProgress*100);
	local EstProgress = math.floor((EstRP - math.floor(EstRP/5000)*5000) / 5000*100);
	for i = 3,14 do
		if (EstRP < Ranks[i]) then
			EstRank = i-1;
			break;
		end
	end

	return pool_size, index, standing, bracket, RP, EstRP, Rank, Progress, EstRank, EstProgress
end

function HonorSpy:Report(playerOfInterest, skipUpdate)
	if (not playerOfInterest) then
		playerOfInterest = playerName
	end
	if (playerOfInterest == playerName) then
		HonorSpy:UpdatePlayerData() -- will update for next time, this report gonna be for old data
	end
	playerOfInterest = string.utf8upper(string.utf8sub(playerOfInterest, 1, 1))..string.utf8lower(string.utf8sub(playerOfInterest, 2))
	
	local pool_size, index, standing, bracket, RP, EstRP, Rank, Progress, EstRank, EstProgress = HonorSpy:Estimate(playerOfInterest)
	if (not index) then
		self:Print(format(L["Player %s not found in table"], playerOfInterest));
		return
	end
	local text = "- HonorSpy: "
	if (playerOfInterest ~= playerName) then
		text = text .. format("%s <%s>: ", L['Progress of'], playerOfInterest)
	end
	text = text .. format("%s = %d, %s = %d, %s = %d, %s = %d (%d%%), %s = %d (%d%%)", L["Estimated Standing"], standing, L["Bracket"], bracket, L["Next Week RP"], EstRP, L["Rank"], Rank, Progress, L["Next Week Rank"], EstRank, EstProgress)
	SendChatMessage(text, "emote")
end

-- SYNCING --
function table.copy(t)
  local u = { }
  for k, v in pairs(t) do u[k] = v end
  return setmetatable(u, getmetatable(t))
end

function class_exist(className)
	if className == "WARRIOR" or 
	className == "PRIEST" or
	className == "SHAMAN" or
	className == "WARLOCK" or
	className == "MAGE" or
	className == "ROGUE" or
	className == "HUNTER" or
	className == "PALADIN" or
	className == "DRUID" then
		return true
	end
	return false
end

function playerIsValid(playerName, player)
	if (not player.last_checked or type(player.last_checked) ~= "number"
		or player.last_checked > GetServerTime()
		or not player.thisWeekHonor		or type(player.thisWeekHonor) ~= "number"
		or not player.lastWeekHonor		or type(player.lastWeekHonor) ~= "number"
		or not player.standing			or type(player.standing) ~= "number"
		or not player.RP				or type(player.RP) ~= "number"
		or not player.rankProgress		or type(player.rankProgress) ~= "number"
		or not player.rank				or type(player.rank) ~= "number"
		or not player.class				or not class_exist(player.class)
		) then
		return false
	end
	local lastPlayer = HonorSpy.db.factionrealm.lastStandings[playerName];
	if (lastPlayer ~= nil) then
		if(lastPlayer.lastWeekHonor == player.lastWeekHonor and lastPlayer.standing == player.standing) then
			return false
		end
	else
		if (player.last_checked < HonorSpy.db.factionrealm.last_reset + 24*60*60 or player.thisWeekHonor == 0) then
			return false
		end
	end

	return true
end

function isFakePlayer(playerName)
	if (HonorSpy.db.factionrealm.fakePlayers[playerName]) then
		return true
	end
	return false
end

function store_player(playerName, player)
	if (player == nil or playerName == nil or playerName:find("[%d%p%s%c%z]") or isFakePlayer(playerName) or not playerIsValid(playerName, player)) then return end

	local player = table.copy(player);

	local corruptPlayerCheck = HonorSpy.db.factionrealm.corruptPlayers[playerName];
	if (corruptPlayerCheck ~= nil) then
		if (corruptPlayerCheck >= player.last_checked) then
			return
		else
			HonorSpy.db.factionrealm.corruptPlayers[playerName] = nil;
		end
	end

	local localPlayer = HonorSpy.db.factionrealm.currentStandings[playerName];
	if (localPlayer == nil or localPlayer.last_checked < player.last_checked) then
		HonorSpy.db.factionrealm.currentStandings[playerName] = player;
		HonorSpy:TestNextFakePlayer();

		if (player.standing > HonorSpy.db.factionrealm.currentPlayerNumber) then
			HonorSpy.db.factionrealm.currentPlayerNumber = player.standing;
		end
	end

end

function HonorSpy:OnCommReceive(prefix, message, distribution, sender)
	if (distribution ~= "GUILD" and UnitRealmRelationship(sender) ~= 1) then
		return -- discard any message from players from different servers (on x-realm BGs)
	end
	local ok, playerName, player = self:Deserialize(message);
	if (not ok) then
		return;
	end
	if (sender == UnitName("player")) then
		return;	-- Ignore broadcast messages from myself
	end
	if (playerName == "filtered_players") then
		for playerName, player in pairs(player) do
			store_player(playerName, player);
		end
		return
	end
	store_player(playerName, player);
end

function broadcast(msg, skip_yell)
	if (IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and IsInInstance()) then
		HonorSpy:SendCommMessage(commPrefix, msg, "INSTANCE_CHAT");
	elseif (IsInRaid()) then
		HonorSpy:SendCommMessage(commPrefix, msg, "RAID");
	end
	if (GetGuildInfo("player") ~= nil) then
		HonorSpy:SendCommMessage(commPrefix, msg, "GUILD");
	end
	if (not skip_yell) then
		HonorSpy:SendCommMessage(commPrefix, msg, "YELL");
	end
end

-- Broadcast on death
local last_send_time = 0;
function HonorSpy:PLAYER_DEAD()
	local filtered_players, count = {}, 0;
	if (time() - last_send_time < 10*60) then return end;
	last_send_time = time();

	for playerName, player in pairs(self.db.factionrealm.currentStandings) do
		filtered_players[playerName] = player;
		count = count + 1;
		if (count == 10) then
			broadcast(self:Serialize("filtered_players", filtered_players), true)
			filtered_players, count = {}, 0;
		end
	end
	if (count > 0) then
		broadcast(self:Serialize("filtered_players", filtered_players), true)
	end
end

function FAKE_PLAYERS_FILTER(_s, e, msg, ...)
	-- not found, fake
	if (msg == ERR_FRIEND_NOT_FOUND) then
		if (not nameToTest) then
			return true
		end
		HonorSpy.db.factionrealm.currentStandings[nameToTest] = nil
		HonorSpy.db.factionrealm.fakePlayers[nameToTest] = true
		HonorSpy.db.factionrealm.goodPlayers[nameToTest] = nil
		-- HonorSpy:Print("removed non-existing player", nameToTest)
		nameToTest = nil
		return true
	end
	-- added or was in friends already, not fake
    local friend = msg:match(string.gsub(ERR_FRIEND_ADDED_S, "(%%s)", "(.+)"))
    if (not friend) then
    	friend = msg:match(string.gsub(ERR_FRIEND_ALREADY_S, "(%%s)", "(.+)"))
    end
    if (friend) then
    	HonorSpy.db.factionrealm.goodPlayers[friend] = true
    	HonorSpy.db.factionrealm.fakePlayers[friend] = nil
    	if (friend == nameToTest) then
    		HonorSpy:removeTestedFriends()
    		nameToTest = nil
    	end
    	return true
    end
end

function HonorSpy:removeTestedFriends()
	local limit = C_FriendList.GetNumFriends()
	if (type(limit) ~= "number") then
		return
	end
	for i = 1, limit do
		local f = C_FriendList.GetFriendInfoByIndex(i)
		if (f.notes == "HonorSpy testing") then
			C_FriendList.RemoveFriend(f.name)
		end
	end
end

function HonorSpy:TestNextFakePlayer()
	if (nameToTest or not startRemovingFakes) then return end

	for playerName, player in pairs(HonorSpy.db.factionrealm.currentStandings) do
		if (not HonorSpy.db.factionrealm.fakePlayers[playerName] and not HonorSpy.db.factionrealm.goodPlayers[playerName] and playerName ~= UnitName("player")) then
			nameToTest = playerName
			break
		end
	end
	if (nameToTest) then
		C_FriendList.AddFriend(nameToTest, "HonorSpy testing")
		HS_wait(1, function() HonorSpy:TestNextFakePlayer() end) 
	end
end

-- RESET WEEK
function HonorSpy:Purge(isClick)
	inspectedPlayers = {};

	if (isClick == true) then
		HonorSpy.db.factionrealm.lastStandings={};
	else
		HonorSpy.db.factionrealm.lastStandings=HonorSpy.db.factionrealm.currentStandings;
	end

	HonorSpy.db.factionrealm.currentStandings={};
	HonorSpy.db.factionrealm.fakePlayers={};
	HonorSpy.db.factionrealm.corruptPlayers={};
	HonorSpy.db.factionrealm.currentPlayerNumber = 0;
	HonorSpy.db.char.original_honor = 0;
	HonorSpyGUI:Reset();
	HonorSpy:Print(L["All data was purged"]);
end

function getResetTime()
	local currentUnixTime = GetServerTime()
	local regionId = GetCurrentRegion()
	local resetDay = 3 -- wed
	local resetHour = 7 -- 7 AM UTC

	if (regionId == 1) then -- US + BR + Oceania: 3 PM UTC Tue (7 AM PST Tue)
		resetDay = 2
		resetHour = 15
	elseif (regionId == 2 or regionId == 4 or regionId == 5) then -- Korea, Taiwan, China: 10 PM UTC Mon (7 AM KST Tue)
		resetDay = 1
		resetHour = 22
	elseif (regionId == 3) then -- EU + RU: 7 AM UTC Wed (7 AM UTC Wed)
	end

	local day = date("!%w", currentUnixTime);
	local h = date("!%H", currentUnixTime);
	local m = date("!%M", currentUnixTime);
	local s = date("!%S", currentUnixTime);

	local reset_seconds = resetDay*24*60*60 + resetHour*60*60 -- reset time in seconds from week start
	local now_seconds = s + m*60 + h*60*60 + day*24*60*60 -- seconds passed from week start
	
	local week_start = currentUnixTime - now_seconds
	local must_reset_on = 0

	if (now_seconds - reset_seconds > 0) then -- we passed this week reset time
		must_reset_on = week_start + reset_seconds
	else -- we not yet passed the reset moment in this week, still on prev week reset time
		must_reset_on = week_start - 7*24*60*60 + reset_seconds
	end

	return must_reset_on
end

function HonorSpy:ResetWeek(isClick)
	HonorSpy.db.factionrealm.last_reset = getResetTime();
	HonorSpy:Purge(isClick)
	HonorSpy:Print(L["Weekly data was reset"]);
end

function HonorSpy:CheckNeedReset(skipUpdate)
	if (not skipUpdate) then
		HonorSpy:UpdatePlayerData(function() HonorSpy:CheckNeedReset(true) end)
	end

	-- reset weekly standings
	local must_reset_on = getResetTime()
	if (HonorSpy.db.factionrealm.last_reset ~= must_reset_on) then
		HonorSpy:ResetWeek()
		HonorSpy.db.char.original_honor = 0
		HonorSpy.db.char.estimated_honor = 0
		HonorSpy.db.char.today_kills = {}
	end

	-- reset daily honor
	if (HonorSpy.db.factionrealm.currentStandings[playerName] and HonorSpy.db.char.original_honor ~= HonorSpy.db.factionrealm.currentStandings[playerName].thisWeekHonor) then
		HonorSpy.db.char.original_honor = HonorSpy.db.factionrealm.currentStandings[playerName].thisWeekHonor
		HonorSpy.db.char.estimated_honor = HonorSpy.db.char.original_honor
		HonorSpy.db.char.today_kills = {}
	end
end

function HonorSpy:RemoveCorrupt()
	local lastStandings = { }
	local currentStandings = { }

	for playerName, player in pairs(HonorSpy.db.factionrealm.lastStandings) do
		table.insert(lastStandings, {playerName, player.lastWeekHonor or 0, player.standing or 0});
	end
	for playerName, player in pairs(HonorSpy.db.factionrealm.currentStandings) do
		table.insert(currentStandings, {playerName, player.lastWeekHonor or 0, player.standing or 0});
	end

	-- Sort
	local sort_func_asc = function(a, b)
		return a[3] > b[3]
	end

	table.sort(lastStandings, sort_func_asc)
	table.sort(currentStandings, sort_func_asc)

	RemoveCorruptData(lastStandings, HonorSpy.db.factionrealm.lastStandings);
	RemoveCorruptData(currentStandings, HonorSpy.db.factionrealm.currentStandings);

	HonorSpy:Print(L["Remove all corrupt data"])
end

-- Minimap icon
function DrawMinimapIcon()
	LibStub("LibDBIcon-1.0"):Register("HonorSpy", LibStub("LibDataBroker-1.1"):NewDataObject("HonorSpy",
	{
		type = "data source",
		text = addonName,
		icon = "Interface\\Icons\\Inv_Misc_Bomb_04",
		OnClick = function(self, button) 
			if (button == "RightButton") then
				HonorSpy:Report()
			elseif (button == "MiddleButton") then
				HonorSpy:Report(UnitIsPlayer("target") and UnitName("target") or nil)
			else 
				HonorSpy:CheckNeedReset()
				HonorSpyGUI:Toggle()
			end
		end,
		OnTooltipShow = function(tooltip)
			tooltip:AddDoubleLine(format("%s", addonName), format("|cff777777v%s", GetAddOnMetadata(addonName, "Version")));
			tooltip:AddLine("|cff777777by Kakysha|r");
			tooltip:AddLine("|cFFCFCFCFLeft Click: |r" .. L['Show HonorSpy Standings']);
			tooltip:AddLine("|cFFCFCFCFMiddle Click: |r" .. L['Report Target']);
			tooltip:AddLine("|cFFCFCFCFRight Click: |r" .. L['Report Me']);
		end
	}), HonorSpy.db.factionrealm.minimapButton);
end

function PrintWelcomeMsg()
	local realm = GetRealmName()
	local faction = UnitFactionGroup("player")
	local msg = format("|cffAAAAAAversion: %s, bugs & features: github.com/kakysha/honorspy|r\n", GetAddOnMetadata(addonName, "Version"))
	if (realm == "Earthshaker" and faction == "Horde") then
		msg = msg .. format("You are lucky enough to play with HonorSpy author on one |cffFFFFFF%s |cff209f9brealm! Feel free to mail me (|cff8787edKakysha|cff209f9b) a supportive %s  tip or kind word!", realm, GetCoinTextureString(50000))
	end
	msg = msg .. "欢迎使用 |cff8787edBinkcn|cffFFFFFF 修改版本，该版本针对国服优化，并且可以在仅具备较少本地数据的情况下计算出更准确的下周军衔。"
	msg = msg .. "此版本Bug反馈及功能建议请移步：\nhttps://github.com/Binkcn/HonorSpy"
	HonorSpy:Print(msg .. "|r")
end

function RemoveCorruptData(tableData, tableStandings)
	local playerName = nil;
	local playerHonor = nil;

	-- Check last.
	if (#tableData >= 2) then
		if ( tableData[1][2] > tableData[2][2] ) then
			playerName = tableData[1][1]
			playerHonor = tableData[1][2]

			tableStandings[playerName] = nil

			HonorSpy.db.factionrealm.corruptPlayers[playerName] = GetServerTime();

			HonorSpy:Print(format("%s：|cff8787ed%s|cffFFFFFF, %s：%s, %s：%s", L["Remove corrupt data"], playerName, L["LstWkHonor"], playerHonor, L["Standing"], tableData[i][3] ))

			table.remove(tableData, 1);

			RemoveCorruptData(tableData, tableStandings)
			return
		end
	end

	-- Check everone.
	for i = 2, (#tableData-1) do
		playerName = tableData[i][1]
		playerHonor = tableData[i][2]

		if (playerHonor > 0) then
			if ( playerHonor < tableData[i-1][2] and  playerHonor < tableData[i+1][2]) then
				tableStandings[playerName] = nil

				HonorSpy.db.factionrealm.corruptPlayers[playerName] = GetServerTime();

				HonorSpy:Print(format("%s：|cff8787ed%s|cffFFFFFF, %s：%s, %s：%s", L["Remove corrupt data"], playerName, L["LstWkHonor"], playerHonor, L["Standing"], tableData[i][3] ))

				table.remove(tableData, i);

				RemoveCorruptData(tableData, tableStandings)
				break
			end

		end
	end

	-- Check first
	-- TODO

	return tableData
end

function DBHealthCheck()
	local currentPlayerNumber = 0
	for playerName, player in pairs(HonorSpy.db.factionrealm.currentStandings) do
		if (not playerIsValid(playerName, player)) then
			HonorSpy.db.factionrealm.currentStandings[playerName] = nil
			HonorSpy:Print("removed bad table row", playerName)
		else
			if (player.standing > currentPlayerNumber) then
				currentPlayerNumber = player.standing;
			end
		end
	end

	HonorSpy.db.factionrealm.currentPlayerNumber = currentPlayerNumber;

	if (HonorSpy.db.factionrealm.actualCommPrefix ~= commPrefix) then
		HonorSpy:Purge()
		HonorSpy.db.factionrealm.actualCommPrefix = commPrefix
	end

	HonorSpy:removeTestedFriends()
	HS_wait(5, function() startRemovingFakes = true; HonorSpy:TestNextFakePlayer(); end)
end

local waitTable = {};
local waitFrame = nil;
function HS_wait(delay, func, ...)
  if(type(delay)~="number" or type(func)~="function") then
	return false;
  end
  if(waitFrame == nil) then
	waitFrame = CreateFrame("Frame","WaitFrame", UIParent);
	waitFrame:SetScript("onUpdate",function (self,elapse)
	  local count = #waitTable;
	  local i = 1;
	  while(i<=count) do
		local waitRecord = tremove(waitTable,i);
		local d = tremove(waitRecord,1);
		local f = tremove(waitRecord,1);
		local p = tremove(waitRecord,1);
		if(d>elapse) then
		  tinsert(waitTable,i,{d-elapse,f,p});
		  i = i + 1;
		else
		  count = count - 1;
		  f(unpack(p));
		end
	  end
	end);
  end
  tinsert(waitTable,{delay,func,{...}});
  return true;
end