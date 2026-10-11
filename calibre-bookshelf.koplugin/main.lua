local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local DataStorage = require("datastorage")
local ReadCollection = require("readcollection")
local DocSettings = require("docsettings")
local BookList = require("ui/widget/booklist")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local ffiutil = require("ffi/util")
local logger = require("logger")
local Core = require("calibre_bookshelf_core")

local Plugin = WidgetContainer:extend{name="calibre_bookshelf",is_doc_only=false}
local CATALOGUE = "/.calibre-bookshelves.json"
local OWNER = "calibre_bookshelf_owner"
local BASE = DataStorage:getSettingsDir() .. "/calibre_bookshelf"
local LEDGER = BASE .. "/state.json"
local function read(path, limit)
    local file=io.open(path,"rb"); if not file then return nil end
    local data=file:read((limit or 8*1024*1024)+1); file:close()
    if #data > (limit or 8*1024*1024) then error("File exceeds import size limit: " .. path) end
    return data
end
local function write(path,data)
    local file=assert(io.open(path .. ".tmp","wb"))
    assert(file:write(data)); assert(file:close()); assert(os.rename(path .. ".tmp",path))
end
local function message(text) UIManager:show(InfoMessage:new{text=text}) end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function copy(value)
    if type(value)~="table" then return value end
    local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
function Plugin:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    util.makePath(BASE)
    self.auto = G_reader_settings:nilOrTrue("calibre_bookshelf_auto")
    self.closed = false
    self.timer = function()
        if self.closed then return end
        if self.auto and not self.failed and not self.ui.document then self:import(false) end
        if not self.closed then UIManager:scheduleIn(60,self.timer) end
    end
    -- Deferred until other plugins (including ZenOS) have initialized.
    UIManager:scheduleIn(4,self.timer)
end
function Plugin:onCloseWidget()
    if self.category_menu then self.category_menu:onCloseAllMenus() end
    self.closed=true
    UIManager:unschedule(self.timer)
end
function Plugin:onDispatcherRegisterActions()
    require("dispatcher"):registerAction("calibre_categories", {
        category="none",event="BrowseCalibreCategories",title="Calibre categories",filemanager=true,
    })
end
function Plugin:onBrowseCalibreCategories()
    local ok,err=pcall(function() self:browseCategories() end)
    if not ok then message(tostring(err)) end
    return true
end
function Plugin:browseCategories()
    local ReaderUI=require("apps/reader/readerui")
    if self.ui.document or ReaderUI.instance then error("Return to Library before browsing Calibre categories.",0) end
    if self.category_menu then return end
    local root=self:getRoot()
    local raw=assert(read(root..CATALOGUE))
    local cat=JSON.decode(raw)
    Core.validate(cat)
    local available={}
    for _,b in ipairs(cat.books) do
        local path=root.."/"..b.file
        if ffiutil.realpath(path)==path and lfs.attributes(path,"mode")=="file" then
            available[b.file]=lfs.attributes(path,"size")
        end
    end
    local model=require("calibre_categories").build(cat,available)
    local function bookPath(rendition)
        if self:getRoot()~=root or read(root..CATALOGUE)~=raw then
            error("The catalogue changed. Close Categories and open it again.",0)
        end
        local path=root.."/"..rendition.file
        if ffiutil.realpath(path)~=path or lfs.attributes(path,"mode")~="file"
            or lfs.attributes(path,"size")~=rendition.bytes then
            error("Waiting for complete book transfer: "..rendition.file,0)
        end
        return path
    end
    local function open(rendition)
        local opened,err=pcall(function()
            local path=bookPath(rendition)
            if self.category_menu then self.category_menu:onCloseAllMenus() end
            UIManager:nextTick(function() ReaderUI:showReader(path) end)
        end)
        if not opened then message(tostring(err)) end
    end
    local function cover(rendition)
        return require("calibre_book_grid").cover(bookPath(rendition))
    end
    self.category_menu=require("calibre_categories_ui").show(model,open,function()self.category_menu=nil end,cover)
end
function Plugin:stopPlugin() self:onCloseWidget(); return true end
function Plugin:onSuspend() UIManager:unschedule(self.timer) end
function Plugin:onResume()
    if not self.closed then UIManager:unschedule(self.timer); UIManager:scheduleIn(4,self.timer) end
end
function Plugin:getRoot()
    local configured = G_reader_settings:readSetting("calibre_bookshelf_root")
    local candidates = configured and {configured} or {
        G_reader_settings:readSetting("home_dir") or "",
        "/mnt/us/Books", "/mnt/base-us/KindleLibrary", "/mnt/us/KindleLibrary",
    }
    for _,path in ipairs(candidates) do
        local root=path~="" and ffiutil.realpath(path)
        if root and lfs.attributes(root .. CATALOGUE,"mode")=="file" then return root end
    end
    error("Bookshelf catalogue not found. Wait for Syncthing, then set the synced book folder in this menu.",0)
