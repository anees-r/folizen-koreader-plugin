--[[
Folizen KOReader plugin — entry point.

Written against KOReader's plugin conventions (WidgetContainer-derived
reader module, addToMainMenu, onPageUpdate/onCloseDocument event hooks)
from reference knowledge of the KOReader plugin API. It has not been
exercised against a live KOReader install/emulator in this build
environment — treat this as a strong, structurally-correct starting
point, and expect to do a normal round of on-device debugging before
shipping it, the same as any new KOReader plugin.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("gettext")

local FolizenSettings = require("settings")
local Api = require("api")
local Net = require("network")
local BookIdentity = require("book_identity")
local Highlights = require("highlights")
local Vocabulary = require("vocabulary")
local Downloads = require("downloads")
local BookHistory = require("book_history")
local StatsHistory = require("stats_history")

local Folizen = WidgetContainer:extend{
    name = "folizen",
    is_doc_only = false,
}

function Folizen:init()
    self.pages_since_sync = 0
    self.current_book_id = nil
    self.ui.menu:registerToMainMenu(self)
end

-- ============================= Menu ================================

function Folizen:addToMainMenu(menu_items)
    menu_items.folizen = {
        text = _("Folizen"),
        sorting_hint = "more_tools",
        sub_item_table_func = function() return self:getMenuItems() end,
    }
end

function Folizen:getMenuItems()
    if not FolizenSettings.isLoggedIn() then
        return {
            {
                text = _("Sign in to Folizen…"),
                keep_menu_open = true,
                callback = function() self:showLoginDialog() end,
            },
            {
                text = _("Server URL: ") .. (FolizenSettings.get("server_url") or ""),
                keep_menu_open = true,
                callback = function() self:showServerUrlDialog() end,
            },
        }
    end

    return {
        {
            text = _("Signed in as ") .. (FolizenSettings.get("username") or ""),
            enabled = false,
        },
        {
            text = _("Sync this book now"),
            keep_menu_open = true,
            callback = function() self:syncCurrentBook(true) end,
        },
        {
            text = _("Sync reading history…"),
            keep_menu_open = true,
            callback = function() self:syncReadingHistory(true) end,
        },
        {
            text = _("Download queue"),
            keep_menu_open = true,
            callback = function() Downloads.show() end,
        },
        {
            text = _("Auto-sync"),
            checked_func = function() return FolizenSettings.get("auto_sync_enabled") end,
            callback = function()
                local new_val = not FolizenSettings.get("auto_sync_enabled")
                FolizenSettings.set("auto_sync_enabled", new_val)
                Api.patchSettings({ autoSyncEnabled = new_val })
            end,
        },
        {
            text = _("Sync every N pages…"),
            keep_menu_open = true,
            callback = function() self:showThresholdDialog() end,
        },
        {
            text = _("Allow Folizen to turn on Wi-Fi automatically"),
            checked_func = function() return FolizenSettings.get("wifi_auto_enable") end,
            callback = function()
                local new_val = not FolizenSettings.get("wifi_auto_enable")
                FolizenSettings.set("wifi_auto_enable", new_val)
                Api.patchSettings({ wifiAutoEnable = new_val })
            end,
        },
        {
            text = _("Sign out"),
            keep_menu_open = true,
            callback = function() self:logout() end,
        },
    }
end

-- ============================= Auth ================================

function Folizen:showServerUrlDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Folizen server URL"),
        input = FolizenSettings.get("server_url"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                FolizenSettings.set("server_url", dialog:getInputText())
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Folizen:showLoginDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Sign in to Folizen"),
        input_hint = _("username or email"),
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Next"), callback = function()
                local identifier = dialog:getInputText()
                UIManager:close(dialog)
                self:showPasswordDialog(identifier)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Folizen:showPasswordDialog(identifier)
    local dialog
    dialog = InputDialog:new{
        title = _("Password"),
        text_type = "password",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Sign in"), callback = function()
                local password = dialog:getInputText()
                UIManager:close(dialog)
                self:doLogin(identifier, password)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Folizen:doLogin(identifier, password)
    Net.withConnection(function()
        local device_label = (Device.model or "KOReader device")
        local ok, body, err = Api.login(identifier, password, device_label)
        if ok and body and body.refreshToken then
            FolizenSettings.set("refresh_token", body.refreshToken)
            FolizenSettings.set("username", body.username)
            FolizenSettings.applyServerPrefs(body.settings)
            UIManager:show(InfoMessage:new{ text = _("Signed in as ") .. body.username })

            if not FolizenSettings.get("history_synced_once") then
                FolizenSettings.set("history_synced_once", true)
                self:syncReadingHistory(false)
            end
        else
            UIManager:show(InfoMessage:new{ text = _("Sign-in failed: ") .. tostring(err) })
        end
    end)
end

function Folizen:logout()
    Net.withConnection(function()
        Api.logout() -- best-effort; revoke locally regardless of network result
        FolizenSettings.clearSession()
        UIManager:show(InfoMessage:new{ text = _("Signed out of Folizen.") })
    end)
end

function Folizen:showThresholdDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Sync after this many pages turned"),
        input = tostring(FolizenSettings.get("sync_threshold_pages")),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                local n = tonumber(dialog:getInputText()) or 5
                n = math.max(1, math.min(100, math.floor(n)))
                FolizenSettings.set("sync_threshold_pages", n)
                Api.patchSettings({ syncThresholdPages = n })
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ========================= Sync orchestration =========================

-- Called by KOReader on every page turn while a document is open.
function Folizen:onPageUpdate(_page)
    if not FolizenSettings.isLoggedIn() then return end
    if not FolizenSettings.get("auto_sync_enabled") then return end

    self.pages_since_sync = self.pages_since_sync + 1
    local threshold = FolizenSettings.get("sync_threshold_pages") or 5

    if self.pages_since_sync >= threshold then
        self.pages_since_sync = 0
        self:syncCurrentBook(false)
    end
end

function Folizen:onEndOfBook()
    if FolizenSettings.isLoggedIn() then
        self:syncCurrentBook(true)
    end
end

function Folizen:onCloseDocument()
    if FolizenSettings.isLoggedIn() and FolizenSettings.get("auto_sync_enabled") then
        self:syncCurrentBook(false)
    end
end

-- The core sync routine: resolves book identity, then pushes progress,
-- highlights, and vocabulary. `announce` shows a toast either way when
-- true (used for the manual "Sync this book now" menu action).
function Folizen:syncCurrentBook(announce)
    if not self.ui or not self.ui.document then return end

    Net.withConnection(function()
        BookIdentity.resolve(self.ui, function(book_id)
            if not book_id then
                if announce then
                    UIManager:show(InfoMessage:new{ text = _("Folizen: couldn't identify this book.") })
                end
                return
            end

            local current_page = self.ui.getCurrentPage and self.ui:getCurrentPage() or nil
            local total_pages = self.ui.document.getPageCount and self.ui.document:getPageCount() or nil
            local percent = (current_page and total_pages and total_pages > 0)
                and (current_page / total_pages * 100) or nil

            Api.syncProgress(book_id, current_page, total_pages, percent)

            -- Rating/review/finished-status, set via KOReader's own Book
            -- Status dialog, live off self.ui.doc_settings. This was
            -- previously never sent at all.
            local status = BookHistory.summaryFor(self.ui.doc_settings)
            if status then
                Api.syncStatus(book_id, status.shelf, status.rating, status.review, status.finishedAt)
            end

            local highlight_list = Highlights.extract(self.ui.doc_settings)
            if #highlight_list > 0 then
                Api.syncHighlights(book_id, highlight_list)
            end

            local props = self.ui.document:getProps() or {}
            local words = Vocabulary.wordsForBook(props.title or "")
            if #words > 0 then
                Api.syncVocabulary(book_id, words)
            end

            if announce then
                UIManager:show(InfoMessage:new{ text = _("Synced to Folizen.") })
            end
        end)
    end)
end

-- Chunks a list into pieces of at most `size` items.
local function chunk(list, size)
    local chunks = {}
    for i = 1, #list, size do
        local piece = {}
        for j = i, math.min(i + size - 1, #list) do
            table.insert(piece, list[j])
        end
        table.insert(chunks, piece)
    end
    return chunks
end

-- Pulls together everything KOReader already knows from before this
-- device ever talked to Folizen: daily pages/duration (statistics.koplugin),
-- per-book rating/review/finish-date (KOReader's own Book Status dialog,
-- read from every book in KOReader's reading history), and vocabulary
-- words looked up per book (vocabbuilder.koplugin). Runs once
-- automatically after first login, and any time from the menu after that.
-- Entirely best-effort: any missing companion plugin/data just means that
-- piece is skipped, never an error shown to the reader unless `announce`.
function Folizen:syncReadingHistory(announce)
    if not FolizenSettings.isLoggedIn() then return end

    Net.withConnection(function()
        local info
        if announce then
            info = InfoMessage:new{ text = _("Syncing reading history — this can take a moment…") }
            UIManager:show(info)
        end

        -- 1. Daily pages/duration, from statistics.koplugin, chunked so one
        -- huge multi-year history doesn't become a single giant request.
        local daily = StatsHistory.dailyTotals()
        for _, piece in ipairs(chunk(daily, 200)) do
            Api.syncReadingDays(piece)
        end

        -- 2. Per-book rating/review/finished-status, from every book in
        -- KOReader's own reading history. Track title -> book_id as we go
        -- so step 3 (vocabulary) can reuse the same resolution without a
        -- second round of book-identity lookups.
        local title_to_book_id = {}
        local book_entries = BookHistory.collectAll()
        for _, entry in ipairs(book_entries) do
            local book_id = BookIdentity.resolveByIdentity(entry.deviceBookKey, entry.title, entry.author)
            if book_id then
                title_to_book_id[entry.title] = book_id
                Api.syncStatus(book_id, entry.shelf, entry.rating, entry.review, entry.finishedAt)
            end
        end

        -- 3. Vocabulary, grouped by book title. Reuses a book_id already
        -- resolved in step 2 when the titles match; otherwise resolves it
        -- fresh (a book with looked-up words but no status set yet).
        local vocab_groups = Vocabulary.allWordsByTitle()
        for _, group in ipairs(vocab_groups) do
            if group.words and #group.words > 0 then
                local book_id = title_to_book_id[group.title]
                if not book_id then
                    book_id = BookIdentity.resolveByIdentity(nil, group.title, _("Unknown author"))
                    if book_id then title_to_book_id[group.title] = book_id end
                end
                if book_id then
                    Api.syncVocabulary(book_id, group.words)
                end
            end
        end

        if info then UIManager:close(info) end
        if announce then
            UIManager:show(InfoMessage:new{
                text = _("Reading history synced: ") .. #daily .. _(" days, ") .. #book_entries .. _(" books."),
            })
        end
    end)
end

return Folizen
