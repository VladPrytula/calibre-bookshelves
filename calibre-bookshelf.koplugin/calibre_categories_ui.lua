-- Standard KOReader widgets; no ZenOS monkey patches or collection writes.
local Menu = require("ui/widget/menu")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Categories = require("calibre_categories")
local M = {}

local function count(books)
    local n,waiting=Categories.count(books)
    return tostring(n)..(n==1 and " book" or " books")..(waiting>0 and " ("..waiting.." waiting)" or "")
end
local function empty(text)
    return {{text=text or "No books in this category on this Kindle.",dim=true,select_enabled=false}}
end

function M.items(model, open)
    local function book_items(books)
        local items=#books==0 and empty() or {}
        items.books=true
        for _,b in ipairs(books) do
            local formats={}; for _,r in ipairs(b.renditions) do formats[#formats+1]=r.format:upper() end
            local item={book=b,text=b.title..(b.authors~="" and " — "..b.authors or ""),
                mandatory=table.concat(formats,"+")..(not b.ready and " · waiting" or "")}
            if #b.renditions==1 then
                local rendition=b.renditions[1]
                item.open_book=function()open(rendition)end
            else
                item.sub_item_table={}
                for _,r in ipairs(b.renditions) do
                    local rendition=r
                    item.sub_item_table[#item.sub_item_table+1]={text=r.format:upper()..(r.ready and "" or " — waiting for transfer"),
                        open_book=function()open(rendition)end}
                end
            end
            items[#items+1]=item
        end
        return items
    end
    local function group(name,books) return {text=name,mandatory=count(books),sub_item_table=book_items(books)} end
    local items={group("All books",model.all)}
    items.categories=true
    if model.flat then
        items[#items+1]={text=model.newer and "These categories need a newer Calibre Bookshelves; saved shelves are listed below."
            or "Flat catalogue: publish updated categories from the Mac.",dim=true,select_enabled=false}
    else
        for _,n in ipairs(model.roots) do
            local item=group(n.name,n.books)
            item.tile=true
            if #n.children>0 then
                item.sub_item_table={group("All in "..n.name,n.books)}
                item.sub_item_table.categories=true
                for _,child in ipairs(n.children) do
                    local child_item=group(child.name,child.books); child_item.tile=true
                    item.sub_item_table[#item.sub_item_table+1]=child_item
                end
                if #n.direct>0 then item.sub_item_table[#item.sub_item_table+1]=group("General "..n.name,n.direct) end
            end
            items[#items+1]=item
        end
    end
    local legacy={text=model.flat and "Saved shelves" or "Older shelf names",mandatory=count(model.legacy),sub_item_table={}}
    for _,name in ipairs(model.legacy_names) do legacy.sub_item_table[#legacy.sub_item_table+1]=group(name,model.legacy_shelves[name]) end
    if #legacy.sub_item_table==0 then legacy.sub_item_table=empty("No older shelf names on this Kindle.") end
    items[#items+1]=legacy; items[#items+1]=group("Unassigned",model.unassigned)
    return items
end

local labels={tiles="Subject tiles",compact="Compact list"}
-- Tile rows per page. Rows differ in height, so page explicitly instead of
-- relying on ButtonDialog's equal-row scrolling.
M.TILE_ROWS=4
local setting="calibre_categories_layout"
local book_labels={list="List",covers="Covers"}
local book_setting="calibre_categories_book_layout"

-- Own the navigation stack so changing layout keeps the current category. Menus
-- remain responsible for book pagination; dialogs render the subject grid.
function M.show(model,open,closed,cover)
    local browser={stack={},title="Calibre categories",item_table=M.items(model,open),page=1,first=1}
    browser.layout=G_reader_settings:readSetting(setting,"tiles")
    if not labels[browser.layout] then browser.layout="tiles" end
    browser.book_layout=G_reader_settings:readSetting(book_setting,"list")
    if not book_labels[browser.book_layout] then browser.book_layout="list" end

    function browser:rememberPage()
        if self.widget and not self.widget.is_category_grid then self.page=self.widget.page or 1 end
        if self.item_table.books then
            self.first=self.widget.is_cover_grid and ((self.page-1)*self.widget.perpage+1)
                or math.max(1,self.widget:getFirstVisibleItemIndex()-1) -- first Menu row is the view control
        end
    end
    function browser:onCloseAllMenus()
        if self.closed then return end
        self.closed=true
        if self.chooser then UIManager:close(self.chooser); self.chooser=nil end
        if self.widget then UIManager:close(self.widget); self.widget=nil end
        if closed then closed() end
    end
    function browser:onClose()
        local previous=table.remove(self.stack)
        if not previous then self:onCloseAllMenus(); return true end
        self.title,self.item_table,self.page,self.first=previous.title,previous.items,previous.page,previous.first
        self:render()
        return true
    end
    function browser:onMenuSelect(item)
        if item.select_enabled==false then return true end
        if item.open_book then item.open_book(); return true end
        if item.sub_item_table then
            self:rememberPage()
            self.stack[#self.stack+1]={title=self.title,items=self.item_table,page=self.page,first=self.first}
            self.title,self.item_table,self.page,self.first=item.text,item.sub_item_table,1,1
            self:render()
        elseif item.callback then item.callback() end
        return true
    end
    function browser:chooseLayout()
        if self.chooser then return end
        self:rememberPage()
        local function dismiss()
            if self.chooser then UIManager:close(self.chooser); self.chooser=nil end
        end
        local function choose(layout)
            dismiss()
            if self.item_table.books then
                self.book_layout=layout
                G_reader_settings:saveSetting(book_setting,layout)
            else
                self.layout=layout
                G_reader_settings:saveSetting(setting,layout)
            end
            self:render()
        end
        local choices=self.item_table.books and {"list","covers"} or {"tiles","compact"}
        local names=self.item_table.books and book_labels or labels
        local current=self.item_table.books and self.book_layout or self.layout
        local buttons={}
        for _,choice in ipairs(choices) do
            local value=choice
            buttons[#buttons+1]={{text=names[value]..(current==value and " ✓" or ""),callback=function()choose(value)end}}
        end
        buttons[#buttons+1]={{text="Cancel",callback=dismiss}}
        self.chooser=ButtonDialog:new{title=self.item_table.books and "Book view" or "Category view",buttons=buttons}
        -- Override onClose so outside-tap and hardware Back clear the reference.
        self.chooser.onClose=function()dismiss();return true end
        UIManager:show(self.chooser)
    end
    function browser:render()
        if self.widget then UIManager:close(self.widget) end
        local owner=self
        local is_books=self.item_table.books
        local view={text="View: "..(is_books and book_labels[self.book_layout] or labels[self.layout]),callback=function()owner:chooseLayout()end}
        if is_books and self.book_layout=="covers" then
            self.widget=require("calibre_book_grid").new{
                title=self.title,items=self.item_table,first=self.first,cover=cover,
                select=function(item)owner:onMenuSelect(item)end,
                view=view.callback,back=function()owner:onClose()end,
                turn=function(first)owner.first=first;owner:render()end,
            }
        elseif self.layout=="tiles" and self.item_table.categories then
            -- Rows before the first tile and after it stay on every page; only tiles page.
            local head,tiles,tail={},{},{}
            for _,item in ipairs(self.item_table) do
                if item.tile then tiles[#tiles+1]=item elseif #tiles==0 then head[#head+1]=item else tail[#tail+1]=item end
            end
            local per=2*M.TILE_ROWS
            local pages=math.max(1,math.ceil(#tiles/per))
            self.page=math.min(math.max(1,self.page or 1),pages)
            local function button(item)
                local entry=item
                local b={text=item.text..(item.mandatory and " · "..item.mandatory or ""),
                    enabled=item.select_enabled~=false,font_size=20,
                    callback=function()owner:onMenuSelect(entry)end}
                if item.tile then b.height=math.floor(math.min(Screen:getWidth(),Screen:getHeight())*0.12) else b.font_bold=false end
                return b
            end
            local rows={{view}}
            for _,item in ipairs(head) do rows[#rows+1]={button(item)} end
            local first=(self.page-1)*per
            for i=first+1,math.min(#tiles,first+per),2 do
                rows[#rows+1]={button(tiles[i]),tiles[i+1] and button(tiles[i+1]) or nil}
            end
            for _,item in ipairs(tail) do rows[#rows+1]={button(item)} end
            if pages>1 then
                local function turn(delta)return function()owner.page=owner.page+delta;owner:render()end end
                rows[#rows+1]={{text="‹ Previous",enabled=self.page>1,callback=turn(-1)},
                    {text=self.page.." / "..pages,enabled=false},
                    {text="Next ›",enabled=self.page<pages,callback=turn(1)}}
            end
            rows[#rows+1]={{text=#self.stack>0 and "Back" or "Close",callback=function()owner:onClose()end}}
            local dialog=ButtonDialog:new{title=self.title,buttons=rows,width=math.floor(Screen:getWidth()*0.94),
                use_info_style=false,is_category_grid=true}
            dialog.onClose=function()return owner:onClose()end
            self.widget=dialog
        else
            local items={view}
            for _,item in ipairs(self.item_table) do items[#items+1]=item end
            local perpage=is_books and 6 or (self.layout=="compact" and 8 or 6)
            -- Menu:init resets page; item_table.current is its supported restore hook.
            items.current=math.min(#items,is_books and self.first+1 or (self.page-1)*perpage+1)
            local menu=Menu:new{title=self.title,item_table=items,
                width=Screen:getWidth(),height=Screen:getHeight(),is_popout=false,is_borderless=true,
                items_max_lines=is_books and 3 or (self.layout=="compact" and 2 or 3),
                title_bar_left_icon="appbar.menu",
                items_per_page=perpage}
            menu.onLeftButtonTap=view.callback
            menu.onMenuSelect=function(_,item)return owner:onMenuSelect(item)end
            menu.onClose=function()return owner:onClose()end
            menu.onCloseAllMenus=function()owner:onCloseAllMenus();return true end
            self.widget=menu
        end
        UIManager:show(self.widget)
    end
    browser:render()
    return browser
end
return M
