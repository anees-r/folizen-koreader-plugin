--[[
Thin JSON/HTTP client for the Folizen server API (see requirements.md
section 9 and src/app/api/plugin/** in the web app repo).

Modeled on the request pattern used by other KOReader network plugins
(e.g. opds.koplugin, newsdownloader.koplugin): socket.http/ssl.https +
ltn12, with socketutil timeouts so a bad connection can't hang the UI.

NOTE: written against KOReader's plugin APIs from documentation/reference
knowledge; it has not been run against a live KOReader install in this
environment (no device/emulator available here). Function names here
(socketutil timeouts, json require) are correct as of recent KOReader
releases, but double-check against your installed KOReader version's
other bundled plugins if something doesn't resolve.
]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")

local FolizenSettings = require("settings")

local Api = {}

local TIMEOUT = 15
local BLOCK_TIMEOUT = 20

local function base_url()
    local url = FolizenSettings.get("server_url") or ""
    return (url:gsub("/+$", "")) -- strip trailing slash
end

-- Performs a JSON request against `path` (e.g. "/api/plugin/sync/progress").
-- Returns ok (boolean), decoded_body_or_nil, status_code_or_error_string.
local function request(method, path, body, opts)
    opts = opts or {}
    local url = base_url() .. path
    local client = url:match("^https") and https or http

    local request_body = nil
    local headers = { ["Accept"] = "application/json" }

    if body ~= nil then
        request_body = json.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#request_body)
    end

    if not opts.skip_auth then
        local token = FolizenSettings.get("refresh_token")
        if not token then
            return false, nil, "not_logged_in"
        end
        headers["Authorization"] = "Bearer " .. token
    end

    local response_chunks = {}
    socketutil:set_timeout(TIMEOUT, BLOCK_TIMEOUT)
    local ok, status_or_err = client.request({
        url = url,
        method = method,
        headers = headers,
        source = request_body and ltn12.source.string(request_body) or nil,
        sink = ltn12.sink.table(response_chunks),
    })
    socketutil:reset_timeout()

    if not ok then
        return false, nil, tostring(status_or_err)
    end

    local raw = table.concat(response_chunks)
    local decoded = nil
    if raw ~= "" then
        local parse_ok, parsed = pcall(json.decode, raw)
        if parse_ok then decoded = parsed end
    end

    local status = status_or_err
    if type(status) == "number" and status >= 200 and status < 300 then
        return true, decoded, status
    end

    local status_code = type(status) == "number" and status or nil

    -- 401 means the token is gone server-side — either it was revoked, or
    -- (since plugin_sessions cascade-deletes with the user) the account
    -- itself was deleted. Either way, the device is no longer signed in;
    -- clear local credentials immediately so the menu reflects that
    -- instead of silently retrying a dead token forever.
    if status_code == 401 and not opts.skip_auth then
        FolizenSettings.clearSession()
    end

    local message = (decoded and decoded.error) or ("HTTP " .. tostring(status))
    return false, decoded, message, status_code
end

--- Auth ---

function Api.login(identifier, password, device_label)
    return request("POST", "/api/plugin/auth/login", {
        identifier = identifier,
        password = password,
        deviceLabel = device_label,
    }, { skip_auth = true })
end

function Api.logout()
    return request("POST", "/api/plugin/auth/logout", {})
end

--- Settings ---

function Api.getSettings()
    return request("GET", "/api/plugin/settings")
end

function Api.patchSettings(prefs)
    return request("PATCH", "/api/plugin/settings", prefs)
end

--- Book identity ---

function Api.searchBooks(query)
    return request("GET", "/api/plugin/books/search?q=" .. Api.urlEncode(query))
end

function Api.findByDeviceKey(device_book_key)
    return request("GET", "/api/plugin/books/search?deviceBookKey=" .. Api.urlEncode(device_book_key))
end

function Api.linkBook(payload)
    -- payload: { bookId=, deviceBookKey=, title=, author= }
    return request("POST", "/api/plugin/books/link", payload)
end

--- Sync ---

function Api.syncProgress(book_id, page, total_pages, percent)
    return request("POST", "/api/plugin/sync/progress", {
        bookId = book_id,
        page = page,
        totalPages = total_pages,
        percent = percent,
    })
end

-- Batched per-sync-event push (section 7.1): progress, device-set status,
-- highlights, and vocabulary in a single HTTPS request, instead of one
-- request per data type. payload: { book_id=, page=, total_pages=, percent=,
-- shelf=, rating=, review=, finished_at=, highlights=, words= } — any of the
-- status/highlights/words fields may be nil/empty and are skipped
-- server-side.
function Api.sync(payload)
    return request("POST", "/api/plugin/sync", {
        bookId = payload.book_id,
        page = payload.page,
        totalPages = payload.total_pages,
        percent = payload.percent,
        shelf = payload.shelf,
        rating = payload.rating,
        review = payload.review,
        finishedAt = payload.finished_at,
        highlights = payload.highlights,
        words = payload.words,
    })
end

function Api.syncHighlights(book_id, highlights_list)
    return request("POST", "/api/plugin/sync/highlights", {
        bookId = book_id,
        highlights = highlights_list,
    })
end

function Api.syncVocabulary(book_id, words)
    return request("POST", "/api/plugin/sync/vocabulary", {
        bookId = book_id,
        words = words,
    })
end

function Api.syncStatus(book_id, shelf, rating, review, finished_at)
    return request("POST", "/api/plugin/sync/status", {
        bookId = book_id,
        shelf = shelf,
        rating = rating,
        review = review,
        finishedAt = finished_at,
    })
end

-- days: { {date="YYYY-MM-DD", pagesRead=, durationSeconds=,
--          books={ {title=, durationSeconds=, pagesRead=}, ... }}, ... }
function Api.syncReadingDays(days)
    return request("POST", "/api/plugin/sync/reading-days", { days = days })
end

--- Download queue ---

function Api.getQueue()
    return request("GET", "/api/plugin/queue")
end

function Api.completeQueueItem(book_id)
    return request("POST", "/api/plugin/queue/" .. tostring(book_id) .. "/complete", {})
end

--- utils ---

function Api.urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

return Api
