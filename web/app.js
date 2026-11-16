import {request} from './core.js';
const $=id=>document.getElementById(id);
let state,selected,original;
const modes=['src-over','multiply','screen','overlay','darken','lighten','color-dodge','color-burn','hard-light','soft-light','difference','color','luminosity','hue','saturation','plus','dst-in','dst-out','src-atop','dst-atop'];
for(const mode of modes){const option=document.createElement('option');option.value='svg:'+mode;option.textContent=mode;$('op').append(option)}
function invoke(query){const result=JSON.parse(request(JSON.stringify(query)));if(!result.ok)throw Error(result.error);return result}
function status(message){$('status').textContent=message||state?.warning||''}
function choose(node){selected=node;for(const id of ['name','x','y','opacity','op'])$(id).value=node[id];$('visible').checked=node.visible;$('opacityValue').value=Math.round(node.opacity*100)+'%';drawTree()}
function drawTree(){const container=$('tree');container.replaceChildren();let count=0;function visit(nodes,depth){for(const node of nodes){count++;const button=document.createElement('button');button.className='layer'+(selected&&JSON.stringify(node.path)===JSON.stringify(selected.path)?' active':'')+(!node.visible?' hidden':'');button.style.paddingLeft=8+depth*16+'px';button.textContent=(node.kind==='group'?'▾  ':'◻  ')+node.name;button.onclick=()=>choose(node);container.append(button);visit(node.children,depth+1)}}visit(state.tree,0);$('count').textContent=count}
function show(result,reset=false){state=result;if(reset){original=result.original||result.png;$('original').checked=false;selected=null}const nodes=[];function walk(list){for(const n of list){nodes.push(n);walk(n.children)}}walk(result.tree);selected=nodes.find(n=>selected&&JSON.stringify(n.path)===JSON.stringify(selected.path))||nodes[0];$('title').textContent=result.name;$('dimensions').textContent=result.width+' × '+result.height+' px';$('canvas').src='data:image/png;base64,'+($('original').checked?original:state.png);if(selected)choose(selected);else drawTree();for(const control of $('properties').elements)control.disabled=result.editable===false;status(result.warning||'')}
function guard(action){try{action();status('')}catch(e){status(e.message)}}
$('sample').onclick=()=>guard(()=>show(invoke({action:'sample'}),true));
$('open').onclick=()=>$('file').click();
$('file').onchange=async()=>{const file=$('file').files[0];if(!file)return;try{if(file.size>32*1024*1024)throw Error('Browser import limit is 32 MiB.');const bytes=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.subarray(i,i+16384));show(invoke({action:'open',data:btoa(binary)}),true);status('')}catch(e){status(e.message)}finally{$('file').value=''}};
$('properties').onsubmit=e=>{e.preventDefault();guard(()=>{if(!selected)return;show(invoke({action:'edit',path:selected.path,name:$('name').value,x:Number($('x').value),y:Number($('y').value),opacity:Number($('opacity').value),visible:$('visible').checked,op:$('op').value}))})};
$('opacity').oninput=()=>$('opacityValue').value=Math.round(Number($('opacity').value)*100)+'%';
$('original').onchange=()=>{$('canvas').src='data:image/png;base64,'+($('original').checked?original:state.png)};
function download(base64,name,type){const bytes=Uint8Array.from(atob(base64),c=>c.charCodeAt(0));const url=URL.createObjectURL(new Blob([bytes],{type}));const link=document.createElement('a');link.href=url;link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
$('png').onclick=()=>guard(()=>download(state.png,'composite.png','image/png'));
$('save').onclick=()=>guard(()=>download(invoke({action:'export'}).data,'edited.ora','image/openraster'));
guard(()=>show(invoke({action:'sample'}),true));
