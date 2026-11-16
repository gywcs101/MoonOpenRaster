import assert from 'node:assert/strict';
import {request} from '../web/core.js';
const run=q=>JSON.parse(request(JSON.stringify(q)));
const sample=run({action:'sample'});
assert.equal(sample.ok,true);
const edit=run({action:'edit',path:[0,0],name:'中文图层',x:-10,y:20,opacity:.5,visible:false,op:'svg:multiply'});
assert.equal(edit.ok,true);
assert.equal(edit.tree[0].children[0].name,'中文图层');
const invalid=run({action:'edit',path:[0,0],name:'bad',x:1.5,y:0,opacity:1,visible:true,op:'svg:src-over'});
assert.equal(invalid.ok,false);
const saved=run({action:'export'});
assert.equal(saved.ok,true);
const loaded=run({action:'open',data:saved.data});
assert.equal(loaded.ok,true);
assert.equal(loaded.png,edit.png);
assert.equal(loaded.tree[0].children[0].visible,false);
const bad=run({action:'open',data:'AAAA'});
assert.equal(bad.ok,false);
assert.equal(run({action:'export'}).ok,true);
console.log('PASS: browser bridge edits, Chinese names, ORA reimport pixels and recovery after failed import');

const ordered=run({action:'reorder',path:[0,0],index:1});
assert.equal(ordered.ok,true);
assert.equal(ordered.tree[0].children[1].name,'中文图层');
const removed=run({action:'remove',path:[0,1]});
assert.equal(removed.ok,true);
assert.equal(removed.tree[0].children.length,1);
console.log('PASS: browser structural reorder and remove');

const composed=run({action:'compose',width:sample.width,height:sample.height,layers:[
 {name:'独立标题层',x:0,y:0,data:sample.png},
 {name:'原图',x:0,y:0,data:sample.png}
]});
assert.equal(composed.ok,true);
assert.equal(composed.tree[0].children[0].width,sample.width);
assert.equal(composed.png,sample.png);
console.log('PASS: raster-layer sample composition and thumbnail metadata');
