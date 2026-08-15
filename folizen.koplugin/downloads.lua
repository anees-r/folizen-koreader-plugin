local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Menu = require("ui/widget/menu")
local CenterContainer = require("ui/widget/container/centercontainer")
local PathChooser = require("ui/widget/pathchooser")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("gettext")

local Api = require("api")
local Net = require("network")
local FolizenSettings = require("settings")

local Downloads = {}

local function guess_filename(title)
    local safe = title:gsub("[^%w%s%-%_]", ""):gsub("%s+", "_")
    return (safe ~= "" and safe or "book") .. ".epub"
end

-- LuaSocket reports a failed connection as (nil, error_string) rather than
-- a numeric status — turns the common cases into a message that actually
-- tells the reader what to do, instead of a raw socket error string.
local function describe_network_error(err)
    local s = tostring(err or ""):lower()
    if s:find("timeout") then
        return _("Connection timed out — check your Wi-Fi and try again.")
    end
    if s:find("refused") or s:find("no route") or s:find("could not resolve") or s:find("host") then
        return _("Couldn't reach the download host — check your connection and the link.")
    end
    return _("Network error: ") .. tostring(err)
end

-- Distinguishes every failure mode section 5.6 calls out by name: network/
-- timeout, an HTML page in place of the file (host interstitials — e.g.
-- Google Drive's "can't scan this file for viruses" page, which returns
-- HTTP 200 with an HTML body, not a file), permissions/access errors,
-- not-found, and local disk-write failure. Returns (success, message,
-- received_bytes) — on any failure, a partially-written file is removed
-- rather than left behind masquerading as the real book.
local function download_to(url, dest_path, on_progress, on_done)
    local client = url:match("^https") and https or http
    local file, open_err = io.open(dest_path, "wb")
    if not file then
        on_done(false, _("Couldn't write to that folder: ") .. tostring(open_err))
        return
    end

    local received = 0
    local last_reported = 0
    local REPORT_EVERY_BYTES = 200 * 1024 -- ~200 KB, avoids flooding the UI with updates

    local sink = function(chunk, err)
        if err then return nil, err end
        if chunk == nil then return true end -- ltn12 end-of-stream marker
        file:write(chunk)
        received = received + #chunk
        if on_progress and (received - last_reported) >= REPORT_EVERY_BYTES then
            last_reported = received
            on_progress(received)
        end
        return true
    end

    socketutil:set_timeout(15, 120) -- generous block timeout; a few MB over a slow connection can take a while
    local ok, code, headers = client.request({
        url = url,
        method = "GET",
        sink = sink,
    })
    socketutil:reset_timeout()
    file:close()

    if not ok then
        os.remove(dest_path)
        on_done(false, describe_network_error(code))
        return
    end

    if type(code) == "number" and code >= 200 and code < 300 then
        local content_type = (headers and (headers["content-type"] or headers["Content-Type"])) or ""
        if content_type:lower():find("text/html", 1, true) then
            os.remove(dest_path)
            on_done(false, _("The link returned a webpage instead of the book file — the host likely needs manual confirmation first (common with large-file warnings). Try opening the link in a browser to download it, or update the link on the web app."))
            return
        end
        on_done(true, nil, received)
        return
    end

    os.remove(dest_path)
    if code == 401 or code == 403 then
        on_done(false, _("The host denied access (") .. tostring(code) .. _(") — the link may require sign-in or have expired."))
    elseif code == 404 then
        on_done(false, _("File not found at that link (404) — double-check the link on the web app."))
    else
        on_done(false, _("The host returned an error (") .. tostring(code) .. ").")
    end
end

function Downloads.show()
    Net.withConnection(function()
        local ok, body = Api.getQueue()
        if not ok then
            if not FolizenSettings.isLoggedIn() then
                UIManager:show(InfoMessage:new{ text = _("Your Folizen session ended — please sign in again from the Folizen menu.") })
            else
                UIManager:show(InfoMessage:new{ text = _("Folizen: couldn't load your download queue.") })
            end
            return
        end

        local queue = (body and body.queue) or {}
        if #queue == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing queued from the web app right now.") })
            return
        end

        local menu, popup
        local items = {}
        for _idx, item in ipairs(queue) do
            table.insert(items, {
                text = item.title .. " — " .. item.author,
                callback = function()
                    UIManager:close(popup)
                    if not item.externalLink or item.externalLink == "" then
                        UIManager:show(InfoMessage:new{ text = _("No download link set for this book yet — add one on the web app.") })
                        return
                    end
                    UIManager:show(PathChooser:new{
                        title = _("Choose a folder to save into"),
                        path = Device.home_dir or "/",
                        onConfirm = function(folder)
                            local dest = folder .. "/" .. guess_filename(item.title)
                            local info = InfoMessage:new{ text = _("Downloading \"") .. item.title .. _("\"…") }
                            UIManager:show(info)

                            local function update_progress(received_bytes)
                                UIManager:close(info)
                                local kb = math.floor(received_bytes / 1024)
                                info = InfoMessage:new{
                                    text = _("Downloading \"") .. item.title .. _("\"… ") .. kb .. _(" KB so far"),
                                }
                                UIManager:show(info)
                                -- KOReader's HTTP call blocks the event loop, so without
                                -- forcing a repaint here these updates may only actually
                                -- become visible once the whole download finishes, on
                                -- some KOReader versions/devices.
                                pcall(function() UIManager:forceRePaint() end)
                            end

                            download_to(item.externalLink, dest, update_progress, function(success, message, received_bytes)
                                UIManager:close(info)
                                if success then
                                    Api.completeQueueItem(item.bookId)
                                    local kb = received_bytes and math.floor(received_bytes / 1024) or nil
                                    UIManager:show(InfoMessage:new{
                                        text = _("Downloaded to ") .. dest .. (kb and (" (" .. kb .. " KB)") or ""),
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = message .. _(" The book stays queued — try again later."),
                                    })
                                end
                            end)
                        end,
                    })
                end,
            })
        end

        -- Menu always anchors itself to (0, 0) regardless of width/height —
        -- it has no self-centering logic at all. Wrapping it in a
        -- CenterContainer sized to the full screen is the idiom KOReader's
        -- own code uses to center a popup Menu; close_callback re-routes
        -- the menu's own close button (and Api's on-select close below) to
        -- close that outer wrapper instead of leaving it stuck on screen.
        menu = Menu:new{
            title = _("Queued from Folizen"),
            item_table = items,
            width = Device.screen:getWidth() * 0.8,
            height = Device.screen:getHeight() * 0.8,
            close_callback = function() UIManager:close(popup) end,
        }
        popup = CenterContainer:new{
            dimen = Device.screen:getSize(),
            menu,
        }
        UIManager:show(popup)
    end, { manual = true })
end

return Downloads
