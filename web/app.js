import {request} from './core.js';
const $=id=>document.getElementById(id);
let state,selected,original;
const collapsed=new Set();
const modes = {
 'src-over': '正常', 'multiply': '正片叠底', 'screen': '滤色',
 'overlay': '叠加', 'darken': '变暗', 'lighten': '变亮',
 'color-dodge': '颜色减淡', 'color-burn': '颜色加深',
 'hard-light': '强光', 'soft-light': '柔光', 'difference': '差值',
 'color': '颜色', 'luminosity': '明度', 'hue': '色相',
 'saturation': '饱和度', 'plus': '相加',
 'dst-in': '保留底图与上层重合的部分',
 'dst-out': '用上层擦除底图',
 'src-atop': '将上层限制在底图范围内',
 'dst-atop': '将底图限制在上层范围内'
};
for(const mode of Object.keys(modes)){const option=document.createElement('option');option.value='svg:'+mode;option.textContent=modes[mode];$('op').append(option)}
function invoke(query){const result=JSON.parse(request(JSON.stringify(query)));if(!result.ok)throw Error(result.error);return result}
function status(message) {
 const text = message || state?.warning || '';
 const translations = {
  'Invalid document: ': '文档无法处理：',
  'Unsupported feature: ': '该功能暂不支持：',
  'Only 8-bit PNG input is currently supported': '此文档包含超出当前编辑范围的位深，现显示原始预览，可保存原文件。',
  'ICC-profiled PNG requires color management': '此文档包含 ICC 色彩配置，现显示原始预览，可保存原文件。',
  'Unknown composite operation: ': '暂不支持的混合方式：',
  'Unknown layer element: ': '暂不支持的图层类型：',
  'Expected an integer coordinate or layer index': '位置和图层编号必须是范围内的整数。',
  'Open a document first': '请先打开一个文档。',
  'Layer tree exceeds depth limit': '图层嵌套层数超过限制。',
  'Rendering buffer budget exceeded': '此文档合成时需要的内存超过限制。',
  'Decoded layer pixels exceed 128 MiB budget': '图层展开后的像素数据超过 128 MiB 限制。',
  'Image dimensions exceed limits': '图像尺寸超过限制。',
  'Invalid layer path': '所选图层不存在，请重新选择。'
 };
 let translated = text;
 for (const [source, target] of Object.entries(translations)) {
  translated = translated.replace(source, target);
 }
 $('status').textContent = translated;
}
function choose(node){selected=node;for(const id of ['name','x','y','opacity','op'])$(id).value=node[id];$('visible').checked=node.visible;$('opacityValue').value=Math.round(node.opacity*100)+'%';drawTree()}
function drawTree(){const container=$('tree');container.replaceChildren();let count=0;function visit(nodes,depth){for(const node of nodes){count++;const button=document.createElement('button');button.className='layer'+(selected&&JSON.stringify(node.path)===JSON.stringify(selected.path)?' active':'')+(!node.visible?' hidden':'');button.style.paddingLeft=8+depth*16+'px';button.textContent=(node.kind==='group'?'▾  ':'◻  ')+node.name;button.onclick=()=>choose(node);container.append(button);if(node.kind==='group'){const toggle=document.createElement('button');toggle.className='fold';toggle.textContent=collapsed.has(JSON.stringify(node.path))?'展开图层组':'收起图层组';toggle.onclick=()=>{const key=JSON.stringify(node.path);if(collapsed.has(key))collapsed.delete(key);else collapsed.add(key);drawTree()};container.append(toggle)}if(!collapsed.has(JSON.stringify(node.path)))visit(node.children,depth+1)}}visit(state.tree,0);$('count').textContent=count}
function show(result,reset=false){state=result;if(reset){original=result.original||result.png;$('original').checked=false;selected=null;collapsed.clear()}const nodes=[];function walk(list){for(const n of list){nodes.push(n);walk(n.children)}}walk(result.tree);selected=nodes.find(n=>selected&&JSON.stringify(n.path)===JSON.stringify(selected.path))||nodes[0];$('title').textContent=result.name==='Untitled'?'未命名文档':result.name;$('dimensions').textContent=result.width+' × '+result.height+' 像素';$('canvas').src='data:image/png;base64,'+($('original').checked?original:state.png);if(selected)choose(selected);else drawTree();for(const control of $('properties').elements)control.disabled=result.editable===false;status(result.warning||'')}
function guard(action){try{action();status('')}catch(e){status(e.message)}}
$('sample').onclick=()=>guard(()=>show(invoke({action:'sample'}),true));
$('open').onclick=()=>$('file').click();
$('file').onchange=async()=>{const file=$('file').files[0];if(!file)return;try{if(file.size>32*1024*1024)throw Error('网页最多可打开 32 MiB 的文件。');const bytes=new Uint8Array(await file.arrayBuffer());let binary='';for(let i=0;i<bytes.length;i+=16384)binary+=String.fromCharCode(...bytes.subarray(i,i+16384));show(invoke({action:'open',data:btoa(binary)}),true);status('')}catch(e){status(e.message)}finally{$('file').value=''}};
$('properties').onsubmit=e=>{e.preventDefault();guard(()=>{if(!selected)return;show(invoke({action:'edit',path:selected.path,name:$('name').value,x:Number($('x').value),y:Number($('y').value),opacity:Number($('opacity').value),visible:$('visible').checked,op:$('op').value}))})};
$('opacity').oninput=()=>$('opacityValue').value=Math.round(Number($('opacity').value)*100)+'%';
$('original').onchange=()=>{$('canvas').src='data:image/png;base64,'+($('original').checked?original:state.png)};
function download(base64,name,type){const bytes=Uint8Array.from(atob(base64),c=>c.charCodeAt(0));const url=URL.createObjectURL(new Blob([bytes],{type}));const link=document.createElement('a');link.href=url;link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
$('png').onclick=()=>guard(()=>download(state.png,'composite.png','image/png'));
$('save').onclick=()=>guard(()=>download(invoke({action:'export'}).data,'edited.ora','image/openraster'));
guard(()=>show(invoke({action:'sample'}),true));
