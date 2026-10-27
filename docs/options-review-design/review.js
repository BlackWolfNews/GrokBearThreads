// Local design prototype only. No runner connection or reply is sent.
const options = [
  {id:'A',title:'Auto account',file:'1-auto-account.png',note:'Keep today’s account menu and add Auto at the top.'},
  {id:'B',title:'One picker',file:'2-one-picker.png',note:'Put the account choice inside the model picker.'},
  {id:'C',title:'Account pools',file:'3-pools.png',note:'Choose a pool of logins for each kind of work.'},
  {id:'D',title:'Moving mid-thread',file:'4-moving-mid-thread.png',note:'Reference: how a move could appear with any option.',reference:true},
];
const imagePath = o => `../account-picker-design/${o.file}`;
const layout = document.body.dataset.layout;
const panel = layout === 'panel';
const state = {pair:[0,1], mode:'pair', zoom:layout === 'detail'?'actual':'fit', picked:1, notes:{B:'Keep the account override easy to find.'}};
const esc = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
document.body.innerHTML = `<header class="intro"><div><h1>${panel?'B. Compare beside the conversation':layout==='detail'?'A. Read both at 100%':'A. A separate comparison window'}</h1><p>${panel?'The thread stays in view. Each image has less room.':'Resize it, compare a pair, then zoom and scroll when you need to read the details.'}</p></div><nav><a href="index.html">Design notes</a><a href="${panel?'1-window.html':'2-panel.html'}">${panel?'See A':'See B'}</a><span class="hint">Design mockup</span></nav></header>
<main class="window ${panel?'panel':''}"><div class="titlebar"><div class="lights"><i></i><i></i><i></i></div><span class="title">${panel?'threadbear / Design comparison':'Account picker'}<span class="sub">${panel?'':'4 images · Auto account and model picker ideas'}</span></span><a class="right" href="${panel?'1-window.html':'index.html#card'}">${panel?'Open in a window ↗':'Back to thread ↗'}</a></div>
${panel?`<div class="shell"><aside class="sidebar"><p>New thread　⌘N</p><p>Needs you</p><div class="thread">Design comparison<br><small>Waiting on you</small></div><p>Running</p><p>Auto account and model picker ideas</p><p>Inbox</p></aside><div class="conversation"><p class="bubble">Let me compare the options and leave notes on each.</p><p>I’ve kept all four images together. D shows the mid-thread move that could go with any of the first three.</p><section class="request"><h2>Account picker</h2><p>4 images · Waiting for your review</p><div class="miniatures">${options.map(o=>`<img src="${imagePath(o)}" alt="${o.title}">`).join('')}</div><button class="chosen" disabled>Review open →</button></section><p class="hint">Your reply will appear here once you send it.</p><div class="composer">Message<small>+　Opus 5.5 · High　 Full access</small></div></div>`:''}
<section class="review"><div class="toolbar"><div class="seg"><button data-mode="pair">2-up</button><button data-mode="grid">Grid</button><button data-mode="single">Single</button></div><span class="hint">Compare any two images</span><div class="seg right"><button data-zoom="fit">Fit</button><button data-zoom="actual">100%</button></div></div><div class="canvases"></div><div class="filmstrip"></div><footer class="reply"><div class="summary"></div><button id="later">Review later</button><button class="primary" id="send">Send reply</button></footer></section>${panel?'</div>':''}</main>
<div class="dialog" hidden><section><h2>Reply preview</h2><pre></pre><p>This prototype keeps everything in this page. The built feature would send this reply back to the thread.</p><button id="close">Back to review</button></section></div>`;
const review = document.querySelector('.review');
function draw(){
  review.className=`review ${state.zoom} ${state.mode==='grid'?'grid':state.mode==='single'?'single':''}`;
  document.querySelectorAll('[data-mode]').forEach(b=>b.classList.toggle('on',b.dataset.mode===state.mode));
  document.querySelectorAll('[data-zoom]').forEach(b=>b.classList.toggle('on',b.dataset.zoom===state.zoom));
  const shown=state.mode==='grid'?[0,1,2,3]:state.mode==='single'?[state.pair[0]]:state.pair;
  document.querySelector('.canvases').innerHTML=shown.map((idx,slot)=>{
    const o=options[idx];
    return `<article class="option ${state.picked===idx?'selected':''}" data-option="${idx}"><header class="option-head"><select aria-label="${slot?'Right':'Left'} image" data-slot="${slot}">${options.map((v,i)=>`<option value="${i}" ${i===idx?'selected':''}>${v.id}. ${v.title}${v.reference?' · Reference':''}</option>`).join('')}</select>${o.reference?'<span class="hint right">Reference</span>':`<button data-pick="${idx}" class="${state.picked===idx?'chosen':''}">${state.picked===idx?'✓ Picked':'Pick this'}</button>`}</header><div class="viewport" tabindex="0" aria-label="${o.id}. ${o.title}, scroll to inspect"><img src="${imagePath(o)}" alt="${o.id}. ${o.title}"></div><div class="note"><p>${o.note}</p><label for="notes-${o.id}">Notes on ${o.id}</label><textarea id="notes-${o.id}" data-note="${o.id}" placeholder="What would you keep or change?">${esc(state.notes[o.id]||'')}</textarea></div></article>`;
  }).join('');
  document.querySelector('.filmstrip').innerHTML=options.map((o,i)=>`<button class="thumb ${shown.includes(i)?'viewing':''}" data-view="${i}" title="Show ${o.id} on the ${state.mode==='single'?'screen':'right'}"><img src="${imagePath(o)}" alt=""><span><strong>${o.id}. ${o.title}</strong><small>${o.reference?'Reference':state.picked===i?'✓ Picked':state.notes[o.id]?'Has notes':'Option'}</small></span></button>`).join('')+'<span class="hint">Click to change the right image.<br>← → to browse · Enter to view alone</span>';
  updateSummary();
}
function updateSummary(){
  const count=Object.values(state.notes).filter(x=>x.trim()).length;
  document.querySelector('.summary').innerHTML=`${state.picked===null?'No option picked':`${options[state.picked].id}. ${options[state.picked].title} picked`}${count?` · Notes on ${count} image${count===1?'':'s'}`:''}<br><small>Nothing is sent until you choose Send reply.</small>`;
  document.querySelector('#send').disabled=state.picked===null&&!count;
}
document.addEventListener('click',event=>{
  const b=event.target.closest('button');if(!b)return;
  if(b.dataset.mode){state.mode=b.dataset.mode;draw();}
  if(b.dataset.zoom){state.zoom=b.dataset.zoom;draw();}
  if(b.dataset.pick!==undefined){const i=+b.dataset.pick;state.picked=state.picked===i?null:i;draw();}
  if(b.dataset.view!==undefined){state.pair[state.mode==='single'?0:1]=+b.dataset.view;if(state.pair[0]===state.pair[1])state.pair[0]=(state.pair[1]+3)%4;draw();}
  if(b.id==='send'){
    const lines=state.picked===null?[]:[`Picked ${options[state.picked].id}. ${options[state.picked].title}.`];
    for(const o of options)if(state.notes[o.id]?.trim())lines.push(`Notes on ${o.id}: ${state.notes[o.id].trim()}`);
    document.querySelector('.dialog pre').textContent=lines.join('\n\n');document.querySelector('.dialog').hidden=false;document.querySelector('#close').focus();
  }
  if(b.id==='close'){document.querySelector('.dialog').hidden=true;document.querySelector('#send').focus();}
  if(b.id==='later'){document.querySelector('.summary').textContent='Review kept open in this page. You can return when you’re ready.';}
});
document.addEventListener('change',event=>{if(event.target.dataset.slot!==undefined){const slot=+event.target.dataset.slot;const idx=+event.target.value;const other=slot?0:1;if(state.pair[other]===idx)state.pair[other]=state.pair[slot];state.pair[slot]=idx;draw();}});
document.addEventListener('input',event=>{if(event.target.dataset.note){state.notes[event.target.dataset.note]=event.target.value;updateSummary();}});
document.addEventListener('keydown',event=>{
  if(event.target.matches('textarea,input,select,button,a'))return;
  if(['ArrowLeft','ArrowRight'].includes(event.key)){event.preventDefault();const slot=state.mode==='single'?0:1;state.pair[slot]=(state.pair[slot]+(event.key==='ArrowRight'?1:3))%4;if(state.pair[0]===state.pair[1])state.pair[1-slot]=(state.pair[slot]+3)%4;draw();}
  if(event.key==='Enter'){state.mode=state.mode==='single'?'pair':'single';draw();}
  if(event.key==='Escape'){document.querySelector('.dialog').hidden=true;}
});
draw();
if(layout==='detail')document.querySelectorAll('.viewport').forEach(v=>{v.scrollLeft=370;v.scrollTop=0;});
