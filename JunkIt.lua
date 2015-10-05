require "Window"
require "string"
require "math"
require "Sound"
require "Item"
require "Money"
require "GameLib"

-----------------------------------------------------------------------------------------------
-- Upvalues
-----------------------------------------------------------------------------------------------

local type, pairs, ipairs = type, pairs, ipairs
local setmetatable, unpack, strformat = setmetatable, unpack, string.format
local strmatch, mathmin, mathmax = string.match, math.min, math.max

-- Wildstar APIs
local Apollo, ApolloTimer, Item, XmlDoc = Apollo, ApolloTimer, Item, XmlDoc
local GameLib, Print, IsRepairVendor = GameLib, Print, IsRepairVendor
local SellItemToVendorById, RepairAllItemsVendor = SellItemToVendorById, RepairAllItemsVendor
local Sound, GuildLib, Money = Sound, GuildLib, Money
-----------------------------------------------------------------------------------------------
-- Local Functions
-----------------------------------------------------------------------------------------------
local function TableMerge(t1, t2)
    for k,v in pairs(t2) do
        if type(v) == "table" then
            if type(t1[k] or false) == "table" then
                TableMerge(t1[k] or {}, t2[k] or {})
            else
                t1[k] = v
            end
        else
            t1[k] = v
        end
    end
    return t1
end

local JunkIt = {}
local GeminiLocale, L
local strParentAddon = "Vendor"
local tAlertTimer
-----------------------------------------------------------------------------------------------
-- Constants
-----------------------------------------------------------------------------------------------
-- Considered using ItemFamilyName and ItemCategoryName but unsure if localization would affect
local ktVendorAddons = {
    ["Vendor"] = {
        wndVendor = "wndVendor",
        strAnchor = "OptionsContainer",
    },
}

local knMaxGuildLimit   = 2000000000 -- 2000 plat
local ItemFamily = {
    Armor      = 1,
    Weapon     = 2,
    Bag        = 5,
    Ornamental = 15, -- Shield
    Consumable = 16,
    Reagent    = 18, -- Crafting Reagents
    Housing    = 20, -- Housing according to inventory
    --Housing  = 22, -- What
    QuestItem  = 24,
    Costume    = 26,
    Crafting   = 27,
}

local ItemCategory = {
    Junk = 94,
}
local ktReverseQualityLookup = {}

function JunkIt:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.config              = {}
    o.config.sellArmor    = true
    o.config.sellWeapons  = true
    o.config.sellCostumes = true
    o.config.sellShields  = true
    o.config.keepSalvage  = false
    o.config.autoSell     = false
    o.config.sellHousing  = false
    o.config.autoRepair   = false
    o.config.showButton   = false
    o.config.repairGuild  = false

    o.config.minSellQuality = Item.CodeEnumItemQuality.Average

    return o
end

function JunkIt:Init()
    Apollo.RegisterAddon(self, false, "", {"Vendor", "Gemini:Locale-1.0"})
end

---------------------------------------------------------------------------------------------------
-- JunkIt Load Functions
---------------------------------------------------------------------------------------------------
function JunkIt:OnLoad()
    -- Read in the file only once, presumably file IO is more costly
    self.Xml = XmlDoc.CreateFromFile("JunkIt.xml")
    self.Xml:RegisterCallback("OnDocLoaded", self)
    GeminiLocale = Apollo.GetPackage("Gemini:Locale-1.0").tPackage
    L = GeminiLocale:GetLocale("JunkIt", false)
end

function JunkIt:OnDocLoaded()
    -- Store reference to the Vendor addon

    self.vendorAddon = Apollo.GetAddon(strParentAddon)

    -- Event thrown by opening the a Vendor window
    Apollo.RegisterEventHandler("InvokeVendorWindow",   "OnInvokeVendorWindow", self)
    Apollo.RegisterEventHandler("WindowManagementAdd",  "OnWindowManagementAdd", self)
    -- Event thrown by closing the a Vendor window
    Apollo.RegisterEventHandler("CloseVendorWindow",    "OnVendorClosed", self)

    -- Boolean to indicate options need configured
    self.bConfigOptions = true

    -- Init ReverseLookup
    for k,v in pairs(Item.CodeEnumItemQuality) do
        ktReverseQualityLookup[v] = k
    end
end

