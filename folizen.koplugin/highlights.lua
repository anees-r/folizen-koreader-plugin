--[[
KOReader stores highlights/notes ("annotations") in each book's sidecar
settings file, keyed by the document's own internal ids — the exact
storage shape has changed across KOReader versions (older: per-page
`highlight` table; 2023.04+: unified `annotations` array). This module
normalizes either shape into a flat list of:

    { devicePositionKey, passageText, note, page, chapter }

`devicePositionKey` is whatever stable position identifier KOReader
already uses internally (annotation "pos0", or the legacy per-page
index) — it does not need to mean anything to the server, only to stay
consistent between syncs so the server can diff additions/edits/removals
(requirements.md section 5.4).
]]

local Highlights = {}

local function safe_str(v)
    if v == nil then return nil end
    return tostring(v)
end

--- Newer KOReader: doc_settings:readSetting("annotations") -> array of
--- { text=, note=, pos0=, pos1=, pageno=, chapter=, drawer= }
local function from_annotations(annotations)
    local out = {}
    for _, a in ipairs(annotations or {}) do
        if a.text and a.text ~= "" then
            table.insert(out, {
                devicePositionKey = safe_str(a.pos0) or safe_str(a.datetime),
                passageText = a.text,
                note = a.note,
                page = a.pageno,
                chapter = a.chapter,
            })
        end
    end
    return out
end

--- Older KOReader: doc_settings:readSetting("highlight") -> map of
--- page_number -> array of { text=, note=, pos0=, pos1=, datetime= }
local function from_legacy_highlight_table(highlight_table)
    local out = {}
    for page, entries in pairs(highlight_table or {}) do
        for _, h in ipairs(entries) do
            if h.text and h.text ~= "" then
                table.insert(out, {
                    devicePositionKey = safe_str(h.pos0) or (safe_str(page) .. ":" .. safe_str(h.datetime)),
                    passageText = h.text,
                    note = h.note,
                    page = tonumber(page),
                    chapter = nil,
                })
            end
        end
    end
    return out
end

-- doc_settings is the LuaSettings/DocSettings object for the currently
-- open document (self.ui.doc_settings inside a ReaderUI-scoped plugin).
function Highlights.extract(doc_settings)
    if not doc_settings then return {} end

    local annotations = doc_settings:readSetting("annotations")
    if annotations and #annotations > 0 then
        return from_annotations(annotations)
    end

    local legacy = doc_settings:readSetting("highlight")
    if legacy then
        return from_legacy_highlight_table(legacy)
    end

    return {}
end

return Highlights
