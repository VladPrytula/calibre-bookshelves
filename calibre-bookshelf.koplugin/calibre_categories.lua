-- Read-only navigation model. Collection reconciliation stays in the importer.
local Core = require("calibre_bookshelf_core")
local M = {}
local function fail(s) error("Calibre categories: " .. s, 0) end
local function text(s, limit, empty)
    return type(s)=="string" and (empty or #s>0) and #s<=limit and not s:find("[%z\1-\31\127]")
end
local function uuid(s)
    return type(s)=="string" and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end
local function array(t, limit)
    if type(t)~="table" or #t>limit then return false end
    local n=0
    for k in pairs(t) do if type(k)~="number" or k<1 or k>#t or k%1~=0 then return false end; n=n+1 end
    return n==#t
end
local function add(list, book)
    if not list.seen[book.id] then list.seen[book.id]=true; list[#list+1]=book end
end
local function list() return {seen={}} end
-- Navigation versions differ only in their budget. Version 1 is the original
-- public contract; version 2 allows sixteen sub-shelves.
local LIMITS={[1]={nodes=14,roots=6,children=8},[2]={nodes=22,roots=6,children=16}}
local function shelf_key(shelves)
    local out={}; for _,s in ipairs(shelves) do out[#out+1]=s end
    table.sort(out); return table.concat(out,"\0")
end
local function sort_books(books)
    table.sort(books,function(a,b)
        local x,y=a.title:lower(),b.title:lower()
        return x==y and a.id<b.id or x<y
    end)
end

function M.build(cat, available)
    Core.validate(cat)
    available=available or {}
    local model={roots={},nodes={},by_path={},all=list(),unassigned=list(),legacy=list(),legacy_shelves={},flat=cat.navigation==nil}
    local nav=cat.navigation
    if not model.flat and type(nav)=="table" and type(nav.version)=="number" and nav.version%1==0 and nav.version>2 then
        -- A newer exporter: keep the saved shelf names browsable instead of guessing.
        model.flat=true; model.newer=nav.version
    end
    if not model.flat then
        local limits=type(nav)=="table" and LIMITS[nav.version]
        if not limits or not array(nav.nodes,limits.nodes) or #nav.nodes==0 then fail("Unsupported navigation metadata.") end
        local paths,roots,children={},0,0
        for _,n in ipairs(nav.nodes) do
            if type(n)~="table" or not text(n.id,80) or not n.id:match("^[a-z0-9][a-z0-9%-]*$")
                or model.nodes[n.id] or not text(n.name,160) or n.name:match("^%s") or n.name:match("%s$")
                or n.name:find("[,/]") or n.name:lower()=="favorites" or n.name:lower()=="to be read"
                or not text(n.path,160) or paths[n.path:lower()]
                or (n.parent~=nil and (not text(n.parent,80) or n.parent==n.id)) then fail("Invalid category definition.") end
            paths[n.path:lower()]=true
            local node={id=n.id,name=n.name,path=n.path,parent=n.parent,children={},books=list(),direct=list()}
            model.nodes[n.id]=node; model.by_path[n.path]=node
        end
        for _,n in ipairs(nav.nodes) do
            local node=model.nodes[n.id]
            if node.parent then
                local parent=model.nodes[node.parent]
                if not parent or parent.parent or node.path~=parent.name.." / "..node.name then fail("Invalid category hierarchy.") end
                parent.children[#parent.children+1]=node; children=children+1
            else
                if node.path~=node.name then fail("Invalid root category path.") end
                model.roots[#model.roots+1]=node; roots=roots+1
            end
        end
        if roots>limits.roots or children>limits.children then fail("Category budget exceeded.") end
    end
    local by_id={}
    for _,r in ipairs(cat.books) do
        local id,title,authors,format=r.uuid,r.file:gsub("%.[^.]+$",""),"",r.file:match("%.([^.]+)$"):lower()
        if not model.flat then
            if not uuid(r.book_uuid) or not text(r.title,2048) or not text(r.authors,2048,true)
                or (r.format~="epub" and r.format~="pdf") or r.format~=format then fail("Invalid book display metadata.") end
            id,title,authors=r.book_uuid,r.title,r.authors
        end
        local book=by_id[id]
        if not book then
            book={id=id,title=title,authors=authors,shelves=r.shelves,renditions={},formats={},ready=false}
            by_id[id]=book; add(model.all,book)
        elseif book.title~=title or book.authors~=authors or shelf_key(book.shelves)~=shelf_key(r.shelves) then
            fail("Renditions disagree about book metadata.")
        end
        if book.formats[format] then fail("Duplicate rendition for one book.") end
        local rendition={file=r.file,format=format,bytes=r.bytes,ready=available[r.file]==r.bytes}
        book.formats[format]=true; book.renditions[#book.renditions+1]=rendition
        book.ready=book.ready or rendition.ready
    end
    for _,book in ipairs(model.all) do
        table.sort(book.renditions,function(a,b)return a.format<b.format end)
        if #book.shelves==0 then add(model.unassigned,book) end
        for _,path in ipairs(book.shelves) do
            local node=model.by_path[path]
            if node then
                add(node.direct,book); add(node.books,book)
                if node.parent then add(model.nodes[node.parent].books,book) end
            else
                add(model.legacy,book)
                model.legacy_shelves[path]=model.legacy_shelves[path] or list()
                add(model.legacy_shelves[path],book)
            end
        end
    end
    sort_books(model.all); sort_books(model.unassigned); sort_books(model.legacy)
    for _,n in pairs(model.nodes) do sort_books(n.books); sort_books(n.direct) end
    model.legacy_names={}
    for name,books in pairs(model.legacy_shelves) do sort_books(books); model.legacy_names[#model.legacy_names+1]=name end
    table.sort(model.legacy_names)
    return model
end

function M.count(books)
    local waiting=0
    for _,b in ipairs(books) do if not b.ready then waiting=waiting+1 end end
    return #books,waiting
end
return M