end
function Plugin:zenTBR()
    -- Use only an already-loaded ZenOS adapter, never load arbitrary common modules.
    local api=package.loaded["common/tbr_index"]
    if type(api)=="table" and type(api.setExplicit)=="function" and type(api.isExplicit)=="function" then return api end
end
function Plugin:takeBackup(plan,paths)
    local stamp=os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(math.floor(os.clock()*1000000))
    local dir=BASE .. "/backups/" .. stamp
    util.makePath(dir)
    local index={schema=1,entries={}}
    local seen={}
    local function save(path)
        if not path or seen[path] then return end
        seen[path]=true
        local data=read(path,32*1024*1024)
        local entry={target=path,existed=data~=nil}
        if data then entry.backup=tostring(#index.entries+1) .. ".bin"; write(dir.."/"..entry.backup,data) end
        index.entries[#index.entries+1]=entry
    end
    local coll=DataStorage:getSettingsDir() .. "/collection.lua"
    save(coll); save(coll..".old"); save(LEDGER)
    for _,op in ipairs(plan.ops) do
        if op.kind=="status" then
            local path=paths[op.file]
            local source=DocSettings:findSidecarFile(path)
            save(source); if source then save(source..".old") end
            for _,loc in ipairs({"doc","dir"}) do
                local target=DocSettings:getSidecarDir(path,loc).."/"..DocSettings.getSidecarFilename(path)
                save(target); save(target..".old")
            end
            if G_reader_settings:readSetting("document_metadata_folder")=="hash" then
                local target=DocSettings:getSidecarDir(path,"hash").."/"..DocSettings.getSidecarFilename(path)
                save(target); save(target..".old")
            end
        end
    end
    write(dir.."/index.json",JSON.encode(index))
    return dir
end
function Plugin:applyStatus(path,status,tbr)
    local doc=DocSettings:open(path)
    local before=copy(doc.data)
    local summary=copy(doc:readSetting("summary") or {})
    local mapping={Reading="reading",["On Hold"]="abandoned",Finished="complete"}
    summary.status=mapping[status] -- To Read clears only explicit status, not location.
    summary.modified=os.date("%Y-%m-%d")
    doc:saveSetting("summary",summary)
    assert(doc:flush(),"Unable to save status sidecar")
    local verified=DocSettings:open(path)
    local expected=copy(before); expected.summary=summary
    if not equal(expected,verified.data) then error("Status verification failed; stop and restore the recorded backup.") end
    if tbr then
        tbr.setExplicit(path,status=="To Read")
        if tbr.isExplicit(path) ~= (status=="To Read") then error("ZenOS To Be Read verification failed") end
        if tbr.refreshPath then tbr.refreshPath(path,verified) end
    end
    BookList.setBookInfoCache(path,verified)
    local bs=package.loaded["common/book_status"]
    if type(bs)=="table" and bs.invalidate then bs.invalidate(path) end
end
function Plugin:run(force)
    if self.ui.document then error("Return to the Library before importing shelves. Open-book state is left untouched.",0) end
    local reader=package.loaded["apps/reader/readerui"]
    if reader and reader.instance then error("Close the book before importing shelves.",0) end
    local root=self:getRoot()
    local raw=assert(read(root..CATALOGUE))
    -- Periodic checks skip already-processed bytes; pending/error imports never set this.
    if not force and self.last_raw==raw and self.last_root==root then return self.last_result or "Already imported." end
    local cat=JSON.decode(raw); Core.validate(cat)
    local ledger_raw=read(LEDGER)
    local state=ledger_raw and JSON.decode(ledger_raw) or {books={}}
    if state.root and state.root~=root then
        error("The import ledger belongs to a different book folder. Restore/review it before changing roots.",0)
    end
    local paths,available={},{}
    for _,b in ipairs(cat.books) do
        local path=ffiutil.realpath(root.."/"..b.file)
        if path and path==root.."/"..b.file and lfs.attributes(path,"mode")=="file" then
            paths[b.file]=path; available[b.file]=lfs.attributes(path,"size")
        end
    end
    local snapshot={collections={},favourites={}}
    local favourites=ReadCollection.default_collection_name or "favorites"
    for name,entries in pairs(ReadCollection.coll) do
        local c={owner=(ReadCollection.coll_settings[name] or {})[OWNER],files={}}
        for path in pairs(entries) do
            local file=path:sub(1,#root+1)==root.."/" and path:sub(#root+2) or "@external:"..path
            c.files[file]=true
        end
        snapshot.collections[name]=c
        if name==favourites then snapshot.favourites=c.files end
    end
    local plan=Core.plan(cat,state,snapshot,available,force=="flags")
    local tbr=self:zenTBR()
    for _,op in ipairs(plan.ops) do
        if op.kind=="status" and not tbr then
            error("This ZenOS version has no loaded To Be Read adapter. Collections remain unchanged; update/check the plugin compatibility before importing this status.",0)
        end
    end
    local backup
    if #plan.ops>0 then backup=self:takeBackup(plan,paths); self.last_backup=backup end
    for _,op in ipairs(plan.ops) do
        if op.kind=="create" then
            ReadCollection:addCollection(op.shelf)
            ReadCollection.coll_settings[op.shelf][OWNER]=cat.library_id
        elseif op.kind=="add" then
            ReadCollection:addItem(paths[op.file],op.shelf)
        elseif op.kind=="remove" then
            ReadCollection:removeItem(root.."/"..op.file,op.shelf,true)
        elseif op.kind=="delete_empty" then
            if next(ReadCollection.coll[op.shelf]) then error("Retired shelf was not empty; stopped.") end
            ReadCollection:removeCollection(op.shelf)
        elseif op.kind=="favourite" then
            if op.value then ReadCollection:addItem(paths[op.file],favourites)
            else ReadCollection:removeItem(paths[op.file],favourites,true) end
        elseif op.kind=="status" then
            self:applyStatus(paths[op.file],op.value,tbr)
        end
    end
    if #plan.ops>0 then
        ReadCollection:write()
        -- Verify the actual saved collection file, not only the in-memory model.
        local disk=assert(dofile(DataStorage:getSettingsDir().."/collection.lua"))
        for name,c in pairs(ReadCollection.coll) do
            if (ReadCollection.coll_settings[name] or {})[OWNER]==cat.library_id or name==favourites then
                local saved=disk[name]; assert(type(saved)=="table","Collection save failed")
                local members={}; for _,entry in ipairs(saved) do members[entry.file]=true end
                for path in pairs(c) do assert(members[path],"Saved collection membership missing") end
                assert(count(members)==count(c),"Saved collection membership differs")
            end
        end
        for _,op in ipairs(plan.ops) do
            if op.kind=="delete_empty" then assert(disk[op.shelf]==nil,"Retired collection was not removed") end
        end
    end
    plan.next_state.root=root
    local encoded=JSON.encode(plan.next_state)
    if ledger_raw~=encoded then write(LEDGER,encoded) end
    self.last_raw,self.last_root=raw,root
    self.last_result=string.format("Calibre: %d books; %d changes.\nRevision %s",#cat.books,#plan.ops,cat.revision:sub(1,12))
    if #plan.warnings>0 then self.last_result=self.last_result.."\n"..table.concat(plan.warnings,"\n") end
    if backup then
        local bs=package.loaded["common/book_status"]; if type(bs)=="table" and bs.clearCache then bs.clearCache() end
        if tbr and tbr.invalidateAudit then tbr.invalidateAudit() end
        if self.ui.onRefresh then self.ui:onRefresh() end
    end
    return self.last_result
end
function Plugin:import(manual,force_flags)
    if manual then self.failed=false end
    local ok,result=pcall(self.run,self,force_flags and "flags" or (manual and true or nil))
    if not ok then
        logger.warn("Calibre Bookshelves",result)
        self.last_result=tostring(result)
        -- Transfer delays and missing catalogue are retried; actual failures pause.
        if not tostring(result):find("Waiting for complete book transfer",1,true)
            and not tostring(result):find("catalogue not found",1,true) then self.failed=true end
        if self.last_backup then self.last_result=self.last_result.."\nBackup: "..self.last_backup end
    end
    if manual then message(self.last_result or result) end
end
function Plugin:addToMainMenu(items)
    items.calibre_bookshelf={text="Calibre Bookshelves",sorting_hint="more_tools",sub_item_table={
        {text="Browse categories",callback=function() self:onBrowseCalibreCategories() end},
        {text="Import now",callback=function() self:import(true) end},
        {text="Automatic import while in Library",checked_func=function() return self.auto end,
            callback=function() self.auto=not self.auto; G_reader_settings:saveSetting("calibre_bookshelf_auto",self.auto) end},
        {text="Status / last result",callback=function() message(self.last_result or "Waiting for the Calibre catalogue. Return to Library to import.") end},
        {text="Set synced book folder",callback=function()
            local dialog
            dialog=InputDialog:new{title="Synced book folder",input=G_reader_settings:readSetting("calibre_bookshelf_root") or "",
                buttons={{{text="Cancel",callback=function() UIManager:close(dialog) end},
                    {text="Save",callback=function()
                        local path=dialog:getInputText():gsub("/+$","")
                        if path~="" and (path:sub(1,1)~="/" or lfs.attributes(path,"mode")~="directory") then
                            message("Choose an existing absolute folder path."); return
                        end
                        G_reader_settings:saveSetting("calibre_bookshelf_root",path~="" and path or nil)
                        self.last_raw=nil; self.failed=false; UIManager:close(dialog)
                    end}}}}
            UIManager:show(dialog); dialog:onShowKeyboard()
        end},
        {text="Reapply explicit Calibre favourites/status",callback=function() self:import(true,true) end},
    }}
end
return Plugin
