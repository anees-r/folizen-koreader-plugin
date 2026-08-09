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
    self.pending_words = {} -- word -> true, looked up this session, not yet synced
    self.ui.menu:registerToMainMenu(self)

    if FolizenSettings.isLoggedIn() then
        UIManager:scheduleIn(2, function()
            local NetworkMgr = require("ui/network/manager")
            if NetworkMgr:isConnected() then
                local ok, body = Api.getSettings()
                if ok and body then
                    FolizenSettings.applyServerPrefs(body)
                end
            end
        end)
    end
end

-- ============================= Menu ================================

function Folizen:addToMainMenu(menu_items)
    menu_items.folizen = {
        text = _("Folizen"),
        sorting_hint = "tools",
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
            enabled_func = function()
                return self.ui and self.ui.doc_settings and not BookIdentity.isSyncDisabled(self.ui.doc_settings)
            end,
            callback = function() self:syncCurrentBook(true) end,
        },
        {
            text_func = function()
                if self.ui and self.ui.doc_settings and BookIdentity.isSyncDisabled(self.ui.doc_settings) then
                    return _("Re-enable sync for this book")
                end
                return _("Don't sync this book")
            end,
            keep_menu_open = true,
            enabled_func = function() return self.ui and self.ui.doc_settings end,
            callback = function()
                if not (self.ui and self.ui.doc_settings) then return end
                local currently_disabled = BookIdentity.isSyncDisabled(self.ui.doc_settings)
                BookIdentity.setSyncDisabled(self.ui.doc_settings, not currently_disabled)
                if currently_disabled then
                    UIManager:show(InfoMessage:new{ text = _("Sync re-enabled for this book — it'll ask you to link or add it next sync.") })
                else
                    UIManager:show(InfoMessage:new{ text = _("This book won't sync to Folizen anymore.") })
                end
            end,
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
                UIManager:show(ConfirmBox:new{
                    text = _("Import your reading history now? This pulls in past ratings, reviews, finished dates, vocabulary, and your reading calendar. It can take a minute and is safe to run later from the Folizen menu instead."),
                    ok_text = _("Import now"),
                    cancel_text = _("Later"),
                    ok_callback = function()
                        self:syncReadingHistory(true)
                    end,
                })
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

-- KOReader fires this when the reader looks a word up in the built-in
-- dictionary (this is the event vocabbuilder.koplugin itself listens for
-- to build its own database — written from that reference pattern, not
-- guessed from nothing, but still worth confirming on your KOReader
-- version if words stop showing up here).
--
-- We track words in memory rather than re-reading vocabbuilder's sqlite
-- file live: that file is only flushed to disk on KOReader's own
-- schedule, so reading it immediately after a lookup can miss words that
-- haven't been written yet — which is exactly why words only showed up
-- after "Sync reading history" (which reads the file later, once it's
-- caught up) and never from a normal in-session sync.
function Folizen:onLookupWord(word)
    if word and word ~= "" then
        self.pending_words[word] = true
    end
end

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

            local progress_ok, _progress_body, _progress_err, progress_status =
                Api.syncProgress(book_id, current_page, total_pages, percent)

            -- The server no longer recognizes this book for us — most
            -- likely the cached link (saved in this book's own sidecar
            -- file) points at an ID from before a database reset/reseed.
            -- Clear the cache so the NEXT sync re-resolves (and, if it's
            -- genuinely unrecognized, re-prompts) instead of failing the
            -- same way forever.
            if not progress_ok and progress_status == 404 then
                if self.ui.doc_settings then
                    self.ui.doc_settings:saveSetting("folizen_book_id", nil)
                    self.ui.doc_settings:flush()
                end
                if announce then
                    UIManager:show(InfoMessage:new{
                        text = _("Folizen lost track of this book (likely a server reset) — linked it again, try Sync now once more."),
                    })
                else
                    UIManager:show(InfoMessage:new{ text = _("Folizen: re-linking this book, it'll catch up on the next sync.") })
                end
                return
            end

            -- Rating/review/finished-status, set via KOReader's own Book
            -- Status dialog, live off self.ui.doc_settings. This was
            -- previously never sent at all.
            local status_ok, status = pcall(function() return BookHistory.summaryFor(self.ui.doc_settings) end)
            if status_ok and status then
                Api.syncStatus(book_id, status.shelf, status.rating, status.review, status.finishedAt)
            end

            local highlight_list = Highlights.extract(self.ui.doc_settings)
            if #highlight_list > 0 then
                Api.syncHighlights(book_id, highlight_list)
            end

            local props = self.ui.document:getProps() or {}
            local db_words = Vocabulary.wordsForBook(props.title or "")

            -- Merge the live in-session lookups with whatever's in
            -- vocabbuilder's own database, deduped, so a word looked up
            -- moments ago syncs immediately rather than waiting for a
            -- history import or the sqlite file to catch up.
            local word_set = {}
            for _, w in ipairs(db_words) do word_set[w] = true end
            for w in pairs(self.pending_words) do word_set[w] = true end

            local words = {}
            for w in pairs(word_set) do table.insert(words, w) end

            if #words > 0 then
                Api.syncVocabulary(book_id, words)
                self.pending_words = {}
            end

            -- If any call above hit a 401, Api.request() already cleared
            -- the stored session — surface that now rather than silently
            -- going dark, even on a background (non-announced) sync.
            if not FolizenSettings.isLoggedIn() then
                UIManager:show(InfoMessage:new{
                    text = _("Your Folizen session ended — please sign in again from the Folizen menu."),
                })
                return
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

        -- Yield to the UI thread so the "syncing" message actually paints
        -- before the blocking network work below starts, instead of the
        -- whole app appearing to freeze/hang the instant this runs.
        UIManager:scheduleIn(0.1, function()
            local daily_count, book_count = 0, 0

            -- Every stage (and every item within it) is individually
            -- pcall-guarded: a bad row from one book, or one companion
            -- plugin's database being in an unexpected shape, must never
            -- be able to abort the whole import or crash the app.
            local overall_ok, overall_err = pcall(function()
                -- 1. Daily pages/duration, from statistics.koplugin.
                local stage1_ok, daily = pcall(function() return StatsHistory.dailyTotals() end)
                if stage1_ok and daily then
                    daily_count = #daily
                    for _pidx, piece in ipairs(chunk(daily, 200)) do
                        if not FolizenSettings.isLoggedIn() then break end
                        pcall(function() Api.syncReadingDays(piece) end)
                    end
                end

                if not FolizenSettings.isLoggedIn() then return end

                -- 2. Per-book rating/review/finished-status.
                local title_to_book_id = {}
                local stage2_ok, book_entries = pcall(function() return BookHistory.collectAll() end)
                if stage2_ok and book_entries then
                    for _eidx, entry in ipairs(book_entries) do
                        if not FolizenSettings.isLoggedIn() then break end
                        pcall(function()
                            local book_id = BookIdentity.resolveByIdentity(entry.deviceBookKey, entry.title, entry.author)
                            if book_id then
                                title_to_book_id[entry.title] = book_id
                                if entry.shelf or entry.rating or entry.review then
                                    Api.syncStatus(book_id, entry.shelf, entry.rating, entry.review, entry.finishedAt)
                                end
                                if entry.highlights and #entry.highlights > 0 then
                                    Api.syncHighlights(book_id, entry.highlights)
                                end
                                book_count = book_count + 1
                            end
                        end)
                    end
                end

                if not FolizenSettings.isLoggedIn() then return end

                -- 3. Vocabulary, grouped by book title.
                local stage3_ok, vocab_groups = pcall(function() return Vocabulary.allWordsByTitle() end)
                if stage3_ok and vocab_groups then
                    for _vidx, group in ipairs(vocab_groups) do
                        if not FolizenSettings.isLoggedIn() then break end
                        pcall(function()
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
                        end)
                    end
                end
            end)

            if info then UIManager:close(info) end

            -- A 401 anywhere above already cleared the stored session
            -- (Api.request() does this centrally) — that's the case that
            -- used to show a false "synced!" message after an account was
            -- deleted, since nothing actually *threw* a Lua error.
            if not FolizenSettings.isLoggedIn() then
                UIManager:show(InfoMessage:new{
                    text = _("Your Folizen session ended partway through — please sign in again from the Folizen menu."),
                })
                return
            end

            if announce then
                if overall_ok then
                    UIManager:show(InfoMessage:new{
                        text = _("Reading history synced: ") .. daily_count .. _(" days, ") .. book_count .. _(" books."),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Reading history import hit a problem partway through, but nothing should be broken — check crash.log for details."),
                    })
                end
            end
        end)
    end)
end

return Folizen
