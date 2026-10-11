-- Geometry/resource contracts only; these do not certify e-ink rendering.
local M={width=1072,height=1448,scale=1.5,images={}}
local Widget={}
function Widget:extend(t)return setmetatable(t,{__index=self})end
function Widget:new(t)
    t=setmetatable(t or {},{__index=self})
    if t.init then t:init() end
    return t
end
function Widget:getSize()
    if self.dimen then return self.dimen end
    if self[1] then return self[1]:getSize() end
    return {w=self.width or 0,h=self.height or 0}
end
function Widget:free()
    self.freed=true
    for _,child in ipairs(self) do if child.free then child:free() end end
end
local function mod(name,value)package.loaded[name]=value end
local Text=Widget:extend{}
function Text:getSize()
    local size=self.face.size
    local lines=math.max(1,math.ceil(#self.text/math.max(1,math.floor(self.width/(size*0.55)))))
    return {w=self.width,h=self.height or math.ceil(lines*size*1.2)}
end
local V=Widget:extend{}
function V:getSize()
    local w,h=0,0
    for _,c in ipairs(self)do local d=c:getSize();w=math.max(w,d.w);h=h+d.h end
    return {w=w,h=h}
end
local H=Widget:extend{}
function H:getSize()
    local w,h=0,0
    for _,c in ipairs(self)do local d=c:getSize();w=w+d.w;h=math.max(h,d.h) end
    return {w=w,h=h}
end
local Frame=Widget:extend{}
function Frame:getSize()
    local d=self[1]:getSize();local pad=2*((self.padding or 0)+(self.bordersize or 0)+(self.margin or 0))
    return {w=d.w+pad,h=d.h+pad}
end
local Image=Widget:extend{}
function Image:init()M.images[#M.images+1]=self end
function Image:getSize()
    if M.image_error then error('image scaling failed') end
    return {w=self.width,h=self.height}
end
function Image:free()
    if not self.freed then self.image:free();self.freed=true end
end
local Buttons=Widget:extend{}
function Buttons:getSize()return {w=self.width,h=#self.buttons*math.floor(48*M.scale)}end
local Span=Widget:extend{}
function Span:getSize()return {w=0,h=self.width}end
local HSpan=Widget:extend{}
function HSpan:getSize()return {w=self.width,h=0}end
mod('ui/widget/container/inputcontainer',Widget)
mod('ui/widget/container/framecontainer',Frame)
mod('ui/widget/container/centercontainer',Widget)
mod('ui/widget/verticalgroup',V);mod('ui/widget/horizontalgroup',H)
mod('ui/widget/verticalspan',Span);mod('ui/widget/horizontalspan',HSpan)
mod('ui/widget/textboxwidget',Text);mod('ui/widget/imagewidget',Image)
mod('ui/widget/buttontable',Buttons);mod('ui/widget/textviewer',Widget)
mod('ui/font',{getFace=function(_,_,size)return {size=size*M.scale}end})
mod('ui/geometry',Widget);mod('ui/gesturerange',Widget)
mod('ffi/blitbuffer',{COLOR_WHITE=255})
M.screen={getWidth=function()return M.width end,getHeight=function()return M.height end,
    scaleBySize=function(_,n)return math.floor(n*M.scale)end}
return M
