-- Velocity Quest Tracker: the settings panel. Pattern: GotJunk/GotJunk.lua (Section / Check /
-- Slider helpers on a scrolling canvas, Settings.RegisterCanvasLayoutCategory with the legacy
-- InterfaceOptions_AddCategory fallback). Settings live in VelocityQuestTrackerDB.settings.
local ADDON_NAME, NS = ...
local Util = NS.Util

local Options = {}
NS.Options = Options

local optionsFrame, optionsCategory
local widgets = {}

local function db() return NS.db.settings end

function Options.Refresh()
  for _, w in ipairs(widgets) do if w.Update then w:Update() end end
end

function Options.Open()
  if Settings and Settings.OpenToCategory and optionsCategory then Settings.OpenToCategory(optionsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory and optionsFrame then InterfaceOptionsFrame_OpenToCategory(optionsFrame); InterfaceOptionsFrame_OpenToCategory(optionsFrame) end
end

function Options.Create()
  if optionsFrame then return end
  optionsFrame = CreateFrame("Frame", "VelocityQuestTrackerOptions", UIParent)
  optionsFrame.name = "Velocity Quest Tracker"
  optionsFrame:Hide()

  local scroll = CreateFrame("ScrollFrame", "VelocityQuestTrackerOptionsScroll", optionsFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -4); scroll:SetPoint("BOTTOMRIGHT", -28, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(620, 900)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(self, w) content:SetWidth(math.max(620, w)) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = self:GetVerticalScrollRange()
    self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
  end)

  local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16); title:SetText("Velocity Quest Tracker")
  local sub = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6); sub:SetWidth(560); sub:SetJustifyH("LEFT")
  sub:SetText("Shows the state of your quest work and leaves the decisions to you. Quests you have acted on in the last few minutes sit in a block at the top; the rest of the zone's work is listed as nearby; other zones fold to one line each. Position the panel with Edit Mode.")

  local BOX_W, PAD = 580, 10
  local last, lastDy = sub, -14
  local function Place(w, dy, dx) w:SetPoint("TOPLEFT", last, "BOTTOMLEFT", dx or 0, dy or lastDy); last = w; lastDy = -6 end

  local function Check(parent, key, label, tip, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb.Text:SetText(label)
    cb.tooltipText = tip
    cb:SetScript("OnClick", function(self) db()[key] = self:GetChecked() and true or false; if onChange then onChange() end; NS.OnSettingChanged(key) end)
    cb.Update = function(self) self:SetChecked(db()[key] and true or false) end
    widgets[#widgets + 1] = cb
    return cb
  end

  local function Slider(parent, name, key, default, minV, maxV, step, labelFn)
    local holder = CreateFrame("Frame", nil, parent); holder:SetSize(BOX_W - 2 * PAD, 44)
    local label = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); label:SetPoint("TOPLEFT", 4, 0)
    local s = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 2, -6); s:SetWidth(220)
    s:SetMinMaxValues(minV, maxV); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
    _G[name .. "Low"]:SetText(tostring(minV)); _G[name .. "High"]:SetText(tostring(maxV)); _G[name .. "Text"]:SetText("")
    s:SetScript("OnValueChanged", function(self, v)
      v = math.floor(v / step + 0.5) * step
      if db()[key] == v then return end
      db()[key] = v; label:SetText(labelFn(v)); NS.OnSettingChanged(key)
    end)
    holder.Update = function() local v = db()[key] or default; s:SetValue(v); label:SetText(labelFn(v)) end
    widgets[#widgets + 1] = holder
    return holder
  end

  local function Section(header)
    local box = CreateFrame("Frame", nil, content, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetWidth(BOX_W)
    if box.SetBackdrop then
      box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      box:SetBackdropColor(0, 0, 0, 0.25); box:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.6)
    end
    local h = box:CreateFontString(nil, "ARTWORK", "GameFontNormal"); h:SetPoint("TOPLEFT", PAD, -PAD); h:SetText(header)
    box.inner_last, box.inner_h = h, PAD + 14
    function box:Add(w, height, dy, dx)
      dy = dy or -6
      w:SetPoint("TOPLEFT", self.inner_last, "BOTTOMLEFT", dx or 0, dy)
      self.inner_last, self.inner_h = w, self.inner_h - dy + height
      return w
    end
    function box:Finish() self:SetHeight(self.inner_h + PAD) end
    Place(box, -14)
    return box
  end

  -- The two headline checkboxes, directly under the intro.
  Place(Check(content, "Enabled", "Enable Velocity Quest Tracker", "Shows the panel and hides the game's own quest tracker. Untick to put the stock tracker back."), -14)
  -- Lock position lives in the LAYOUT PROFILE (per Edit Mode layout / manual profile), not in settings.
  -- Label and tip differ by client: only an Edit Mode client can "edit with Edit Mode".
  local hasEditMode = NS.Profiles:Source() == "editmode"
  do
    local cb = CreateFrame("CheckButton", nil, content, "InterfaceOptionsCheckButtonTemplate")
    cb.Text:SetText(hasEditMode and "Lock position (edit with Edit Mode)" or "Lock position")
    cb.tooltipText = hasEditMode
      and "Ticked: the panel moves only in the game's Edit Mode. Unticked: it can also be dragged by the titlebar that appears when you hover over it. Saved with the layout profile."
      or "Ticked: the panel cannot be dragged. Unticked: hover over the panel and drag the titlebar that appears. The lock icon on the titlebar toggles this too. Saved with the layout profile."
    cb:SetScript("OnClick", function(self) NS.EditMode.SetPositionLocked(self:GetChecked()) end)
    cb.Update = function(self) self:SetChecked(NS.EditMode.IsPositionLocked()) end
    widgets[#widgets + 1] = cb
    Place(cb, -4)
  end
  Place(Check(content, "TitleBarOnlyWhenUnlocked", "Show titlebar on hover only when unlocked", "Ticked (default): the titlebar with the drag handle and lock icon appears on hover only while the position is unlocked. Unticked: it also appears when locked, so you can unlock from the panel itself."), -4)
  Place(Check(content, "RequireShiftToInteract", "Require Shift key to interact with panel", "Ticked: clicks on quest titles only open the quest log while Shift is held, so the panel never catches stray clicks."), -4)
  Place(Check(content, "RequireShiftForHover", "Hold Shift for hover feedback", "Ticked: the place-line summary card and title highlight only appear while Shift is held."), -4)

  local blk = Section("Actionable block")
  -- Radio pair: objective counts shown as what is LEFT (default) or as done/total.
  local countRadios = {}
  local function CountRadio(mode, label, tip)
    local r = CreateFrame("CheckButton", nil, blk, "UIRadioButtonTemplate"); r:SetSize(16, 16)
    r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); r.text:SetPoint("LEFT", r, "RIGHT", 4, 0); r.text:SetText(label)
    r.tooltipText = tip
    r.mode = mode
    r:SetScript("OnClick", function()
      db().ObjectiveCountMode = mode
      for _, o in ipairs(countRadios) do o:SetChecked(o.mode == mode) end
      NS.OnSettingChanged("ObjectiveCountMode")
    end)
    r.Update = function(self) self:SetChecked((db().ObjectiveCountMode or "remaining") == mode) end
    widgets[#widgets + 1] = r; countRadios[#countRadios + 1] = r
    return r
  end
  local countLabel = blk:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); countLabel:SetText("Show objectives as")
  blk:Add(countLabel, 14, -10, 4)
  blk:Add(CountRadio("remaining", "remaining counts", "\"3\" -- how many units are still owed."), 16, -4, 4)
  blk:Add(CountRadio("completed", "completed counts", "\"1/4\" -- done over total."), 16, -4, 4)
  blk:Add(Slider(blk, "VelocityQuestTrackerOptActive", "ActiveWindowSeconds", 300, 60, 900, 30,
    function(v) return string.format("A quest stays in the block for %d s after you act on it", v) end), 44, -10)
  blk:Add(Slider(blk, "VelocityQuestTrackerOptProximity", "ActiveProximityYards", 100, 0, 300, 10,
    function(v) if v <= 0 then return "Being near the work does not make a quest active" end return string.format("A quest is active while a spawn of its unfinished work is within %d yd", v) end), 44, -10)
  blk:Add(Slider(blk, "VelocityQuestTrackerOptArrive", "HandInArriveYards", 25, 0, 50, 5,
    function(v) if v <= 0 then return "Hand-in cards do not highlight when you reach the NPC" end return string.format("A hand-in card holds its yellow while the turn-in NPC is within %d yd", v) end), 44, -10)
  blk:Add(Slider(blk, "VelocityQuestTrackerOptErrand", "ErrandGraceSeconds", 120, 0, 600, 15,
    function(v) return string.format("A quest that just became complete is shown as a hand-in card even out of zone for %d s", v) end), 44, -10)
  blk:Add(Check(blk, "HideCompletedSegments", "Hide completed segments", "Done units are not drawn; the bar shows only what is left."), 26, -10)
  blk:Add(Check(blk, "HideCompletedRows", "Hide fully completed quest objectives", "An objective row leaves the block once its last unit has faded."), 26)
  blk:Add(Check(blk, "AutoUntrackInactive", "Auto-untrack inactive quests", "Tracking a quest in the quest log makes it active here. Ticked: when a quest ages out of the active block it is also untracked in the quest log, so tracked == active."), 26)
  blk:Finish()

  local tm = Section("Recent-progress timing")
  tm:Add(Slider(tm, "VelocityQuestTrackerOptHold", "HoldSeconds", 4, 1, 10, 0.5,
    function(v) return string.format("Stay yellow: %.1f s", v) end), 44, -10)
  tm:Add(Slider(tm, "VelocityQuestTrackerOptFade", "FadeSeconds", 1, 0.2, 3, 0.1,
    function(v) return string.format("Fade to dim: %.1f s", v) end), 44, -10)
  tm:Finish()

  local nb = Section("Nearby work")
  nb:Add(Check(nb, "ExperimentalMapMode", "Experimental map mode", "Adds a Map view of nearby work (compass field with one mark per mob type per direction) and the Map | Range switcher that appears above the panel on hover. Off: the Range list only."), 26, -10)
  nb:Add(Check(nb, "OrderNearbyByProximity", "Order nearby by proximity", "Ticked (default): nearby objectives are listed closest first, by the distance to their nearest spawn. Unticked: quest-log order."), 26)
  nb:Add(Check(nb, "LinearSparkScale", "Linear distance scale on the spark lines", "Unticked (default): square-root scale, so the near half of the line covers the near quarter of the range and close differences get the pixels. Ticked: plain distance / range."), 26, -10)
  nb:Finish()

  -- Layout profile. Panel position + lock are saved per profile (LibEditModeProfileExtension). On a client
  -- with Edit Mode the game's layout dropdown IS the picker, so only a note is shown; on Era we show the
  -- "micro profile" block: current profile dropdown, New (copies the current), Delete.
  local P = NS.Profiles
  local lp = Section("Layout profile")
  if P:Source() == "editmode" then
    local note = lp:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); note:SetWidth(BOX_W - 2 * PAD - 8); note:SetJustifyH("LEFT")
    note.Update = function(self) self:SetText(string.format("Panel position and lock are saved per Edit Mode layout. Current layout: |cffffd100%s|r. Switch layouts in Edit Mode; a new layout inherits the current position.", P:Name())) end
    widgets[#widgets + 1] = note
    lp:Add(note, 28, -8, 4)
  else
    local row = CreateFrame("Frame", nil, lp); row:SetSize(BOX_W - 2 * PAD, 26)
    local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight"); lbl:SetPoint("LEFT", 4, 0); lbl:SetText("This character uses")
    local dd = CreateFrame("Frame", "VelocityQuestTrackerOptProfileDropDown", row, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", lbl, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(dd, 180)
    UIDropDownMenu_Initialize(dd, function(self, level)
      for _, name in ipairs(P:List()) do
        local info = UIDropDownMenu_CreateInfo()
        info.text, info.checked = name, (name == P:Name())
        info.func = function() P:Select(name); UIDropDownMenu_SetText(dd, P:Name()) end
        UIDropDownMenu_AddButton(info, level)
      end
    end)
    row.Update = function() UIDropDownMenu_SetText(dd, P:Name()) end
    widgets[#widgets + 1] = row
    lp:Add(row, 26, -8)

    StaticPopupDialogs["VELOCITYQUESTTRACKER_NEW_PROFILE"] = {
      text = "New layout profile (copies the current one):", button1 = CREATE or "Create", button2 = CANCEL or "Cancel",
      hasEditBox = true, maxLetters = 32, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
      OnAccept = function(self)
        local name = self.editBox:GetText()
        if P:Create(name) then Util.Print("layout profile %q created", name) else Util.Print("could not create profile %q (empty, too long, or already exists)", name) end
        Options.Refresh()
      end,
      EditBoxOnEnterPressed = function(self) local parent = self:GetParent(); parent.button1:Click() end,
      EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
      OnShow = function(self) self.editBox:SetText(""); self.editBox:SetFocus() end,
    }
    StaticPopupDialogs["VELOCITYQUESTTRACKER_DELETE_PROFILE"] = {
      text = "Delete layout profile %q? Characters using it fall back to \"Default\".", button1 = DELETE or "Delete", button2 = CANCEL or "Cancel",
      timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
      OnAccept = function(self, name)
        if P:Delete(name) then Util.Print("layout profile %q deleted", name) else Util.Print("cannot delete %q (Default, or in use by this character)", name) end
        Options.Refresh()
      end,
    }
    local btns = CreateFrame("Frame", nil, lp); btns:SetSize(BOX_W - 2 * PAD, 22)
    local newBtn = CreateFrame("Button", nil, btns, "UIPanelButtonTemplate"); newBtn:SetSize(140, 22); newBtn:SetText("New profile...")
    newBtn:SetPoint("LEFT", 4, 0)
    newBtn:SetScript("OnClick", function() StaticPopup_Show("VELOCITYQUESTTRACKER_NEW_PROFILE") end)
    -- Delete acts on a profile OTHER than the current one: a second dropdown would be heavy, so it offers a menu.
    local delBtn = CreateFrame("Button", nil, btns, "UIPanelButtonTemplate"); delBtn:SetSize(140, 22); delBtn:SetText("Delete profile...")
    delBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
    local delMenu = CreateFrame("Frame", "VelocityQuestTrackerOptProfileDeleteMenu", btns, "UIDropDownMenuTemplate")
    delBtn:SetScript("OnClick", function(self)
      UIDropDownMenu_Initialize(delMenu, function(_, level)
        local any = false
        for _, name in ipairs(P:List()) do
          if name ~= P:Name() and name ~= "Default" then
            any = true
            local info = UIDropDownMenu_CreateInfo(); info.text, info.notCheckable = name, true
            info.func = function() local d = StaticPopup_Show("VELOCITYQUESTTRACKER_DELETE_PROFILE", name); if d then d.data = name end end
            UIDropDownMenu_AddButton(info, level)
          end
        end
        if not any then local info = UIDropDownMenu_CreateInfo(); info.text, info.notCheckable, info.disabled = "(nothing to delete)", true, true; UIDropDownMenu_AddButton(info, level) end
      end, "MENU")
      ToggleDropDownMenu(1, nil, delMenu, self, 0, 0)
    end)
    lp:Add(btns, 22, -8)
  end
  lp:Finish()

  -- Reset: the current profile's panel position, or everything.
  StaticPopupDialogs["VELOCITYQUESTTRACKER_RESET_ALL"] = {
    text = "Reset ALL Velocity Quest Tracker data?\n\nEvery setting, every layout profile and this character's view state are wiped and the UI reloads.",
    button1 = "Reset everything", button2 = CANCEL or "Cancel", timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3, showAlert = true,
    OnAccept = function() VelocityQuestTrackerDB = nil; VelocityQuestTrackerCharDB = nil; ReloadUI() end,
  }
  local rs = Section("Reset")
  local rrow = CreateFrame("Frame", nil, rs); rrow:SetSize(BOX_W - 2 * PAD, 22)
  local resetLayout = CreateFrame("Button", nil, rrow, "UIPanelButtonTemplate"); resetLayout:SetSize(160, 22); resetLayout:SetText("Reset layout")
  resetLayout:SetPoint("LEFT", 4, 0)
  resetLayout.tooltipText = "Puts the panel back on the stock tracker's position for the CURRENT layout profile only."
  resetLayout:SetScript("OnClick", function() NS.EditMode.ResetPosition(); Util.Print("panel position reset for profile %q", P:Name()) end)
  local resetAll = CreateFrame("Button", nil, rrow, "UIPanelButtonTemplate"); resetAll:SetSize(160, 22); resetAll:SetText("Reset all data...")
  resetAll:SetPoint("LEFT", resetLayout, "RIGHT", 8, 0)
  resetAll:SetScript("OnClick", function() StaticPopup_Show("VELOCITYQUESTTRACKER_RESET_ALL") end)
  for _, b in ipairs({ resetLayout, resetAll }) do
    b:SetScript("OnEnter", function(self) if self.tooltipText then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(self.tooltipText, nil, nil, nil, nil, true); GameTooltip:Show() end end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  rs:Add(rrow, 22, -10)
  rs:Finish()

  content:SetHeight(-select(5, last:GetPoint(1)) + last:GetHeight() + 60)
  optionsFrame:SetScript("OnShow", function()
    Options.Refresh()
    local top = content:GetTop(); local bottom = last:GetBottom()
    if top and bottom then content:SetHeight(top - bottom + 40) end
  end)

  if Settings and Settings.RegisterCanvasLayoutCategory then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsFrame, "Velocity Quest Tracker")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(optionsFrame)
  end
end