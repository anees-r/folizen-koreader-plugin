--[[
Maps the currently-open KOReader document to a Folizen `bookId`.

KOReader already computes a stable partial-MD5 hash per document (used
internally for its own reading-statistics and history features), which
we reuse as `deviceBookKey` — it survives file renames/moves better than
a path, and requires no extra hashing work on our end.

Resolution order (requirements.md section 5.7):
  1. Cached bookId in this doc's own sidecar settings (fast path).
  2. Ask the server if it already knows this deviceBookKey.
  3. Ask the reader to pick from a search of their existing library.
  4. Fall back to auto-creating a new book from the file's title/author
     metadata, same as a manual "Add book" on the web app.
]]

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local util = require("util")
local _ = require("gettext")

local Api = require("api")

local BookIdentity = {}

local function device_key_for(document)
    local ok, hash = pcall(function() return document:fastDigest() end)
    if ok and hash then return hash end
    -- Older KOReader versions exposed this on the file directly.
    local ok2, hash2 = pcall(util.partialMD5, document.file)
    if ok2 and hash2 then return hash2 end
    return nil
end

local function ask_user_to_pick(results, on_pick, on_create_new)
    local menu
    local items = {}
    for _, r in ipairs(results) do
        table.insert(items, {
            text = r.title .. " — " .. r.author,
            callback = function()
                UIManager:close(menu)
                on_pick(r.bookId)
            end,
        })
    end
    table.insert(items, {
        text = _("None of these — add as a new book"),
        callback = function()
            UIManager:close(menu)
            on_create_new()
        end,
    })
    menu = Menu:new{
        title = _("Which book is this?"),
        item_table = items,
        width = require("device").screen:getWidth() * 0.8,
    }
    UIManager:show(menu)
end

-- ui: the ReaderUI instance. callback(book_id_or_nil)
function BookIdentity.resolve(ui, callback)
    local doc_settings = ui.doc_settings
    local cached = doc_settings and doc_settings:readSetting("folizen_book_id")
    if cached then
        callback(cached)
        return
    end

    local key = device_key_for(ui.document)
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

    if key then
        local ok, body = Api.findByDeviceKey(key)
        if ok and body and body.results and body.results[1] then
            store_and_return(body.results[1].bookId)
            return
        end
    end

    local ok, body = Api.searchBooks(title)
    if ok and body and body.results and #body.results > 0 then
        ask_user_to_pick(
            body.results,
            function(picked_book_id)
                local link_ok, link_body = Api.linkBook({ bookId = picked_book_id, deviceBookKey = key })
                store_and_return(link_ok and link_body and link_body.bookId or nil)
            end,
            function()
                local link_ok, link_body = Api.linkBook({ deviceBookKey = key, title = title, author = author })
                store_and_return(link_ok and link_body and link_body.bookId or nil)
            end
        )
        return
    end

    local link_ok, link_body = Api.linkBook({ deviceBookKey = key, title = title, author = author })
    if link_ok and link_body then
        store_and_return(link_body.bookId)
    else
        UIManager:show(InfoMessage:new{ text = _("Folizen: couldn't resolve this book — check your connection.") })
        callback(nil)
    end
end

return BookIdentity