function JunkIt:OnDependencyError(strDep, strError)
    if strDep == "Vendor" then
        local tReplaced = Apollo.GetReplacement(strDep)
        if #tReplaced ~= 1 or not ktVendorAddons[tReplaced[1]] then
            return false
        end
        strParentAddon = tReplaced[1]
        return true
    end

    return false
end

---------------------------------------------------------------------------------------------------
-- JunkIt EventHandlers
---------------------------------------------------------------------------------------------------
local function FindAnchor(oAddon, strParentAddon)
    local aRef = strParentAddon == "Vendor" and oAddon.tWndRefs or oAddon
    local wndParent = aRef[ktVendorAddons[strParentAddon].wndVendor]

    if ktVendorAddons[strParentAddon].strAnchor then
        wndParent = wndParent:FindChild(ktVendorAddons[strParentAddon].strAnchor)
        if strParentAddon == "Vendor" then
            wndParent:SetAnchorOffsets(-1,27,215,466)
            local wndDefOpts = wndParent:FindChild("OptionsContainerFrame")
            wndDefOpts:Show(false, true)
        end
    end
    return wndParent
end

-- Sets the selected options on the Options Frame, this is delayed to ensure both new users
--  and people who have used the addon before see options as configured in the options pane.
--  uses bool to indicate has already been done.
function JunkIt:SetupJunkIt()
    -- Load forms, parent to vendor addon
    local wndParent = FindAnchor(self.vendorAddon, strParentAddon)
    self.wndJunkOpts = Apollo.LoadForm(self.Xml, "JunkItOptionsContainerFrame", wndParent, self)
    self.wndJunkButton = Apollo.LoadForm(self.Xml, "JunkButtonOverlay", self.vendorAddon.tWndRefs.wndVendor or self.vendorAddon.wndLilVendor, self)
    GeminiLocale:TranslateWindow(L, self.wndJunkOpts)

    -- Iterate through config options
    for k,v in pairs(self.config) do
        -- Boolean options are the checkboxes, so set the check appropriately
        if (type(v) == "boolean") then
            if self.wndJunkOpts:FindChild(k) ~= nil then
                self.wndJunkOpts:FindChild(k):SetCheck(v)
            end
        else -- Item Quality Type, set the ComboBox selected and the right color
            self.wndJunkOpts:FindChild("QualityDropDown"):SetText(Apollo.GetString("CRB_" .. ktReverseQualityLookup[v]))
            self.wndJunkOpts:FindChild("QualityDropDown"):SetNormalTextColor("ItemQuality_" .. ktReverseQualityLookup[v])
        end
    end
    -- Show/Hide Sell button based on autosell config
    self:SetButtonState()
    -- Set boolean to indicate options have been set
    if self.bConfigOptions then
        -- Turn off Base AutoSell
        self.vendorAddon.bAutoSellToVendor = false
        -- Indicate One-Time Config is done
        self.bConfigOptions = false
    end
end

-- Event Handler for Vendor Window closing
function JunkIt:OnVendorClosed()
    -- Hide Options window when vendor is closed, prevents options from being open next time vendor is opened
    --self.wndJunkOpts:Show(false)
    -- If we are showing a submenu get rid of it
    if self.wndSubMenu then
        self.wndSubMenu:Destroy()
    end
end

-- Event handler for WindowManagementAdd - Monitoring for Vendor SetupJunkIt
function JunkIt:OnWindowManagementAdd(windowInfo)
  self.WinInfo = windowInfo
  if windowInfo.strName ~= Apollo.GetString("CRB_Vendor") then
      return
  end
  -- Vendor Window appears to be destroyed so we have to reattach
  -- every time it is created
  self:SetupJunkIt()
end

-- Event handler for Vendor window opening.
function JunkIt:OnInvokeVendorWindow(unitArg)
    local nItemsSold = nil
    if self.config.autoSell then
        nItemsSold = self:SellItems(true)
    end

    local nItemsRepaired = nil
    if self.config.autoRepair and IsRepairVendor(unitArg) then
        nItemsRepaired = self:CanRepair(unitArg)
        if nItemsRepaired then
            if self.config.repairGuild then
                self.vendorAddon:OnGuildRepairBtn()
            else
                self:RepairItems(unitArg)
            end
        end
    end

    -- Didn't do anything interesting, exit out.
    if (not nItemsSold or nItemsSold == 0) and (not nItemsRepaired  or nItemsRepaired == 0) then return end

    local strAlertMsg = "JunkIt"

    if nItemsSold then
        strAlertMsg = strformat("%s: Sold %d Items", strAlertMsg, nItemsSold)
    end

    if nItemsRepaired then
        strAlertMsg = strformat("%s: Repaired %d Items", strAlertMsg, nItemsRepaired)
    end

    self:SendAlert(strAlertMsg)
