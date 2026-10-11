-- The documented sample catalogue must pass the plugin's own validator and plan cleanly.
package.path='/plugin/?.lua;'..package.path
local JSON=require('cjson')
local C=require('calibre_bookshelf_core')
local Cat=require('calibre_categories')
local f=assert(io.open('/docs/sample-catalogue.json','rb')); local raw=f:read('*a'); f:close()
local cat=JSON.decode(raw)
assert(C.validate(cat))
local available={}
for _,b in ipairs(cat.books) do available[b.file]=b.bytes end
local p=C.plan(cat,{books={}},{collections={favorites={files={}}},favourites={}},available)
assert(#p.ops>0,'expected collection operations for a fresh device')
local model=Cat.build(cat,available)
assert(model.flat,'sample has no navigation block and must browse flat')
print('Sample catalogue: valid, '..#cat.books..' books, '..#p.ops..' initial operations.')
