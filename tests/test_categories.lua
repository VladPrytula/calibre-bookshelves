package.path='/plugin/?.lua;'..package.path
local C=require('calibre_categories')
local Core=require('calibre_bookshelf_core')
local function clone(t) if type(t)~='table' then return t end local x={};for k,v in pairs(t) do x[k]=clone(v) end;return x end
local id='11111111-1111-4111-8111-111111111111'
local function uid(i) return string.format('00000000-0000-4000-8000-%012d',i) end
local function book(i,shelves,format,original)
 format=format or 'epub'
 return {uuid=uid(i),book_uuid=uid(original or i),title='Book '..(original or i),authors='An Author',format=format,
 file='Book '..i..'.'..format,bytes=10,shelves=shelves,status='unmanaged',favourite='unmanaged'}
end
local cat={schema=1,library_id=id,revision=string.rep('a',64),navigation={version=1,nodes={
 {id='math',name='Mathematics',path='Mathematics'},
 {id='analysis',name='Analysis',path='Mathematics / Analysis',parent='math'},
 {id='geometry',name='Geometry',path='Mathematics / Geometry',parent='math'},
 {id='fiction',name='Literature',path='Literature'}}},
 books={book(1,{'Mathematics / Analysis'}),book(2,{'Mathematics'}),book(3,{'Mathematics / Analysis','Mathematics / Geometry'}),book(4,{'Old Fiction'}),book(5,{})}}
local function build(c) c=c or clone(cat);local available={};for _,b in ipairs(c.books) do available[b.file]=b.bytes end;return C.build(c,available) end
local n=0
local function test(name,fn) fn();n=n+1;print('PASS '..name)end
local function raises(fn,pattern)local ok,e=pcall(fn);assert(not ok and tostring(e):find(pattern,1,true),tostring(e))end
test('parent union includes direct and child assignments once',function()local m=build();assert(#m.nodes.math.books==3 and #m.nodes.math.direct==1 and #m.nodes.analysis.books==2)end)
test('exact destinations and empty definitions retained',function()local m=build();assert(#m.roots==2 and #m.nodes.fiction.books==0 and #m.nodes.math.children==2)end)
test('legacy labels are not silently interpreted',function()local c=clone(cat);c.books[1].shelves={'Analysis'};local m=build(c);assert(#m.nodes.analysis.books==1 and #m.legacy==2 and #m.legacy_shelves.Analysis==1)end)
test('unassigned differs from older shelf names',function()local m=build();assert(#m.unassigned==1 and m.unassigned[1].id==uid(5) and #m.legacy==1)end)
test('both formats count as one original Calibre book',function()local c=clone(cat);c.books[#c.books+1]=book(6,{'Mathematics / Analysis'},'pdf',1);local m=build(c);assert(#m.all==5 and #m.nodes.math.books==3 and #m.all[1].renditions==2 and m.all[1].renditions[1].format=='epub')end)
test('missing and partial files remain explicit',function()local m=C.build(cat,{['Book 1.epub']=9,['Book 2.epub']=10});local total,waiting=C.count(m.all);assert(total==5 and waiting==4)end)
test('one ready rendition makes a book available',function()local c=clone(cat);c.books[#c.books+1]=book(6,{'Mathematics / Analysis'},'pdf',1);local m=C.build(c,{['Book 6.pdf']=10});assert(m.all[1].ready and not m.all[1].renditions[1].ready and m.all[1].renditions[2].ready)end)
test('old catalogue has a flat saved-shelf fallback',function()local c=clone(cat);c.navigation=nil;local m=build(c);assert(m.flat and #m.roots==0 and #m.legacy_names==4 and #m.unassigned==1)end)
test('empty catalogue retains the category tree',function()local c=clone(cat);c.books={};local m=build(c);assert(#m.all==0 and #m.roots==2)end)
local function wide(version,children)
 local c=clone(cat);c.navigation={version=version,nodes={{id='math',name='Mathematics',path='Mathematics'}}}
 for i=1,children do c.navigation.nodes[#c.navigation.nodes+1]={id='c'..i,name='Child '..i,path='Mathematics / Child '..i,parent='math'} end
 for i=2,6 do c.navigation.nodes[#c.navigation.nodes+1]={id='r'..i,name='Root '..i,path='Root '..i} end
 c.books={book(1,{'Mathematics / Child 1'})};return c
end
test('version 1 keeps its original budget of eight sub-shelves',function()assert(#build(wide(1,8)).nodes.math.children==8);raises(function()build(wide(1,9))end,'Unsupported navigation')end)
test('version 2 accepts sixteen sub-shelves and six subjects',function()local m=build(wide(2,16));assert(#m.roots==6 and #m.nodes.math.children==16 and #m.nodes.c1.books==1)end)
test('version 2 refuses a seventeenth sub-shelf or a seventh subject',function()
 raises(function()build(wide(2,17))end,'Unsupported navigation')
 local c=wide(2,15);c.navigation.nodes[#c.navigation.nodes+1]={id='r7',name='Root 7',path='Root 7'};raises(function()build(c)end,'budget')end)
test('a newer navigation version falls back to saved shelf names',function()local c=clone(cat);c.navigation.version=3;assert(Core.validate(c));local m=build(c);assert(m.flat and m.newer==3 and #m.roots==0 and #m.legacy_names==4)end)
test('malformed navigation versions still fail browsing',function()for _,v in ipairs({0,'2',2.5})do local c=clone(cat);c.navigation.version=v;raises(function()build(c)end,'Unsupported navigation')end end)
test('cyclic and unknown parents rejected',function()local c=clone(cat);c.navigation.nodes[1].parent='analysis';raises(function()build(c)end,'hierarchy');c=clone(cat);c.navigation.nodes[2].parent='missing';raises(function()build(c)end,'hierarchy')end)
test('duplicate IDs paths and reserved names rejected',function()local c=clone(cat);c.navigation.nodes[2].id='math';raises(function()build(c)end,'definition');c=clone(cat);c.navigation.nodes[4].path='Mathematics';raises(function()build(c)end,'definition');c=clone(cat);c.navigation.nodes[4].name='favorites';raises(function()build(c)end,'definition')end)
test('arbitrary display paths do not define the hierarchy',function()local c=clone(cat);c.navigation.nodes[2].path='Mathematics / Forged';raises(function()build(c)end,'hierarchy')end)
test('inconsistent renditions rejected',function()local c=clone(cat);c.books[#c.books+1]=book(6,{'Other'},'pdf',1);raises(function()build(c)end,'disagree')end)
test('duplicate format for original identity rejected',function()local c=clone(cat);c.books[#c.books+1]=book(6,{'Mathematics / Analysis'},'epub',1);raises(function()build(c)end,'Duplicate rendition')end)
test('navigation never mutates catalogue or availability',function()local before=clone(cat);local m=build(cat);assert(cat.books[1].ready==nil and cat.books[1].renditions==nil and cat.navigation.nodes[1].books==nil);assert(cat.books[1].file==before.books[1].file)end)
test('invalid filename and format cannot reach open action',function()local c=clone(cat);c.books[1].file='../outside.epub';raises(function()build(c)end,'Invalid or duplicate');c=clone(cat);c.books[1].format='pdf';raises(function()build(c)end,'display metadata')end)
print('Category model tests passed: '..n)
