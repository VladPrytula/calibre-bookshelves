package.path='/plugin/?.lua;'..package.path
local C=require('calibre_bookshelf_core')
local function clone(t) if type(t)~='table' then return t end local x={};for k,v in pairs(t) do x[k]=clone(v) end;return x end
local ID='aef39fc4-236a-45bd-8820-f7eb9b0ded57'
local B='8765a416-370d-4d8d-b69d-ff390a178255'
local cat={schema=1,library_id=ID,revision=string.rep('a',64),books={{uuid=B,file='Book [8765a416].epub',bytes=10,shelves={'Mathematics'},favourite='unmanaged',status='unmanaged'}}}
local f=cat.books[1].file
local snap={collections={favorites={files={}}},favourites={}}
local function plan(c,s,v,a,force) return C.plan(c or clone(cat),s or {books={}},v or clone(snap),a or {[f]=10},force) end
local n=0
local function test(name,fn) fn(); n=n+1; print('PASS '..name) end
local function raises(fn,pattern) local ok,e=pcall(fn);assert(not ok and tostring(e):find(pattern,1,true),tostring(e)) end
local function has(p,kind) for _,op in ipairs(p.ops) do if op.kind==kind then return true end end return false end
test('creates missing shelf and membership',function() local p=plan();assert(has(p,'create') and has(p,'add'));assert(not has(p,'status') and not has(p,'favourite')) end)
test('idempotent after apply',function() local p=plan();local s=clone(snap);s.collections.Mathematics={owner=ID,files={[f]=true}};assert(#plan(nil,p.next_state,s).ops==0) end)
test('defer entire catalogue when any book missing',function() raises(function()plan(nil,nil,nil,{})end,'Waiting for complete') end)
test('defer truncated book',function()raises(function()plan(nil,nil,nil,{[f]=9})end,'Waiting for complete')end)
test('reject path traversal',function()local c=clone(cat);c.books[1].file='../book.epub';raises(function()plan(c)end,'Invalid or duplicate')end)
test('reject unsupported schema',function()local c=clone(cat);c.schema=9;raises(function()plan(c)end,'unsupported schema')end)
test('reject duplicate identity',function()local c=clone(cat);c.books[2]=clone(c.books[1]);raises(function()plan(c)end,'Invalid or duplicate')end)
test('reject foreign library ledger',function()raises(function()plan(nil,{library_id=B,books={}})end,'Different Calibre library')end)
test('do not adopt unrelated collection',function()local s=clone(snap);s.collections.Mathematics={files={}};raises(function()plan(nil,nil,s)end,'outside this Calibre')end)
test('case-insensitive collision',function()local s=clone(snap);s.collections.mathematics={owner=ID,files={}};raises(function()plan(nil,nil,s)end,'outside this Calibre')end)
test('explicit false removes favourite',function()local c=clone(cat);c.books[1].favourite='no';local s=clone(snap);s.favourites[f]=true;assert(has(plan(c,nil,s),'favourite'))end)
test('unset favourite does not remove local favourite',function()local s=clone(snap);s.favourites[f]=true;assert(not has(plan(nil,nil,s),'favourite'))end)
test('status applies once; reapply is explicit',function()local c=clone(cat);c.books[1].status='Finished';local p=plan(c);assert(has(p,'status'));assert(not has(plan(c,p.next_state),'status'));assert(has(plan(c,p.next_state,nil,nil,true),'status'))end)
test('unset status does not reset progress',function()local p=plan();p.next_state.books[B].status='Reading';assert(not has(plan(nil,p.next_state),'status'))end)
test('remove stale managed membership and empty retired shelf',function()local c=clone(cat);c.books[1].shelves={};local s=clone(snap);s.collections.Mathematics={owner=ID,files={[f]=true}};local p=plan(c,nil,s);assert(has(p,'remove') and has(p,'delete_empty'))end)
test('preserve unrelated books in retired managed shelf',function()local c=clone(cat);c.books[1].shelves={};local s=clone(snap);s.collections.Mathematics={owner=ID,files={[f]=true,['Local.epub']=true}};local p=plan(c,nil,s);assert(has(p,'remove') and not has(p,'delete_empty') and #p.warnings==1)end)
test('favourites and TBR cannot become managed subject shelves',function()local c=clone(cat);c.books[1].shelves={'favorites'};raises(function()plan(c)end,'reserved shelf')end)
test('filename extension transition removes prior membership',function()local p=plan();p.next_state.books[B].file='Old.pdf';local s=clone(snap);s.collections.Mathematics={owner=ID,files={['Old.pdf']=true}};local p2=plan(nil,p.next_state,s);assert(has(p2,'remove') and has(p2,'add'))end)
test('empty catalogue retires managed membership without touching local books',function()
 local previous=plan().next_state
 local c=clone(cat);c.books={}
 local s=clone(snap);s.collections.Mathematics={owner=ID,files={[f]=true,['Local.epub']=true}}
 local p=plan(c,previous,s,{})
 assert(has(p,'remove') and not has(p,'delete_empty') and not has(p,'status'))
 assert(next(p.next_state.books)==nil)
end)
print('Core tests passed: '..n)
