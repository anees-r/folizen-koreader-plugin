--[[
Maps a KOReader document to a Folizen `bookId`.

deviceBookKey is KOReader's own "partial MD5" checksum of the file —
verified (not guessed) by reading statistics.koplugin's source, which
uses this exact same value (cached under doc_settings key
"partial_md5_checksum") to identify books in its own database.

Resolution order (requirements.md section 5.7):
  1. Cached bookId in this doc's own sidecar settings (fast path).
  2. If the reader has opted this book out of syncing, stop silently.
  3. If the device key already matches a book the server knows about
     (e.g. re-installed plugin, same file synced from elsewhere),
     link silently — no need to ask again about a book we already know.
  4. Otherwise ALWAYS ask: link to an existing book, add as new, or
     don't sync this book. An earlier version of this file only asked
     when a same-titled book happened to already exist, and silently
     auto-created otherwise — which for a personal library with no
     duplicate titles meant it silently created every single time and
     never actually asked.
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local InputDialog = require("ui/widget/inputdialog")
local util = require("util")
local _ = require("gettext")

local Api = require("api")

local BookIdentity = {}

local function device_key_for_doc_settings(doc_settings)
    if not doc_settings then return nil end
    local ok, key = pcall(function() return doc_settings:readSetting("partial_md5_checksum") end)
    if ok and key then return key end
    return nil
end

function BookIdentity.isSyncDisabled(doc_settings)
    if not doc_settings then return false end
    local ok, disabled = pcall(function() return doc_settings:readSetting("folizen_sync_disabled") end)
    return ok and disabled == true
end

function BookIdentity.setSyncDisabled(doc_settings, disabled)
    if not doc_settings then return end
    doc_settings:saveSetting("folizen_sync_disabled", disabled or nil)
    doc_settings:saveSetting("folizen_book_id", nil) -- clear any prior link
    doc_settings:flush()
end

local function show_search_and_pick(title_guess, on_pick, on_create_new, on_cancel)
    local search_dialog
    search_dialog = InputDialog:new{
        title = _("Search your Folizen library"),
        input = title_guess,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(search_dialog) on_cancel() end },
            { text = _("Search"), callback = function()
                local query = search_dialog:getInputText()
                UIManager:close(search_dialog)

                local ok, body = Api.searchBooks(query)
                local results = (ok and body and body.results) or {}

                if #results == 0 then
                    UIManager:show(InfoMessage:new{ text = _("No matches found.") })
                    on_cancel()
                    return
                end

                local results_menu
                local items = {}
                for _ridx, r in ipairs(results) do
                    table.insert(items, {
                        text = r.title .. " — " .. r.author,
                        callback = function()
                            UIManager:close(results_menu)
                            on_pick(r.bookId)
                        end,
                    })
                end
                table.insert(items, {
                    text = _("None of these — add as a new book"),
                    callback = function()
                        UIManager:close(results_menu)
                        on_create_new()
                    end,
                })
                results_menu = Menu:new{
                    title = _("Which book is this?"),
                    item_table = items,
                    width = require("device").screen:getWidth() * 0.8,
                }
                UIManager:show(results_menu)
            end },
        }},
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

local function show_first_time_prompt(title, on_link_existing, on_create_new, on_skip)
    local dialog
    dialog = ButtonDialog:new{
        title = _("New to Folizen: \"") .. title .. _("\"\n\nWhat should happen with this book?"),
        buttons = {
            {{ text = _("Link to a book already in my library"), callback = function()
                UIManager:close(dialog)
                on_link_existing()
            end }},
            {{ text = _("Add as a new book"), callback = function()
                UIManager:close(dialog)
                on_create_new()
            end }},
            {{ text = _("Don't sync this book"), callback = function()
                UIManager:close(dialog)
                on_skip()
            end }},
        },
    }
    UIManager:show(dialog)
end

