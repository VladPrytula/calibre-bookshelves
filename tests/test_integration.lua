-- Run the plugin against real files and KOReader's actual ReadCollection module.
-- UI, sidecar storage and ZenOS adapter are controlled doubles, not a device test.
package.path='/plugin/?.lua;/tests/upstream/?.lua;'..package.path
local lfs=require('lfs')
local JSON=require('cjson')
local function mkdir(path) assert(os.execute('mkdir -p '..string.format('%q',path))==0) end
local function dump(x)
    if type(x)~='table' then return type(x)=='string' and string.format('%q',x) or tostring(x) end
    local t={'{'};for k,v in pairs(x) do t[#t+1]='['..dump(k)..']='..dump(v)..',' end;t[#t+1]='}';return table.concat(t)
end
local function write(path,data) local f=assert(io.open(path,'wb'));f:write(data);f:close() end
local function read(path) local f=io.open(path,'rb');if not f then return nil end;local s=f:read('*a');f:close();return s end
local settings='/tmp/bookshelf-test/settings';mkdir(settings)
local root='/tmp/bookshelf-test/Paperwhite/Books';mkdir(root)
local b='Book [8765a416].epub';write(root..'/'..b,'0123456789')
local id='aef39fc4-236a-45bd-8820-f7eb9b0ded57'
local uid='8765a416-370d-4d8d-b69d-ff390a178255'
local gs={home_dir=root}
G_reader_settings={readSetting=function(_,k,default) if gs[k]==nil then return default end return gs[k] end,
 saveSetting=function(_,k,v)gs[k]=v end,nilOrTrue=function(_,k)return gs[k]~=false end}
local WC={extend=function(self,t)setmetatable(t,{__index=self});return t end}
local function mod(name,value)package.loaded[name]=value end
mod('ui/widget/container/widgetcontainer',WC)
local shown,ticks,opened,actions={},{},{},{}
local widgets=dofile('/tests/widget_doubles.lua')
mod('ui/uimanager',{scheduleIn=function()end,unschedule=function()end,show=function(_,widget)shown[#shown+1]=widget end,
 close=function(_,widget)widget.closed=true;if widget.onCloseWidget then widget:onCloseWidget()end end,setDirty=function()end,
 nextTick=function(_,fn)ticks[#ticks+1]=fn end})
mod('dispatcher',{registerAction=function(_,name,spec)actions[name]=spec end})
mod('apps/reader/readerui',{showReader=function(_,path)opened[#opened+1]=path end})
mod('device',{screen=widgets.screen})
local Menu=WC:extend{}
function Menu:new(t)
 t.item_table_stack={};t.page=math.floor(((t.item_table.current or 1)-1)/t.items_per_page)+1
 return setmetatable(t,{__index=self})
end
function Menu:getFirstVisibleItemIndex()
 return self.first_visible or ((self.page-1)*self.items_per_page+1)
end
function Menu:onMenuSelect(item)
 if item.sub_item_table then self.item_table.title=self.title;self.item_table_stack[#self.item_table_stack+1]=self.item_table;self.item_table=item.sub_item_table;self.title=item.text
 elseif item.select_enabled~=false and item.callback then item.callback() end
 return true
end
function Menu:onCloseAllMenus()self.closed=true;if self.close_callback then self.close_callback()end end
function Menu:onClose()if #self.item_table_stack>0 then self.item_table=table.remove(self.item_table_stack);self.title=self.item_table.title else self:onCloseAllMenus()end end
mod('ui/widget/menu',Menu)
mod('ui/widget/buttondialog',{new=function(_,t)return t end})
mod('ui/widget/infomessage',{new=function(_,t)return t end})
mod('ui/widget/inputdialog',{})
mod('datastorage',{getSettingsDir=function()return settings end})
mod('json',JSON);mod('libs/libkoreader-lfs',lfs)
mod('util',{makePath=mkdir})
mod('ffi/util',{realpath=function(path)if lfs.attributes(path) then return path end end})
mod('logger',{dbg=function()end,warn=function()end})
mod('document/documentregistry',{})
mod('ui/widget/booklist',{setBookInfoCache=function()end})
mod('luasettings',{open=function(_,path)
 local ok,data=pcall(dofile,path);if not ok then data={} end
 return {data=data,hasNot=function(self,k)return self.data[k]==nil end,
 saveSetting=function(self,k,v)self.data[k]=v end,delSetting=function(self,k)self.data[k]=nil end,
 flush=function(self)write(path,'return '..dump(self.data)) end}
end})
local DS={}
function DS:getSidecarDir(path,loc) return loc=='dir' and settings..'/docsettings'..path..'.sdr' or path:gsub('%.[^.]+$','')..'.sdr' end
function DS.getSidecarFilename(path)return 'metadata.'..path:match('%.([^.]+)$')..'.lua' end
function DS:findSidecarFile(path)local s=self:getSidecarDir(path)..'/'..self.getSidecarFilename(path);return lfs.attributes(s) and s or nil end
function DS:open(path)
 local s=self:getSidecarDir(path)..'/'..self.getSidecarFilename(path)
 local ok,data=pcall(dofile,s);if not ok then data={} end;data.doc_path=path
 return {data=data,readSetting=function(self,k)return self.data[k]end,
 saveSetting=function(self,k,v)self.data[k]=v end,
 flush=function(self)mkdir(DS:getSidecarDir(path));write(s,'return '..dump(self.data));return DS:getSidecarDir(path)end}
end
mod('docsettings',DS)
local explicit={}
local tbr={setExplicit=function(path,v)explicit[path]=v end,isExplicit=function(path)return explicit[path]==true end,refreshPath=function()end,invalidateAudit=function()end}
mod('common/tbr_index',tbr)
local RC=require('readcollection')
local Plugin=require('main')
local p=Plugin:extend{ui={menu={registerToMainMenu=function()end},onRefresh=function()end}}
p:init()
local cat={schema=1,library_id=id,revision=string.rep('a',64),books={{uuid=uid,file=b,bytes=10,shelves={'Mathematics'},favourite='unmanaged',status='unmanaged'}}}
local function publish(letter)cat.revision=string.rep(letter,64);write(root..'/.calibre-bookshelves.json',JSON.encode(cat))end
local function run()return p:run(true)end
local function check(name,fn) fn();print('PASS '..name)end
publish('a')
check('creates real KOReader collection file',function()run();local data=dofile(settings..'/collection.lua');assert(data.Mathematics[1].file==root..'/'..b);assert(data.Mathematics.settings.calibre_bookshelf_owner==id)end)
check('repeat import produces no operations or backup',function()local backup=p.last_backup;assert(run():find('0 changes',1,true));assert(p.last_backup==backup)end)
local original={doc_path=root..'/'..b,last_xpointer='/body/p[42]',last_page=42,percent_finished=0.4,annotations={{text='Keep me'}},summary={status='reading',note='private note'},font_size=25}
local doc=DS:open(root..'/'..b);doc.data=original;doc:flush()
check('explicit favourite and Finished preserve all other sidecar data',function()
 cat.books[1].favourite='yes';cat.books[1].status='Finished';publish('b');run()
 local after=DS:open(root..'/'..b).data
 assert(after.summary.status=='complete' and after.summary.note=='private note')
 assert(after.last_xpointer==original.last_xpointer and after.last_page==42 and after.percent_finished==0.4)
 assert(after.annotations[1].text=='Keep me' and after.font_size==25)
 assert(RC:isFileInCollection(root..'/'..b,'favorites'))
 assert(lfs.attributes(p.last_backup..'/index.json'))
end)
check('same status source does not repeatedly reset device status',function()
 local d=DS:open(root..'/'..b);d.data.summary.status='reading';d:flush();run();assert(DS:open(root..'/'..b).data.summary.status=='reading')
end)
check('explicit force reapply changes status',function()p:run('flags');assert(DS:open(root..'/'..b).data.summary.status=='complete')end)
check('missing TBR adapter stops before any mutation',function()
 cat.books[1].status='To Read';cat.books[1].favourite='no';publish('c');package.loaded['common/tbr_index']=nil
 local before=read(settings..'/collection.lua');local side=read(DS:findSidecarFile(root..'/'..b))
 local ok,err=pcall(run);assert(not ok and err:find('To Be Read adapter',1,true))
 assert(read(settings..'/collection.lua')==before and read(DS:findSidecarFile(root..'/'..b))==side)
end)
mod('common/tbr_index',tbr)
check('TBR adapter used without erasing progress',function()run();local d=DS:open(root..'/'..b).data;assert(explicit[root..'/'..b] and d.summary.status==nil and d.last_page==42 and d.annotations[1].text=='Keep me');assert(not RC:isFileInCollection(root..'/'..b,'favorites'))end)
check('unmanaged status preserves device state',function()cat.books[1].status='unmanaged';cat.books[1].favourite='unmanaged';publish('d');run();assert(DS:open(root..'/'..b).data.last_page==42 and explicit[root..'/'..b])end)
check('open reader blocks import',function()p.ui.document={};local ok=pcall(run);assert(not ok);p.ui.document=nil end)
check('catalogue before book defers all mutations',function()cat.books[1].bytes=11;publish('e');local before=read(settings..'/collection.lua');local ok=pcall(run);assert(not ok and read(settings..'/collection.lua')==before);cat.books[1].bytes=10 end)
check('remove shelf only when empty and owned',function()cat.books[1].shelves={};publish('f');run();assert(RC.coll.Mathematics==nil);assert(dofile(settings..'/collection.lua').Mathematics==nil)end)
check('Scribe root yields local absolute paths, not Paperwhite paths',function()
 -- New device: independent settings/ledger and ReadCollection instance.
 settings='/tmp/bookshelf-test/Scribe/settings';mkdir(settings)
 root='/tmp/bookshelf-test/Scribe/KindleLibrary';mkdir(root);write(root..'/'..b,'0123456789');gs.home_dir=root
 package.loaded.readcollection=nil;RC=require('readcollection');package.loaded.main=nil;Plugin=require('main')
 p=Plugin:extend{ui={menu={registerToMainMenu=function()end},onRefresh=function()end}};p:init()
 cat.books[1].shelves={'Mathematics'};publish('a');run()
 assert(RC.coll.Mathematics[root..'/'..b]);assert(dofile(settings..'/collection.lua').Mathematics[1].file==root..'/'..b)
end)
cat.navigation={version=1,nodes={{id='math',name='Mathematics',path='Mathematics'},
 {id='analysis',name='Analysis',path='Mathematics / Analysis',parent='math'}}}
cat.books[1].book_uuid=uid;cat.books[1].title='A Book';cat.books[1].authors='An Author';cat.books[1].format='epub';cat.books[1].shelves={'Mathematics / Analysis'}
publish('b')
local function find(items,text)for _,item in ipairs(items)do if item.text==text then return item end end;error('Missing item '..text)end
check('dispatcher exposes library-only category action',function()assert(actions.calibre_categories.event=='BrowseCalibreCategories' and actions.calibre_categories.filemanager and not actions.calibre_categories.general)end)
check('browsing navigates nested menus without collection or ledger writes',function()
 local collections=read(settings..'/collection.lua');local ledger=read(settings..'/calibre_bookshelf/state.json');local side=DS:findSidecarFile(root..'/'..b);local sidebytes=side and read(side)
 p:browseCategories();local menu=p.category_menu;assert(menu.layout=='tiles' and menu.widget.is_category_grid)
 menu:onMenuSelect(find(menu.item_table,'Mathematics'));menu:onMenuSelect(find(menu.item_table,'Analysis'))
 assert(menu.item_table[1].text=='A Book — An Author');menu:onClose();assert(menu.title=='Mathematics')
 assert(read(settings..'/collection.lua')==collections and read(settings..'/calibre_bookshelf/state.json')==ledger)
 assert((side and read(side))==sidebytes);menu:onCloseAllMenus();assert(not p.category_menu)
end)
check('visible view switch renders two-column tiles and remembers compact preference',function()
 p:browseCategories();local browser=p.category_menu
 assert(browser.widget.buttons[1][1].text=='View: Subject tiles')
 -- Add a sibling to check that subject tiles occupy a genuine two-column row.
 browser.item_table[#browser.item_table+1]={text='Physics',tile=true,mandatory='0 books',sub_item_table={}}
 browser.item_table[2],browser.item_table[#browser.item_table]=browser.item_table[#browser.item_table],browser.item_table[2]
 table.insert(browser.item_table,3,table.remove(browser.item_table))
 browser:render();assert(#browser.widget.buttons[3]==2)
 browser.widget.buttons[1][1].callback();browser.chooser.buttons[2][1].callback()
 assert(browser.layout=='compact' and browser.widget.items_per_page==8 and not browser.chooser)
 assert(browser.widget.item_table[1].text=='View: Compact list')
 browser:onMenuSelect(find(browser.item_table,'Mathematics'))
 browser.widget.page=2;browser:chooseLayout();browser.chooser.buttons[1][1].callback()
 assert(browser.title=='Mathematics' and #browser.stack==1 and browser.widget.is_category_grid)
 browser:onClose();assert(browser.title=='Calibre categories')
 browser:chooseLayout();browser.chooser:onClose();assert(not browser.chooser)
 browser:chooseLayout();browser.chooser.buttons[2][1].callback();browser:onCloseAllMenus()
 p:browseCategories();assert(p.category_menu.layout=='compact');p.category_menu:onCloseAllMenus()
end)
check('book pagination survives Back and view changes without duplicate close callbacks',function()
 p:browseCategories();local browser=p.category_menu
 browser.widget.page=2;browser:onMenuSelect(find(browser.item_table,'All books'))
 assert(browser.widget.items_per_page==6 and browser.widget.item_table[1].text=='View: List')
 browser.widget.item_table[1].callback();browser.chooser.buttons[2][1].callback()
 assert(browser.title=='All books' and browser.widget.is_cover_grid and browser.layout=='compact')
 assert(gs.calibre_categories_book_layout=='covers' and gs.calibre_categories_layout=='compact')
 browser:chooseLayout();browser.chooser.buttons[1][1].callback()
 assert(browser.widget.items_per_page==6 and browser.widget.items_max_lines==3)
 browser:onClose();assert(browser.page==2)
 browser:chooseLayout();browser:onCloseAllMenus();assert(not browser.chooser and not browser.widget and not p.category_menu)
 browser:onCloseAllMenus()
end)
check('cover preference persists independently and ready covers use guarded original paths',function()
 local registry=package.loaded['document/documentregistry'];local paths={}
 registry.openDocument=function(_,path)
  paths[#paths+1]=path
  return {getCoverPageImage=function()return {free=function()end}end,close=function()end}
 end
 p:browseCategories();local browser=p.category_menu
 browser:onMenuSelect(find(browser.item_table,'All books'))
 browser:chooseLayout();browser.chooser.buttons[2][1].callback()
 assert(paths[1]==root..'/'..b and browser.widget.cards[1].item.book.title=='A Book')
 browser:onCloseAllMenus();p:browseCategories();browser=p.category_menu
 assert(browser.layout=='compact' and browser.book_layout=='covers')
 browser:onMenuSelect(find(browser.item_table,'All books'));local before=#paths
 publish('e');browser:render();assert(#paths==before) -- stale catalogue blocks even a cover read
 publish('b');os.remove(root..'/'..b);browser:render();assert(#paths==before)
 write(root..'/'..b,'short');browser:render();assert(#paths==before)
 write(root..'/'..b,'0123456789');browser:render();assert(#paths==before+1)
 browser:onCloseAllMenus()
 gs.calibre_categories_book_layout='list'
end)
check('switching covers and list preserves book position and rendition Back',function()
 p:browseCategories();local browser=p.category_menu
 browser:onMenuSelect(find(browser.item_table,'All books'))
 local prototype=browser.item_table[1]
 for i=2,20 do browser.item_table[i]=prototype end
 browser.widget.page=3 -- list page starts at book 12 (including view row)
 browser:chooseLayout();browser.chooser.buttons[2][1].callback()
 assert(browser.widget.first==9 and browser.widget.page==3)
 browser.widget:nextPage();assert(browser.widget.first==13 and browser.widget.page==4)
 browser:chooseLayout();browser.chooser.buttons[1][1].callback()
 assert(browser.widget.item_table.current==14 and browser.widget.page==3)
 browser:chooseLayout();browser.chooser.buttons[2][1].callback()
 browser:onMenuSelect({text='Formats',sub_item_table={{text='EPUB'}}})
 browser:onClose();assert(browser.widget.is_cover_grid and browser.widget.first==9)
 browser:onCloseAllMenus();gs.calibre_categories_book_layout='list'
end)
check('adaptive wrapped Menu rows use the actual visible index when switching',function()
 p:browseCategories();local browser=p.category_menu
 browser:onMenuSelect(find(browser.item_table,'All books'))
 local prototype=browser.item_table[1]
 for i=2,25 do browser.item_table[i]=prototype end
 browser.widget.page=2;browser.widget.first_visible=16 -- actual wrapped-row layout, not fixed rows/page
 browser:chooseLayout();browser.chooser.buttons[2][1].callback()
 assert(browser.widget.first==13 and browser.widget.page==4)
 browser:onCloseAllMenus();gs.calibre_categories_book_layout='list'
end)
check('opening rechecks current bytes and passes exact original path',function()
 p:browseCategories();local menu=p.category_menu;menu:onMenuSelect(find(menu.item_table,'All books'));menu:onMenuSelect(menu.item_table[1])
 assert(not p.category_menu and #opened==0);table.remove(ticks,1)();assert(opened[1]==root..'/'..b)
end)
check('stale catalogue prevents opening from old view',function()
 p:browseCategories();local menu=p.category_menu;menu:onMenuSelect(find(menu.item_table,'All books'));publish('c');menu:onMenuSelect(menu.item_table[1]);assert(#ticks==0 and p.category_menu and shown[#shown].text:find('catalogue changed',1,true));menu:onCloseAllMenus()
end)
check('removed file is reported and leaves browser open',function()
 p:browseCategories();local menu=p.category_menu;menu:onMenuSelect(find(menu.item_table,'All books'));os.remove(root..'/'..b);menu:onMenuSelect(menu.item_table[1]);assert(#ticks==0 and p.category_menu and shown[#shown].text:find('Waiting for complete',1,true));write(root..'/'..b,'0123456789');menu:onCloseAllMenus()
end)
check('both formats use explicit rendition chooser',function()
 local pdf=b:gsub('epub$','pdf');write(root..'/'..pdf,'0123456789')
 local second={};for k,v in pairs(cat.books[1])do second[k]=v end;second.uuid='00000000-0000-4000-8000-000000000002';second.file=pdf;second.format='pdf';cat.books[2]=second;publish('d')
 p:browseCategories();local menu=p.category_menu;menu:onMenuSelect(find(menu.item_table,'All books'));assert(#menu.item_table==1);menu:onMenuSelect(menu.item_table[1]);assert(menu.item_table[1].text=='EPUB' and menu.item_table[2].text=='PDF');menu:onMenuSelect(menu.item_table[2]);table.remove(ticks,1)();assert(opened[2]==root..'/'..pdf)
end)
check('active reader prevents category browser',function()
 package.loaded['apps/reader/readerui'].instance={};local ok=pcall(function()p:browseCategories()end);assert(not ok and not p.category_menu);package.loaded['apps/reader/readerui'].instance=nil
end)
print('Integration tests passed: 24 (actual KOReader collections; controlled UI/sidecar/ZenOS adapters).')
