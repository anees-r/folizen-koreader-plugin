--[[
Two distinct data sources, both core KOReader features (not part of any
optional plugin, so these always exist once a book has been touched):

1. Per-document "summary" — set by KOReader's own Book Status dialog
   (the one that pops up when you finish a book, or via the status menu).
   Stored in the book's own sidecar settings under the "summary" key:
       { status = "reading" | "complete" | "abandoned" | "",
         rating = 0-5 (some KOReader versions store 0-10 half-stars),
         note = "free text review",
         modified = "YYYY-MM-DD" }
   This is what was missing before: the plugin never read this table at
   all, so rating/review/finish-date never made it into a sync call.

2. KOReader's global reading history (require("readhistory")), a list of
   every file ever opened with {file=, time=}. Combined with
   require("docsettings").open(file) — which can open ANY book's sidecar
   by path, not just the currently-active one — this lets us walk every
   book ever read and pull its summary, even books not opened on this
   device since Folizen was installed.
]]

local DocSettings = require("docsettings")
local logger = require("logger")
local Highlights = require("highlights")

local BookHistory = {}

-- Normalizes whatever rating scale this KOReader version used (plain 0-5,
-- or 0-10 half-star) down to our 1-5 integer scale. Returns nil for "no
-- rating set" rather than 0, since 0 isn't a valid Folizen rating.
local function normalize_rating(raw)
    if type(raw) ~= "number" or raw <= 0 then return nil end
    local r = raw > 5 and (raw / 2) or raw
    r = math.floor(r + 0.5)
    if r < 1 then return nil end
    if r > 5 then r = 5 end
    return r
end

local function status_to_shelf(status)
    if status == "complete" then return "finished" end
    if status == "abandoned" then return "dropped" end
    return nil -- "reading"/"" — leave shelf alone, progress sync already handles this
end

-- Reads the summary for a single already-open document (ui.doc_settings).
-- Returns nil if nothing's been set, or { shelf, rating, review, finishedAt }.
function BookHistory.summaryFor(doc_settings)
    if not doc_settings then return nil end
    local ok, summary = pcall(function() return doc_settings:readSetting("summary") end)
    if not ok or not summary then return nil end

    local shelf = status_to_shelf(summary.status)
    local rating = normalize_rating(summary.rating)
    local review = (summary.note and summary.note ~= "") and summary.note or nil
    local finishedAt = (shelf == "finished" or shelf == "dropped") and summary.modified or nil

    if not shelf and not rating and not review then return nil end
    return { shelf = shelf, rating = rating, review = review, finishedAt = finishedAt }
end

-- Walks every book KOReader has ever opened (its own history list) and
-- returns { title, author, deviceBookKey, shelf, rating, review,
-- finishedAt, highlights } for each one that has a readable sidecar file
-- AND has something worth syncing (a status, or at least one highlight).
-- Best-effort throughout — a single unreadable/missing file just gets
-- skipped, never aborts the whole scan.
function BookHistory.collectAll()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or not ReadHistory.hist then
        logger.warn("Folizen: readhistory unavailable, skipping history import")
        return {}
    end

    local results = {}
    for _, entry in ipairs(ReadHistory.hist) do
        local file = entry.file
        if file then
            local fh = io.open(file, "rb")
            if fh then
                fh:close()
                local open_ok, docinfo = pcall(function() return DocSettings:open(file) end)
                if open_ok and docinfo then
                    local summary = docinfo:readSetting("summary") or {}
                    local doc_props = docinfo:readSetting("doc_props") or {}
                    local md5 = docinfo:readSetting("partial_md5_checksum")

                    local shelf = status_to_shelf(summary.status)
                    local rating = normalize_rating(summary.rating)
                    local review = (summary.note and summary.note ~= "") and summary.note or nil
                    local finishedAt = (shelf == "finished" or shelf == "dropped") and summary.modified or nil

                    local highlight_ok, highlight_list = pcall(function() return Highlights.extract(docinfo) end)
                    if not highlight_ok then highlight_list = {} end

                    -- Worth syncing if there's a status/rating/review OR
                    -- at least one highlight — this was the gap that meant
                    -- "Sync reading history" imported status/vocab but
                    -- silently skipped highlights & notes entirely.
                    if shelf or rating or review or #highlight_list > 0 then
                        local title = doc_props.title
                        if not title or title == "" then
                            title = file:match("([^/\\]+)%.%w+$") or file
                        end
                        table.insert(results, {
                            title = title,
                            author = doc_props.authors or doc_props.author or "Unknown author",
                            deviceBookKey = md5,
                            shelf = shelf,
                            rating = rating,
                            review = review,
                            finishedAt = finishedAt,
                            highlights = highlight_list,
                        })
                    end
                end
            end
        end
    end
    return results
end

return BookHistory