-- ui: the ReaderUI instance. callback(book_id_or_nil)
function BookIdentity.resolve(ui, callback)
    local doc_settings = ui.doc_settings

    if BookIdentity.isSyncDisabled(doc_settings) then
        callback(nil)
        return
    end

    local cached = doc_settings and doc_settings:readSetting("folizen_book_id")
    if cached then
        callback(cached)
        return
    end

    local key = device_key_for_doc_settings(doc_settings)
    if not key and ui.document and ui.document.file then
        local ok, hash = pcall(util.partialMD5, ui.document.file)
        if ok then key = hash end
    end

    local props = ui.document:getProps() or {}
    local title = props.title and props.title ~= "" and props.title or util.splitFileNameSuffix(ui.document.file)
    local author = props.authors or props.author or _("Unknown author")

    local function store_and_return(book_id)
        if doc_settings and book_id then
            doc_settings:saveSetting("folizen_book_id", book_id)
            doc_settings:flush()
        end
        callback(book_id)
    end

    -- Known device key match: link silently, no need to ask again.
    if key then
        local ok, body = Api.findByDeviceKey(key)
        if ok and body and body.results and body.results[1] then
            store_and_return(body.results[1].bookId)
            return
        end
    end

    -- Anything else: always ask, every time, for every unresolved book.
    show_first_time_prompt(
        title,
        function() -- link to existing
            show_search_and_pick(
                title,
                function(picked_book_id)
                    local link_ok, link_body = Api.linkBook({ bookId = picked_book_id, deviceBookKey = key })
                    store_and_return(link_ok and link_body and link_body.bookId or nil)
                end,
                function() -- "none of these" inside search -> create new
                    local link_ok, link_body = Api.linkBook({ deviceBookKey = key, title = title, author = author })
                    store_and_return(link_ok and link_body and link_body.bookId or nil)
                end,
                function() callback(nil) end -- cancelled search entirely
            )
        end,
        function() -- add as new
            local link_ok, link_body = Api.linkBook({ deviceBookKey = key, title = title, author = author })
            store_and_return(link_ok and link_body and link_body.bookId or nil)
        end,
        function() -- don't sync this book
            BookIdentity.setSyncDisabled(doc_settings, true)
            callback(nil)
        end
    )
end

-- Called on logout (section 5.2: logout clears "any locally cached sync
-- state"). Sweeps every book KOReader has ever opened and clears Folizen's
-- own per-book bookkeeping (the link to a server book_id, and the
-- don't-sync flag) so a different account signing in on this device
-- doesn't inherit stale links to books it can't see. Never touches
-- anything else in the sidecar — summary (status/rating/review),
-- annotations (highlights/notes), or KOReader's own progress fields are
-- untouched, since those belong to KOReader, not Folizen.
function BookIdentity.clearAllLocalLinks()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or not ReadHistory.hist then return end
    local DocSettings = require("docsettings")

    for _, entry in ipairs(ReadHistory.hist) do
        local file = entry.file
        if file then
            local fh = io.open(file, "rb")
            if fh then
                fh:close()
                local open_ok, docinfo = pcall(function() return DocSettings:open(file) end)
                if open_ok and docinfo then
                    pcall(function() BookIdentity.setSyncDisabled(docinfo, false) end)
                end
            end
        end
    end
end

-- Non-interactive variant for bulk/background imports (history sync),
-- where prompting the reader once per historical book would be unusable.
-- Tries the device key first, then falls back straight to auto-create —
-- never shows a picker.
function BookIdentity.resolveByIdentity(key, title, author)
    if key then
        local ok, body = Api.findByDeviceKey(key)
        if ok and body and body.results and body.results[1] then
            return body.results[1].bookId
        end
    end

    local link_ok, link_body = Api.linkBook({ deviceBookKey = key, title = title, author = author or _("Unknown author") })
    if link_ok and link_body then
        return link_body.bookId
    end
    return nil
end

return BookIdentity
