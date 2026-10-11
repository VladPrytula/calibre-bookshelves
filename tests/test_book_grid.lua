package.path='/plugin/?.lua;'..package.path
local widgets=dofile('/tests/widget_doubles.lua')
package.loaded.device={screen=widgets.screen}
local shown={}
package.loaded['ui/uimanager']={show=function(_,w)shown[#shown+1]=w end,
    close=function(_,w)w.closed=true;if w.close_callback then w.close_callback()end end,setDirty=function()end}
local Grid=require('calibre_book_grid')
local passed=0
local function check(name,fn)fn();passed=passed+1;print('PASS '..name)end
local function book(i,ready)
    return {text='Book '..i,mandatory='EPUB+PDF',book={title='Book '..i,authors='Author',ready=ready~=false,
        renditions={{format='epub',file=i..'.epub',ready=ready~=false},{format='pdf',file=i..'.pdf',ready=ready~=false}}}}
end
local items={};for i=1,13 do items[i]=book(i)end
local selected,turned,backs,views
local function make(extra)
    local opts={title='Analysis & PDE',items=items,first=1,
        select=function(item)selected=item end,turn=function(first)turned=first end,
        back=function()backs=(backs or 0)+1 end,view=function()views=(views or 0)+1 end}
    for k,v in pairs(extra or {})do opts[k]=v end
    return Grid.new(opts)
end
local function texts(widget,result)
    result=result or {}
    if widget.text then result[#result+1]=widget end
    for _,child in ipairs(widget)do texts(child,result)end
    return result
end
check('portrait cards fit both device sizes and use only the current page',function()
 for _,size in ipairs({{1072,1448,1.5},{1860,2480,2.5},{600,800,1}})do
  widgets.width,widgets.height,widgets.scale=unpack(size)
  local calls=0
  local grid=make{cover=function()calls=calls+1;return {free=function()end}end}
  assert(grid.perpage==4 and #grid.cards==4 and grid.pages==4 and calls==4)
  local d=grid[1]:getSize();assert(d.w<=widgets.width and d.h<=widgets.height)
  for _,card in ipairs(grid.cards)do assert(card[1]:getSize().h<=card.height)end
  grid:onCloseWidget()
 end
 widgets.width,widgets.height,widgets.scale=1072,1448,1.5
end)
check('long Unicode titles are retained and full details are available on hold',function()
 local title='Non-Homogeneous Boundary Value Problems and Applications, Volume III — Maß- und Integrationstheorie '..string.rep('long title ',60)
 local entry=book(1);entry.book.title=title;entry.book.authors='J. L. Lions & E. Magenes'
 local grid=make{items={entry}};local found
 for _,t in ipairs(texts(grid.cards[1]))do if t.text==title then found=t end end
 assert(found and found.height and found.height_overflow_show_ellipsis)
 assert(grid.cards[1][1]:getSize().h<=grid.cards[1].height)
 grid.cards[1]:onDetails();assert(shown[#shown].text:find(title,1,true))
 grid:onCloseWidget();assert(shown[#shown].closed)
end)
check('missing failed and incomplete covers keep selectable text cards',function()
 local calls=0
 local grid=make{items={book(1),book(2,false)},cover=function()calls=calls+1;error('damaged cover')end}
 assert(calls==2) -- both ready renditions tried; incomplete files never parsed
 local all={};for _,t in ipairs(texts(grid))do all[t.text]=true end
 assert(all['No cover'] and all['Waiting for transfer'])
 grid.cards[2]:onOpen();assert(selected==grid.cards[2].item)
 grid:onCloseWidget()
end)
check('fallback rendition can provide the cover without choosing how to open',function()
 local calls={};local bb={free=function()end}
 local grid=make{items={book(1)},cover=function(r)calls[#calls+1]=r.format;if r.format=='pdf' then return bb end end}
 assert(table.concat(calls,',')=='epub,pdf')
 grid.cards[1]:onOpen();assert(selected==grid.items[1])
 grid:onCloseWidget()
end)
check('cover buffers are freed on page close',function()
 local freed=0
 local grid=make{cover=function()return {free=function()freed=freed+1 end}end}
 assert(freed==0);grid:onCloseWidget();assert(freed==4)
end)
check('failed image scaling releases buffers and leaves a text fallback',function()
 local freed=0;widgets.image_error=true
 local grid=make{items={book(1)},cover=function()return {free=function()freed=freed+1 end}end}
 assert(freed==2 and #grid.cards==1)
 widgets.image_error=false;grid:onCloseWidget();assert(freed==2)
end)
check('paging swipes bounds and final partial page retain exact item identity',function()
 local grid=make{first=13};assert(grid.page==4 and #grid.cards==1 and grid.cards[1].item==items[13])
 turned=nil;grid:nextPage();assert(not turned)
 grid:onSwipe(nil,{direction='east'});assert(turned==9)
 grid:onClose();assert(backs==1)
 grid:onCloseWidget()
 grid=make();turned=nil;grid:previousPage();assert(not turned)
 grid:onSwipe(nil,{direction='west'});assert(turned==5)
 grid:onCloseWidget()
end)
check('landscape retains two wide cards within the viewport',function()
 widgets.width,widgets.height=1448,1072
 local grid=make{first=7};assert(grid.perpage==2 and grid.first==7 and #grid.cards==2)
 local d=grid[1]:getSize();assert(d.h<=widgets.height and d.w<=widgets.width)
 grid:onCloseWidget();widgets.width,widgets.height=1072,1448
end)
check('empty shelves keep navigation without cover reads',function()
 local grid=make{items={},cover=function()error('must not read')end}
 assert(#grid.cards==0 and grid.pages==1);grid:onCloseWidget()
end)
local custom,opened,closed,fail,load_fail
package.loaded.docsettings={findCustomCoverFile=function()return custom end}
package.loaded['document/documentregistry']={openDocument=function(_,path)
 opened[#opened+1]=path
 return {loadDocument=function(_,render)assert(render==false);return not load_fail end,
  getCoverPageImage=function()if fail and fail[path] then error('bad cover')end;return {path=path}end,
  close=function()closed=closed+1 end}
end}
local function reset()custom=nil;opened={};closed=0;fail=nil;load_fail=false end
check('cover extraction loads metadata only and closes the document',function()
 reset();assert(Grid.cover('/Books/a.epub').path=='/Books/a.epub' and closed==1)
end)
check('custom covers take precedence without opening the book',function()
 reset();custom='/Books/a.sdr/cover.jpg'
 assert(Grid.cover('/Books/a.epub').path==custom and #opened==1 and closed==1)
end)
check('decoder errors close documents and fall back from bad custom covers',function()
 reset();custom='/Books/a.sdr/cover.jpg';fail={[custom]=true}
 assert(Grid.cover('/Books/a.epub').path=='/Books/a.epub' and closed==2)
 fail['/Books/a.epub']=true;assert(Grid.cover('/Books/a.epub')==nil and closed==4)
end)
check('failed metadata load still closes the document',function()
 reset();load_fail=true;assert(Grid.cover('/Books/a.epub')==nil and closed==1)
end)
print('Book grid tests passed: '..passed..' (controlled widget geometry and document adapters).')