end

function JunkIt:SendAlert(strAlert)
    self.strDelayedAlert = strAlert

    if tAlertTimer then
        tAlertTimer:Start()
    else
        tAlertTimer = ApolloTimer.Create(0.5, false, "OnDelayedAlert", self)
    end
end

function JunkIt:OnDelayedAlert()
    if self.strDelayedAlert then
        self.vendorAddon:ShowAlertMessageContainer(self.strDelayedAlert, false)
        self.strDelayedAlert = nil
    end
end

-----------------------------------------------------------------------------------------------
-- Selling Functions
-----------------------------------------------------------------------------------------------
function JunkIt:SellItems(bAuto)
    local tInventoryItems = GameLib.GetPlayerUnit():GetInventoryItems()
    local nItemCount = 0
    for _, v in ipairs(tInventoryItems) do
        if self:IsSellable(v.itemInBag) then
            nItemCount = nItemCount + v.itemInBag:GetStackCount()
            SellItemToVendorById(v.itemInBag:GetInventoryId(), v.itemInBag:GetStackCount())
        end
    end
    if not bAuto then
        self:SendAlert("JunkIt: Sold " .. nItemCount .. " Items")
    else
        return nItemCount
    end
end

function JunkIt:DebugSell(item)
    -- You can't sell items that don't exist or have no price
    if not item or not item:GetSellPrice() then return false end

    -- Determine if the item is junk, if it is, vend it!
    if item:GetItemCategory() == ItemCategory.Junk and item:GetItemQuality() == Item.CodeEnumItemQuality.Inferior then
        Print(item:GetName() .. " will be auto-sold. [Type == Junk]")
        return true
    end

    -- If item quality is set to inferior, keep all items
    if self.config.minSellQuality == Item.CodeEnumItemQuality.Inferior then
        Print(item:GetName() .. " will not be auto-sold [Junk Only Threshold]")
        return false
    end

    -- If we are keeping salvagable items and this one is salvageable, then this isn't for sale
    if self.config.keepSalvage and item:CanSalvage() then
        Print(item:GetName() .. " will not be auto-sold [Keep Salvage Items]")
        return false
    end

    -- Pull the itemFamily to reduce # of function calls
    local itemFamily = item:GetItemFamily()

    --  Are we selling this type of item?
    if ((itemFamily == ItemFamily.Armor and self.config.sellArmor) or
        (itemFamily == ItemFamily.Weapon and self.config.sellWeapons) or
        (itemFamily == ItemFamily.Ornamental and self.config.sellShields) or
        (itemFamily == ItemFamily.Housing and self.config.sellHousing) or
        (itemFamily == ItemFamily.Costume and self.config.sellCostumes)) then
        -- Is it under our threshold?
        if item:GetItemQuality() == Item.CodeEnumItemQuality.Inferior or self.config.minSellQuality > item:GetItemQuality() then
            Print(item:GetName() .. " will be auto-sold ["..itemFamily.." type set and meets qual (Type: ".. item:GetItemFamilyName() ..", Qual:" .. item:GetItemQuality()")]")
            return true
        end
    end

    -- Default is no, it is not sellable
    Print(item:GetName() .. " will not be auto-sold [Does not match filters (Item type or Quality)]")
    return false
end

