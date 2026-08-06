--[[
KOReader's built-in "Vocabulary Builder" plugin (vocabbuilder.koplugin)
keeps its own sqlite3 database of words the reader has looked up, at
<settings dir>/vocabulary_builder.sqlite3, with (roughly) a `vocabulary`
table containing word / book_title / create_time columns. Schema details
have shifted across KOReader releases, so this reads defensively and
simply returns an empty list if the table/columns aren't there — vocab
sync is a nice-to-have, not something that should break page-turn sync.

Definitions and pronunciation are NOT resolved here — per
requirements.md section 4.13, that lookup happens server-side, lazily,
the first time a word is displayed in the Folizen web app's Vocabulary
view. The plugin only ever ships the bare word list up.
]]

local DataStorage = require("datastorage")
local logger = require("logger")

local Vocabulary = {}

local function open_db()
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then
        logger.warn("Folizen: lua-ljsqlite3 unavailable, skipping vocabulary sync")
        return nil
    end
    local path = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
    local open_ok, conn = pcall(SQ3.open, path)
    if not open_ok then return nil end
    return conn
end

-- Returns a de-duplicated list of lowercase words looked up while reading
-- `book_title` (matched loosely — vocabbuilder doesn't key by our book id).
function Vocabulary.wordsForBook(book_title)
    local conn = open_db()
    if not conn then return {} end

    local words = {}
    local ok, stmt = pcall(function()
        return conn:prepare([[
            SELECT DISTINCT word FROM vocabulary
            WHERE book_title = ?
        ]])
    end)

    if ok and stmt then
        local rows_ok, rows = pcall(function()
            stmt:bind(1, book_title)
            return stmt:resultset()
        end)
        if rows_ok and rows and rows[1] then
            for _, w in ipairs(rows[1]) do
                table.insert(words, w)
            end
        end
        pcall(function() stmt:close() end)
    end

    pcall(function() conn:close() end)
    return words
end

return Vocabulary
