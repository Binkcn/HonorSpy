local GUI = {}
_G["HonorSpyGUI"] = GUI

local AceGUI = LibStub("AceGUI-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("HonorSpy", true)

LibStub("AceHook-3.0"):Embed(GUI)

local mainFrame, statusLine, playerStandings, reportBtn, clearBtn, scroll = nil, nil, nil, nil, nil
local editFrame, editStanding, editTotalPlayer = nil, nil, nil
local rows, brackets = {}, {}
local show_bracket = false

local colors = {
	["ORANGE"] = "ff7f00",
	["GREY"] = "aaaaaa",
	["RED"] = "C41F3B",
	["GREEN"] = "00FF96",
	["SHAMAN"] = "0070DE",
	["nil"] = "FFFFFF",
	["NORMAL"] = "f2ca45"
}

local playerName = UnitName("player")
local regionId = GetCurrentRegion()

function GUI:Show(skipUpdate, sort_column)
	if (not skipUpdate) then
		HonorSpy:UpdatePlayerData(function()
			if (mainFrame:IsShown()) then
				GUI:Show(true, sort_column)
			end
		end)
	end

	if (sort_column == nil or sort_column == L["Honor"]) then
		show_bracket = true
	else
		show_bracket = false
	end

	rows = HonorSpy:BuildStandingsTable(sort_column)
	brackets = HonorSpy:GetBracketsByStanding(#rows)

	local index = false;
	local totalPlayerNumber = HonorSpy:GetPoolSize(#rows);

	for i = 1, #rows do
		if (playerName == rows[i][1]) then
			index = i
		end
	end

	local poolSizeText = format(L['Pool Size'] .. ': %d ', #rows)

	statusLine:SetText('|cff777777/hs show|r                                              ' .. poolSizeText .. '                                      |cff777777/hs search nickname|r')

	local pool_size, _, standing, bracket, RP, EstRP, Rank, Progress, EstRank, EstProgress = HonorSpy:Estimate(false)
	if (index and standing) then
		editStanding:SetText(standing);
		editTotalPlayer:SetText(totalPlayerNumber);
		editFrame:Show();

		local playerText = colorize(L['Progress of'], "GREY") .. ' ' .. colorize(playerName, HonorSpy.db.factionrealm.currentStandings[playerName].class)
		playerText = playerText .. ', ' .. colorize(L['Estimated Honor'] .. ': ', "GREY") .. colorize(HonorSpy.db.char.estimated_honor, "ORANGE")
		playerText = playerText .. ' ' .. colorize(L['Bracket'] .. ':', "GREY") .. colorize(bracket, "ORANGE")
		playerText = playerText .. ' ' .. colorize(L['Current Rank'] .. ':', "GREY") .. colorize(format('%d (%d%%)', Rank, Progress), "ORANGE")
		playerText = playerText .. ' ' .. colorize(L['Next Week Rank'] .. ':', "GREY") .. colorize(format('%d (%d%%)', EstRank, EstProgress), EstRP >= RP and "GREEN" or "RED")
		playerText = playerText .. '\n' .. colorize(L['Estimated Standing'] .. ':', "GREY")
		playerText = playerText .. '\n' .. colorize(L['Total Player Number'] .. ':', "GREY")
		playerStandings:SetText(playerText)

		scroll.scrollBar:SetValue(index * scroll.buttonHeight-200)
		scroll.scrollBar.thumbTexture:Show()
	else
		playerStandings:SetText(format('%s %s, %s: %s\n%s\n', L['Progress of'], playerName, colorize(L['Estimated Honor'], "GREY"), colorize(HonorSpy.db.char.estimated_honor, "ORANGE"), L['You have 0 honor or not enough HKs, min = 15']))
	end

	reportBtn:SetText(L['Report'] .. ' ' .. (UnitIsPlayer("target") and UnitName("target") or ''))

	mainFrame:Show()
	GUI:UpdateTableView()
end

function GUI:Hide()
	if (mainFrame) then
		mainFrame:Hide()
	end
end

function GUI:Toggle()
	if (mainFrame and mainFrame:IsShown()) then
		GUI:Hide()
	else
		GUI:Show()
	end
end

function GUI:Reset()
	if (rows[1]) then
		rows = {}
		GUI:PrepareGUI()
	end
end

function GUI:UpdateTableView()
	local buttons = HybridScrollFrame_GetButtons(scroll);
	local offset = HybridScrollFrame_GetOffset(scroll);
	local display_bracket = 0;

	for buttonIndex = 1, #buttons do
		local button = buttons[buttonIndex];
		local itemIndex = buttonIndex + offset;

		if (itemIndex <= #rows) then
			local name, class, thisWeekHonor, lastWeekHonor, standing, RP, rank, last_checked = unpack(rows[itemIndex])
			local bracket = nil;

			if (show_bracket == true) then
				for idx = 1, #brackets do
					if (thisWeekHonor >= brackets[idx][2]) then
						bracket = brackets[idx][1];
						break;
					end
				end
			end

			if (show_bracket == true and display_bracket ~= bracket) then
				offset = offset-1

				button.Name:SetText(colorize(format(L["Bracket"] .. " %d", bracket), "GREY"))
				button.Honor:SetText();
				button.LstWkHonor:SetText();
				button.Standing:SetText();
				button.RP:SetText();
				button.Rank:SetText();
				button.LastSeen:SetText();
				button.Background:SetTexture("Interface/Glues/CharacterCreate/CharacterCreateMetalFrameHorizontal")
				button.Highlight:SetTexture()
				button:Show();

				display_bracket = bracket;
			else
				local last_seen, last_seen_human = (GetServerTime() - last_checked), ""

				if (last_seen/60/60/24 > 1) then
					last_seen_human = ""..math.floor(last_seen/60/60/24)..L["d"]
				elseif (last_seen/60/60 > 1) then
					last_seen_human = ""..math.floor(last_seen/60/60)..L["h"]
				elseif (last_seen/60 > 1) then
					last_seen_human = ""..math.floor(last_seen/60)..L["m"]
				else
					last_seen_human = ""..last_seen..L["s"]
				end

				button:SetID(itemIndex);
				button.Name:SetText(colorize(itemIndex .. ')  ', "GREY") .. colorize(name, class));
				button.Honor:SetText(colorize(thisWeekHonor, class));
				button.LstWkHonor:SetText(colorize(lastWeekHonor, class));
				button.Standing:SetText(colorize(standing, class));
				button.RP:SetText(colorize(RP, class));
				button.Rank:SetText(colorize(rank, class));
				button.LastSeen:SetText(colorize(last_seen_human, class));

				if (name == playerName) then
					button.Background:SetColorTexture(0.5, 0.5, 0.5, 0.2)
				else
					button.Background:SetColorTexture(0, 0, 0, 0.2)
				end
				button.Highlight:SetColorTexture(1, 0.75, 0, 0.2)

				button:Show();
			end
		else
			button:Hide();
		end
	end

	local buttonHeight = scroll.buttonHeight;
	local totalHeight = #rows * buttonHeight;
	local shownHeight = #buttons * buttonHeight;

	HybridScrollFrame_Update(scroll, totalHeight, shownHeight);
end

function GUI:PrepareGUI()
	mainFrame = AceGUI:Create("Window")
	mainFrame:Hide()
	_G["HonorSpyGUI_MainFrame"] = mainFrame
	tinsert(UISpecialFrames, "HonorSpyGUI_MainFrame")	-- allow ESC close
	mainFrame:SetTitle(L["HonorSpy Standings"])
	mainFrame:SetWidth(800)
	mainFrame:SetLayout("List")
	mainFrame:EnableResize(false)

	-- Player Standings
	local playerStandingsGrp = AceGUI:Create("SimpleGroup")
	playerStandingsGrp:SetFullWidth(true)
	playerStandingsGrp:SetLayout("Flow")
	mainFrame:AddChild(playerStandingsGrp)

	playerStandings = AceGUI:Create("Label")
	playerStandings:SetRelativeWidth(0.80)
	playerStandings:SetText('\n\n')
	playerStandingsGrp:AddChild(playerStandings)






	-- Custom input.
	editFrame = CreateFrame("Frame", nil, playerStandingsGrp.frame);
	editFrame:SetWidth(100);
	editFrame:SetPoint("TOPLEFT", 70, -18);
	editFrame:SetPoint("BOTTOMRIGHT", -650, -4);
	editFrame:Hide();



	editStanding = CreateFrame("EditBox", nil, editFrame);
	editStanding:SetAutoFocus(false);
	editStanding:SetMaxLetters(6);
	editStanding:SetHeight(18);
	editStanding:SetFontObject("GameFontWhite");
	editStanding:SetJustifyH("LEFT");
	editStanding:SetJustifyV("CENTER");
	editStanding:SetTextInsets(7,7,7,7);
	editStanding:SetBackdrop({
		bgFile = [[Interface\Buttons\WHITE8x8]],
		edgeFile = [[Interface\Tooltips\UI-Tooltip-Border]],
		edgeSize = 16,
		insets = {left = 1, right = 1, top = 1, bottom = 1},
	});
	editStanding:SetBackdropColor(0, 0, 0);
	editStanding:SetBackdropBorderColor(0.3, 0.3, 0.3);

	editFrame.standingEdit = editStanding;
	editFrame.standingEdit:SetPoint("TOPLEFT", 0, 0);
	editFrame.standingEdit:SetPoint("BOTTOMRIGHT", 0, 16);


	editTotalPlayer = CreateFrame("EditBox", nil, editFrame);
	editTotalPlayer:SetAutoFocus(false);
	editTotalPlayer:SetMaxLetters(6);
	editTotalPlayer:SetHeight(18);
	editTotalPlayer:SetFontObject("GameFontWhite");
	editTotalPlayer:SetJustifyH("LEFT");
	editTotalPlayer:SetJustifyV("CENTER");
	editTotalPlayer:SetTextInsets(7,7,7,7);
	editTotalPlayer:SetBackdrop({
		bgFile = [[Interface\Buttons\WHITE8x8]],
		edgeFile = [[Interface\Tooltips\UI-Tooltip-Border]],
		edgeSize = 16,
		insets = {left = 1, right = 1, top = 1, bottom = 1},
	});
	editTotalPlayer:SetBackdropColor(0, 0, 0);
	editTotalPlayer:SetBackdropBorderColor(0.3, 0.3, 0.3);

	editFrame.totalPlayerEdit = editTotalPlayer;
	editFrame.totalPlayerEdit:SetPoint("TOPLEFT", 0, -16);
	editFrame.totalPlayerEdit:SetPoint("BOTTOMRIGHT", 0, 0);

	editFrame.confirmBtn = CreateFrame("Button", nil, editFrame, "OptionsButtonTemplate");
	editFrame.confirmBtn:SetText(L['Confirm Edit']);
	editFrame.confirmBtn:SetPoint("TOPLEFT", 80, -6);
	editFrame.confirmBtn:SetWidth(125);
	editFrame.confirmBtn:SetScript("OnClick", function(self)
		local standingValue = editStanding:GetText()
		local totalPlayerValue = editTotalPlayer:GetText()

		HonorSpy:CustomSet(standingValue, totalPlayerValue)

		GUI:Show(true, nil)
	end)

	editFrame.resetBtn = CreateFrame("Button", nil, editFrame, "OptionsButtonTemplate");
	editFrame.resetBtn:SetText(L['Reset Edit']);
	editFrame.resetBtn:SetPoint("TOPLEFT", 220, -6);
	editFrame.resetBtn:SetWidth(125);
	editFrame.resetBtn:SetScript("OnClick", function(self)
		HonorSpy:CustomReset()

		GUI:Show(true, nil)
	end)


	-- Report Button
	reportBtn = AceGUI:Create("Button")
	reportBtn:SetRelativeWidth(0.18)
	reportBtn.text:SetFontObject("SystemFont_NamePlate")
	reportBtn:SetCallback("OnClick", function()
		HonorSpy:Report(UnitIsPlayer("target") and UnitName("target") or nil)
	end)
	playerStandingsGrp:AddChild(reportBtn)

	-- Clear Button
	-- clearBtn = AceGUI:Create("Button")
	-- clearBtn:SetRelativeWidth(0.18)
	-- clearBtn.text:SetFontObject("SystemFont_NamePlate")
	-- clearBtn:SetText(L['Remove corrupt data'])
	-- clearBtn:SetCallback("OnClick", function()
	-- 	HonorSpy:RemoveCorrupt()
	-- end)
	-- playerStandingsGrp:AddChild(clearBtn)
	





	-- TABLE HEADER
	local tableHeader = AceGUI:Create("SimpleGroup")
	tableHeader:SetFullWidth(true)
	tableHeader:SetLayout("Flow")
	mainFrame:AddChild(tableHeader)

	local btn = AceGUI:Create("InteractiveLabel")
	btn:SetWidth(180)
	btn:SetText(colorize(L["Name"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetCallback("OnClick", function()
		GUI:Show(false, L["Honor"])
	end)
	btn.highlight:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	btn:SetWidth(100)
	btn:SetText(colorize(L["Honor"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetWidth(100)
	btn:SetText(colorize(L["LstWkHonor"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetCallback("OnClick", function()
		GUI:Show(false, L["Standing"])
	end)
	btn.highlight:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	btn:SetWidth(80)
	btn:SetText(colorize(L["Standing"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetWidth(80)
	btn:SetText(colorize(L["RP"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetCallback("OnClick", function()
		GUI:Show(false, L["Rank"])
	end)
	btn.highlight:SetColorTexture(0.3, 0.3, 0.3, 0.5)
	btn:SetWidth(80)
	btn:SetText(colorize(L["Rank"], "ORANGE"))
	tableHeader:AddChild(btn)

	btn = AceGUI:Create("InteractiveLabel")
	btn:SetWidth(80)
	btn:SetText(colorize(L["LastSeen"], "ORANGE"))
	tableHeader:AddChild(btn)

	local scrollHeight = 390
	if (regionId == 5) then
		scrollHeight = 350		-- zhCN font size
	end
	scrollcontainer = AceGUI:Create("SimpleGroup")
	scrollcontainer:SetFullWidth(true)
	scrollcontainer:SetHeight(scrollHeight)
	scrollcontainer:SetLayout("Fill")
	mainFrame:AddChild(scrollcontainer)
	scrollcontainer:ClearAllPoints()
	scrollcontainer.frame:SetPoint("TOP", tableHeader.frame, "BOTTOM", 0, -5)
	scrollcontainer.frame:SetPoint("BOTTOM", 0, 20)

	scroll = CreateFrame("ScrollFrame", nil, scrollcontainer.frame, "HybridScrollFrame")
	HybridScrollFrame_CreateButtons(scroll, "HybridScrollListItemTemplate");
	HybridScrollFrame_SetDoNotHideScrollBar(scroll, true)
	scroll.update = function() GUI:UpdateTableView() end

	statusLine = AceGUI:Create("Label")
	statusLine:SetFullWidth(true)
	mainFrame:AddChild(statusLine)
	statusLine:ClearAllPoints()
	statusLine:SetPoint("BOTTOM", mainFrame.frame, "BOTTOM", 0, 15)

	if (not HonorSpyGUI:IsHooked(HonorFrame, "OnUpdate")) then
		HonorSpyGUI:SecureHookScript(HonorFrame, "OnUpdate", "UpdateHonorFrameText")
	end
end

function HonorSpyGUI:UpdateHonorFrameText(setRankProgress)
	-- rank progress percentage
	local _, rankNumber = GetPVPRankInfo(UnitPVPRank("player"))
	local rankProgress = GetPVPRankProgress(); -- This is a player only call
	HonorFrameCurrentPVPRank:SetText(format("(%s %d) %d%%", RANK, rankNumber, rankProgress*100))
	
	-- today's honor
	HonorFrameCurrentHKValue:SetText(format("%d "..colorize("(Honor: %d)", "NORMAL"), GetPVPSessionStats(), HonorSpy.db.char.estimated_honor - HonorSpy.db.char.original_honor))
	-- this week honor
	local _, this_week_honor = GetPVPThisWeekStats();
	HonorFrameThisWeekContributionValue:SetText(format("%d (%d)", this_week_honor, HonorSpy.db.char.estimated_honor))
end

function colorize(str, colorOrClass)
	if (not colorOrClass) then -- some guys have nil class for an unknown reason
		colorOrClass = "nil"
	end
	
	if (not colors[colorOrClass] and RAID_CLASS_COLORS and RAID_CLASS_COLORS[colorOrClass]) then
		colors[colorOrClass] = format("%02x%02x%02x", RAID_CLASS_COLORS[colorOrClass].r * 255, RAID_CLASS_COLORS[colorOrClass].g * 255, RAID_CLASS_COLORS[colorOrClass].b * 255)
	end
	if (not colors[colorOrClass]) then
		colorOrClass = "nil"
	end

	return format("|cff%s%s|r", colors[colorOrClass], str)
end
