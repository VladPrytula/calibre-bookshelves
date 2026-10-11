-- Pure, deterministic planning. No filesystem, KOReader or network dependencies.
local M = {}
local statuses = {unmanaged=true, ["To Read"]=true, Reading=true, ["On Hold"]=true, Finished=true}
local flags = {unmanaged=true, yes=true, no=true}
local function fail(message) error("Calibre Bookshelves: " .. message, 0) end
local function text(value, limit)
    return type(value) == "string" and #value > 0 and #value <= limit and not value:find("[%z\1-\31]")
end
local function uuid(value)
    return type(value) == "string" and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end
local function array(value, max)
    if type(value) ~= "table" or #value > max then return false end
    local count=0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then return false end
        count=count+1
    end
    return count == #value
end
function M.filename(file)
    return text(file, 240) and not file:find("[/\\]") and file:sub(1,1) ~= "."
        and (file:lower():match("%.epub$") or file:lower():match("%.pdf$")) ~= nil
end
function M.validate(cat)
    if type(cat) ~= "table" or cat.schema ~= 1 or not uuid(cat.library_id)
        or not text(cat.revision, 64) or #cat.revision ~= 64 or not cat.revision:match("^%x+$")
        or not array(cat.books, 10000) then fail("Invalid catalogue or unsupported schema.") end
    local ids, files, shelves = {}, {}, {}
    for _, b in ipairs(cat.books) do
        if type(b) ~= "table" or not uuid(b.uuid) or ids[b.uuid] or not M.filename(b.file)
            or files[b.file:lower()] or type(b.bytes) ~= "number" or b.bytes <= 0 or b.bytes % 1 ~= 0
            or not flags[b.favourite] or not statuses[b.status] or not array(b.shelves, 100) then
            fail("Invalid or duplicate book entry.")
        end
        ids[b.uuid], files[b.file:lower()] = true, true
        local seen = {}
        for _, name in ipairs(b.shelves) do
            if not text(name, 160) or name:match("^%s") or name:match("%s$")
                or name:lower() == "favorites" or name:lower() == "to be read" or seen[name] then
                fail("Invalid, duplicate or reserved shelf name.")
            end
            if shelves[name:lower()] and shelves[name:lower()] ~= name then fail("Shelf names differ only in case.") end
            shelves[name:lower()], seen[name] = name, true
        end
    end
    return true
end
function M.plan(cat, state, snapshot, available, force_flags)
    M.validate(cat)
    state = state or {books={}}
    if state.library_id and state.library_id ~= cat.library_id then fail("Different Calibre library. Restore the matching ledger or review explicitly.") end
    if type(state.books) ~= "table" then fail("Invalid local import ledger.") end
    local p = {ops={}, next_state={schema=1,library_id=cat.library_id,revision=cat.revision,books={}}, warnings={}}
    local function op(kind, shelf, file, value) p.ops[#p.ops+1]={kind=kind,shelf=shelf,file=file,value=value} end
    local desired, known = {}, {}
    for _, prev in pairs(state.books) do
        if not M.filename(prev.file) then fail("Invalid filename in local ledger.") end
        known[prev.file]=true
    end
    for _, b in ipairs(cat.books) do
        if available[b.file] ~= b.bytes then fail("Waiting for complete book transfer: " .. b.file) end
        known[b.file]=true
        for _, name in ipairs(b.shelves) do
            desired[name]=desired[name] or {}
            desired[name][b.file]=true
        end
        local prev = state.books[b.uuid] or {}
        -- An unset field relinquishes control; it does not clear device data.
        if b.favourite ~= "unmanaged" and (force_flags or prev.favourite ~= b.favourite or prev.file ~= b.file)
            and (snapshot.favourites[b.file] == true) ~= (b.favourite == "yes") then
            op("favourite", nil, b.file, b.favourite == "yes")
        end
        if b.status ~= "unmanaged" and (force_flags or prev.status ~= b.status or prev.file ~= b.file) then
            op("status", nil, b.file, b.status)
        end
        p.next_state.books[b.uuid]={file=b.file,favourite=b.favourite,status=b.status}
    end
    -- Preflight all collisions before producing executable mutations.
    for name in pairs(desired) do
        for local_name, c in pairs(snapshot.collections) do
            if local_name:lower() == name:lower() and (local_name ~= name or c.owner ~= cat.library_id) then
                fail("Collection name already exists outside this Calibre library: " .. local_name .. ". Rename that local collection first.")
            end
        end
    end
    local names={}
    for name in pairs(desired) do names[name]=true end
    for name,c in pairs(snapshot.collections) do if c.owner == cat.library_id then names[name]=true end end
    local sorted={}; for name in pairs(names) do sorted[#sorted+1]=name end; table.sort(sorted)
    for _,name in ipairs(sorted) do
        local want, current = desired[name] or {}, snapshot.collections[name]
        if not current then op("create", name); current={files={}} end
        local remaining={}
        for file in pairs(current.files) do
            if known[file] and not want[file] then op("remove",name,file)
            else remaining[file]=true end
        end
        for file in pairs(want) do
            if not current.files[file] then op("add",name,file) end
            remaining[file]=true
        end
        if not desired[name] then
            if not next(remaining) then op("delete_empty",name)
            else p.warnings[#p.warnings+1]="Kept retired shelf containing local books: " .. name end
        end
    end
    -- Creation must precede additions; status/favourite actions have no dependency
    -- on managed shelves. Operations are deterministic enough for repeat planning.
    return p
end
return M
