-- Offline cover cards built from KOReader widgets. No collection/sidecar writes.
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local ButtonTable = require("ui/widget/buttontable")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local M = {}

-- Follow FileManagerBookInfo's metadata-only cover API, with guaranteed document
-- close on a decoder error. Custom covers are read, never created or rewritten.
function M.cover(path)
    local Registry = require("document/documentregistry")
    local function extract(file)
        local doc
        local ok,bb=pcall(function()
            doc=Registry:openDocument(file)
            if not doc then return end
            if doc.loadDocument and not doc:loadDocument(false) then return end
            return doc:getCoverPageImage()
        end)
        if doc then pcall(doc.close,doc) end
        if ok then return bb end
    end
    local ok,custom=pcall(function()return require("docsettings"):findCustomCoverFile(path)end)
    if ok and custom then
        local bb=extract(custom)
        if bb then return bb end
    end
    return extract(path)
end

local function text(value,width,size,height,bold)
    return TextBoxWidget:new{text=value,width=width,height=height,
        face=Font:getFace("cfont",size),bold=bold,alignment="center",
        height_overflow_show_ellipsis=true}
end

local Card=InputContainer:extend{}
function Card:init()
    self.dimen=Geom:new{w=self.width,h=self.height}
    local pad=Screen:scaleBySize(6)
    local w,h=self.width-2*pad-2,self.height-2*pad-2
    local gap=Screen:scaleBySize(4)
    -- Title gets nearly half the card when needed; short titles give that space
    -- back to the cover. Font size stays legible rather than shrinking to fit.
    local title=text(self.item.book.title,w,20,nil,true)
    local title_cap=math.floor(h*0.45)
    if title:getSize().h>title_cap then
        title:free()
        title=text(self.item.book.title,w,20,title_cap,true)
    end
    local author=text(self.item.book.authors,w,16,math.floor(h*0.14))
    local formats=text(self.item.mandatory,w,14,math.floor(h*0.08))
    local cover_h=math.max(1,h-title:getSize().h-author:getSize().h-formats:getSize().h-3*gap)
    local cover
    if self.cover then
        for _,rendition in ipairs(self.item.book.renditions) do
            if rendition.ready then
                local ok,bb=pcall(self.cover,rendition)
                if ok and bb then
                    local candidate
                    local rendered=pcall(function()
                        candidate=ImageWidget:new{image=bb,image_disposable=true,width=w,height=cover_h,scale_factor=0}
                        candidate:getSize()
                    end)
                    -- Resize now so only a page of thumbnails is retained. The
                    -- original buffer is owned/freed by ImageWidget.
                    if rendered then cover=candidate;break end
                    if candidate then candidate:free() else bb:free() end
                end
            end
        end
    end
    cover=cover or CenterContainer:new{dimen=Geom:new{w=w,h=cover_h},
        text(self.item.book.ready and "No cover" or "Waiting for transfer",w,18)}
    self[1]=FrameContainer:new{padding=pad,bordersize=1,margin=0,background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align="center",cover,VerticalSpan:new{width=gap},title,
            VerticalSpan:new{width=gap},author,VerticalSpan:new{width=gap},formats}}
    self.ges_events={
        Open={GestureRange:new{ges="tap",range=self.dimen}},
        Details={GestureRange:new{ges="hold",range=self.dimen}},
    }
end
function Card:onOpen() self.select(self.item);return true end
function Card:onDetails()
    self.details(self.item)
    return true
end

local Grid=InputContainer:extend{is_cover_grid=true}
function Grid:init()
    local w,h=Screen:getWidth(),Screen:getHeight()
    local pad=Screen:scaleBySize(8)
    local width=w-2*pad
    local rows=h>=w and 2 or 1
    self.perpage=rows*2
    local total=self.items[1] and self.items[1].book and #self.items or 0
    local pages=math.max(1,math.ceil(total/self.perpage))
    self.page=math.min(pages,math.max(1,math.floor(((self.first or 1)-1)/self.perpage)+1))
    self.first=(self.page-1)*self.perpage+1
    self.pages=pages
    local title=text(self.title,width,24,math.floor(h*0.07),true)
    local controls=ButtonTable:new{width=width,buttons={{
        {text="View: Covers",callback=self.view},
        {text="Back",callback=self.back},
    }}}
    local footer=ButtonTable:new{width=width,buttons={{
        {text="Previous",enabled=self.page>1,callback=function()self:previousPage()end},
        {text=tostring(self.page).." / "..pages,enabled=false,callback=function()end},
        {text="Next",enabled=self.page<pages,callback=function()self:nextPage()end},
    }}}
    local hint=text("Hold a book for its full title and author",width,14)
    local grid_h=h-2*pad-title:getSize().h-controls:getSize().h-footer:getSize().h-hint:getSize().h-3*pad
    local card_h=math.floor((grid_h-(rows-1)*pad)/rows)
    local card_w=math.floor((width-pad)/2)
    local cards=VerticalGroup:new{align="left"}
    self.cards={}
    for row=1,rows do
        local line=HorizontalGroup:new{align="top"}
        for column=1,2 do
            local i=self.first+(row-1)*2+column-1
            local item=i<=total and self.items[i]
            if item then
                local card=Card:new{item=item,width=card_w,height=card_h,cover=self.cover,select=self.select,
                    details=function(entry)self:showDetails(entry)end}
                self.cards[#self.cards+1]=card
                line[#line+1]=card
            else
                line[#line+1]=CenterContainer:new{dimen=Geom:new{w=card_w,h=card_h},
                    text(total==0 and row==1 and column==1 and "No books on this shelf." or "",card_w,18)}
            end
            if column==1 then line[#line+1]=HorizontalSpan:new{width=pad} end
        end
        cards[#cards+1]=line
        if row<rows then cards[#cards+1]=VerticalSpan:new{width=pad} end
    end
    self.dimen=Geom:new{w=w,h=h}
    self[1]=FrameContainer:new{padding=pad,bordersize=0,margin=0,width=w,height=h,background=Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{align="left",title,controls,VerticalSpan:new{width=pad},cards,
            VerticalSpan:new{width=pad},hint,VerticalSpan:new{width=pad},footer}}
    self.key_events={Close={{"Back"}},NextPage={{"LPgFwd"},{"RPgFwd"}},PreviousPage={{"LPgBack"},{"RPgBack"}}}
    self.ges_events={Swipe={GestureRange:new{ges="swipe",range=self.dimen}}}
end
function Grid:showDetails(item)
    local TextViewer=require("ui/widget/textviewer")
    self.detail_widget=TextViewer:new{title="Book details",text=item.book.title.."\n\n"..item.book.authors.."\n\n"..item.mandatory,
        close_callback=function()self.detail_widget=nil end}
    UIManager:show(self.detail_widget)
end
function Grid:onNextPage()return self:nextPage()end
function Grid:onPreviousPage()return self:previousPage()end
function Grid:nextPage()
    if self.page<self.pages then self.turn(self.first+self.perpage) end
    return true
end
function Grid:previousPage()
    if self.page>1 then self.turn(self.first-self.perpage) end
    return true
end
function Grid:onSwipe(_,ges)
    if ges.direction=="west" then return self:nextPage() end
    if ges.direction=="east" then return self:previousPage() end
    return true
end
function Grid:onClose()self.back();return true end
function Grid:onShow()UIManager:setDirty(self,"ui");return true end
function Grid:onCloseWidget()
    if self.detail_widget then UIManager:close(self.detail_widget);self.detail_widget=nil end
    self:free()
    UIManager:setDirty(nil,"ui")
end
function M.new(options)return Grid:new(options)end
return M