function JunkIt:IsSellable(item)
    if self.config.Debug then return self:DebugSell(item) end
    -- You can't sell items that don't exist or have no price
    if not item or not item:GetSellPrice() then return false end

    -- Determine if the item is junk, if it is, vend it!
    if item:GetItemCategory() == ItemCategory.Junk and item:GetItemQuality() == Item.CodeEnumItemQuality.Inferior then return true end

    -- If item quality is set to inferior, keep all items
    if self.config.minSellQuality == Item.CodeEnumItemQuality.Inferior then return false end

    -- If we are keeping salvagable items and this one is salvageable, then this isn't for sale
    if self.config.keepSalvage and item:CanSalvage() then return false end

    -- Pull the itemFamily to reduce # of function calls
    local itemFamily = item:GetItemFamily()

    --  Are we selling this type of item?
    if ((itemFamily == ItemFamily.Armor and self.config.sellArmor) or
        (itemFamily == ItemFamily.Weapon and self.config.sellWeapons) or
        (itemFamily == ItemFamily.Ornamental and self.config.sellShields) or
        (itemFamily == ItemFamily.Housing and self.config.sellHousing) or
        (itemFamily == ItemFamily.Costume and self.config.sellCostumes)) then

        -- Is it under our threshold?
        if item:GetItemQuality() == Item.CodeEnumItemQuality.Inferior or self.config.minSellQuality > item:GetItemQuality() then return true end
    end

    -- Default is no, it is not sellable
    return false
end

---------------------------------------------------------------------------------------------------
-- Save/Restore Settings Functions
---------------------------------------------------------------------------------------------------
function JunkIt:OnSave(eLevel)
    if eLevel ~= GameLib.CodeEnumAddonSaveLevel.Character then return nil end
    return self.config
end

function JunkIt:OnRestore(eLevel, tData)
    TableMerge(self.config, tData)
end

-----------------------------------------------------------------------------------------------
-- Repair Functions
-----------------------------------------------------------------------------------------------
local function IsValidRepairable(tItem)
    -- Costume Sets 1-6
    if tItem.idLocation >= 2304 and tItem.idLocation <= 2405 then
        return false
    end
    return true
end

function JunkIt:RepairItems(unitArg)
    -- Perform Repair
    RepairAllItemsVendor()
    -- Reset Repair Tab information
    self.vendorAddon:RefreshRepairTab()
    -- return the number of items repaired
    Sound.Play(Sound.PlayUIVendorRepair)
end

function JunkIt:CanRepair(unitArg)
    local repairableItems = unitArg:GetRepairableItems()
    local nCount = 0
    for _,v in ipairs(repairableItems) do
        if IsValidRepairable(v) then
            nCount = nCount + 1
        end
    end
    if nCount == 0 then
        return false
    end
    return nCount
end

-----------------------------------------------------------------------------------------------
-- Guild Functions
-----------------------------------------------------------------------------------------------
function JunkIt:GuildRepair(unitArg)
    local tMyGuild
    for idx, tGuild in pairs(GuildLib.GetGuilds()) do
        if tGuild:GetType() == GuildLib.GuildType_Guild then
            tMyGuild = tGuild
            break
        end
    end

    if not tMyGuild then
        self:RepairItems()
        return
    end

    local tMyRankData = tMyGuild:GetRanks()[tMyGuild:GetMyRank()]
    local nAvailableFunds
    local nRepairRemainingToday = mathmin(knMaxGuildLimit, tMyRankData.monBankRepairLimit:GetAmount()) - tMyGuild:GetBankMoneyRepairToday():GetAmount()
    if tMyGuild:GetMoney():GetAmount() <= nRepairRemainingToday then
        nAvailableFunds = tMyGuild:GetMoney():GetAmount()
    else
        nAvailableFunds = nRepairRemainingToday
    end

    local repairableItems = unitArg:GetRepairableItems()
    local nRepairAllCost = 0
    for key, tCurrItem in pairs(repairableItems) do
        if IsValidRepairable(tCurrItem) then
            local tCurrPrice = mathmax(tCurrItem.tPriceInfo.nAmount1, tCurrItem.tPriceInfo.nAmount2) * tCurrItem.nStackSize
            nRepairAllCost = nRepairAllCost + tCurrPrice
        end
    end
    if nRepairAllCost <= nAvailableFunds then
        tMyGuild:RepairAllItemsVendor()
        local monRepairAllCost = GameLib.GetRepairAllCost()
        self.vendorAddon[ktVendorAddons[strParentAddon].wndVendor]:FindChild("AlertCost"):SetMoneySystem(Money.CodeEnumCurrencyType.Credits)
        self.vendorAddon[ktVendorAddons[strParentAddon].wndVendor]:FindChild("AlertCost"):SetAmount(monRepairAllCost)
    else
        self:RepairItems()
        return
    end
    Sound.Play(Sound.PlayUIVendorRepair)
end

---------------------------------------------------------------------------------------------------
-- VendorWindow Functions
---------------------------------------------------------------------------------------------------

-- Handle the Options button, both show and hide
function JunkIt:OnOptionsMenuToggle( wndHandler, wndControl, eMouseButton )
    self.wndJunkOpts:FindChild("OptionsContainer"):Show(self.wndOpt:FindChild("OptionsBtn"):IsChecked())
end

---------------------------------------------------------------------------------------------------
-- VendorWindowOverlay Functions
---------------------------------------------------------------------------------------------------

-- Handler for Options Close button
function JunkIt:OnOptionsCloseClick( wndHandler, wndControl, eMouseButton )
    self.wndOpt:FindChild("OptionsBtn"):SetCheck(false)
    self:OnOptionsMenuToggle()
end

-- Handler for Junk Button
function JunkIt:OnJunkButtonClick( wndHandler, wndControl, eMouseButton )
    self:SellItems()
end

---------------------------------------------------------------------------------------------------
-- OptionsContainer Functions
---------------------------------------------------------------------------------------------------

function JunkIt:SetButtonState()
    local showButton
    if self.config.autoSell ~= nil then
        showButton = self.config.showButton
    else
        showButton = true
    end

    self.wndJunkButton:Show(showButton)
    self.wndJunkOpts:FindChild("showButton"):Show(self.config.autoSell)
    self.wndJunkOpts:FindChild("repairGuild"):Show(self.config.autoRepair)
end

-- Handler for all of the checkboxes in the Options window
function JunkIt:OnCheckboxChange( wndHandler, wndControl, eMouseButton )
    local wndControlName = wndControl:GetName()
    self.config[wndControlName] = wndControl:IsChecked()
    -- Special cases, aren't they special?
    -- If we turn on AutoSell, or change the showButton setting, honor it.
    if wndControlName == "autoSell" then
        wndControl:FindChild("showButton"):Show(self.config.autoSell)
    end
    self:SetButtonState()
end

function JunkIt:OnQualityPopoutToggle( wndHandler, wndControl, eMouseButton )
    if self.wndSubMenu and self.wndSubMenu:GetParent() == wndControl then
        if not wndControl:IsChecked() and self.wndSubMenu then
            self.wndSubMenu:Destroy()
        end
        return
    end
    if self.wndSubMenu then
        self.wndSubMenu:Destroy()
    end
    self.wndSubMenu = Apollo.LoadForm(self.Xml, "QualityMenu", wndControl, self)
    local strBtnName = "sell" .. strmatch(self.wndSubMenu:GetData():GetName(),"(.-)Container")
    self.wndSubMenu:SetData(wndControl:GetParent():FindChild(strBtnName))
end

function JunkIt:OnQualityDropdownToggle( wndHandler, wndControl, eMouseButton )
    if self.wndSubMenu then
        self.wndSubMenu:Destroy()
        if not wndControl:IsChecked() then
            return
        end
    end
    self.wndSubMenu = Apollo.LoadForm(self.Xml, "QualityMenu", wndControl, self)
    self.wndSubMenu:SetData(wndControl)
    self.wndSubMenu:SetAnchorPoints(0,1,1,0)
    self.wndSubMenu:SetAnchorOffsets(-21, -26, 21, 246)
end

---------------------------------------------------------------------------------------------------
-- QualityMenu Functions
---------------------------------------------------------------------------------------------------

function JunkIt:OnQualityBtnClicked( wndHandler, wndControl, eMouseButton )
    self.wndSubMenu:GetData():SetText(wndControl:FindChild("QualityBtnTxt"):GetText())
    self.wndSubMenu:GetData():SetNormalTextColor("ItemQuality_"..wndControl:GetName())
    self.wndSubMenu:GetData():SetCheck(false)

    local strWndName = wndControl:GetName()
    for k,v in pairs(ktReverseQualityLookup) do
        if v == strWndName then
            self.config.minSellQuality = k
            break
        end
    end

    self.wndSubMenu:Destroy()
    if self.config.autoSell then
        self:SellItems()
    end
end

---------------------------------------------------------------------------------------------------
-- JunkIt instance
---------------------------------------------------------------------------------------------------
local JunkItInst = JunkIt:new()
JunkItInst:Init()
