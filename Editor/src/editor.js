import { EditorState, StateField, StateEffect, Compartment, Transaction } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection, ViewPlugin } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap, indentWithTab, isolateHistory, undo as undoCommand, redo as redoCommand, undoDepth, redoDepth } from '@codemirror/commands';
import { markdown, markdownKeymap } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { GFM } from '@lezer/markdown';
import { acceptCompletion, autocompletion, closeCompletion, startCompletion } from '@codemirror/autocomplete';

const root = document.getElementById('editor');
const toolbar = document.getElementById('toolbar');
let documentId = null, strings = {}, aiAvailable = false, aiBusy = false, aiLabel = null;
let activeLinkMetadata={id:null,documents:[]}, pendingLinkMetadata=null;
const localizedExtension = new Compartment();
let stableSelection = null, suppressedSelection = null, toolbarFrame = 0;
const pendingImages = new Map();
let aiPendingPlugin=null;
const fallback = {bold:'Bold', italic:'Italic', strikethrough:'Strikethrough', heading1:'Heading 1', heading2:'Heading 2', quote:'Quote', code:'Code', link:'Link', wikiAction:'Wiki', optimizeAction:'Optimize', editSource:'Edit source', importImage:'Import image', selectionToolbar:'Text formatting', busy:'Working…', imageAlt:'Image', table:'Table', linkOpenNote:'Notiz öffnen', linkOpenWiki:'Wiki-Seite öffnen', linkCreateMissing:'Nicht gefunden – mit ⌘-Klick erstellen', linkAmbiguous:'Mehrdeutiger Link', linkExternal:'Externen Link öffnen', linkSectionNotes:'Notizen', linkSectionWiki:'Wiki'};
const tr = key => strings['editor.' + key] || fallback[key] || key;
const post = message => window.webkit?.messageHandlers?.still?.postMessage(message);
// The caret overlay only adds a soft visual trail; CodeMirror remains the
// authority for selection, input, and the native caret.
const motionPreference=window.matchMedia('(prefers-reduced-motion: reduce)');
const reducedMotion=()=>motionPreference.matches||document.documentElement.dataset.reduceMotion==='true';
let caretMotion=null;
const caretMotionPlugin=ViewPlugin.fromClass(class {
  constructor(editor) {
    this.editor=editor;this.lastRect=null;this.animation=null;this.composing=false;this.generation=0;this.scrollTop=editor.scrollDOM.scrollTop;this.scrollLeft=editor.scrollDOM.scrollLeft;this.inputIntent=null;this.pendingTyping=false;
    this.overlay=document.createElement('div');this.overlay.className='still-smooth-caret';
    this.overlay.hidden=true;this.overlay.setAttribute('aria-hidden','true');document.body.append(this.overlay);
    caretMotion=this;this.measure(false);
  }
  snap() {
    this.generation++;
    this.animation?.cancel();this.animation=null;this.overlay.hidden=true;
    this.editor.dom.classList.remove('still-caret-moving');this.lastRect=null;this.pendingTyping=false;
  }
  update(update) {
    if(update.docChanged) {
      const before=update.startState.selection.main,after=update.state.selection.main;
      let shortEdit=true,changes=0;
      update.changes.iterChanges((from,to,fromNew,toNew,inserted)=>{
        changes++;if(to-from>8||inserted.length>8||inserted.lines>1||update.startState.doc.sliceString(from,to).includes('\n'))shortEdit=false;
      });
      const typed=update.transactions.some(transaction=>transaction.isUserEvent('input.type')||transaction.isUserEvent('delete.backward'))||this.inputIntent&&performance.now()-this.inputIntent<120;
      this.inputIntent=null;
      const eligible=typed&&shortEdit&&changes===1&&before.empty&&after.empty&&update.state.selection.ranges.length===1&&update.startState.doc.lineAt(before.head).number===update.state.doc.lineAt(after.head).number&&!this.composing&&!this.editor.composing&&!reducedMotion()&&this.editor.hasFocus;
      this.measure(eligible);
    } else if(update.focusChanged||update.selectionSet&&(!update.startState.selection.eq(update.state.selection)||!this.lastRect&&!this.pendingTyping)) this.measure(false);
    else if(update.viewportChanged||update.geometryChanged) this.measure('layout');
  }
  measure(animate) {
    const layout=animate==='layout';
    // A layout notification may arrive before the pending typing measurement.
    // That measurement already reads the final geometry; keep its visual intent.
    if(layout&&this.pendingTyping)return;
    if(animate===true)this.pendingTyping=true;
    if(!animate)this.snap();
    if(animate&&!layout&&this.lastRect&&this.overlay.hidden) {
      this.overlay.style.transform=`translate3d(${this.lastRect.left}px,${this.lastRect.top}px,0)`;
      this.overlay.style.height=`${this.lastRect.bottom-this.lastRect.top}px`;
      this.overlay.hidden=false;this.editor.dom.classList.add('still-caret-moving');
    }
    const state=this.editor.state,head=state.selection.main.head,generation=++this.generation;
    this.editor.requestMeasure({key:this,
      read:editor=>{
        const selection=editor.state.selection.main;
        if(this.generation!==generation||editor.state.doc!==state.doc||selection.head!==head||!editor.hasFocus||!selection.empty||editor.state.selection.ranges.length!==1)return null;
        const target=editor.coordsAtPos(selection.head);
        const visual=!this.overlay.hidden?this.overlay.getBoundingClientRect():null;
        return target?{target,visual}:null;
      },
      write:measurement=>{
        if(this.generation!==generation)return;
        this.pendingTyping=false;
        if(!measurement){this.snap();return;}
        const {target,visual}=measurement;
        const scrolled=this.scrollTop!==this.editor.scrollDOM.scrollTop||this.scrollLeft!==this.editor.scrollDOM.scrollLeft;
        this.scrollTop=this.editor.scrollDOM.scrollTop;this.scrollLeft=this.editor.scrollDOM.scrollLeft;
        if(layout) {
          const unchanged=this.lastRect&&Math.abs(this.lastRect.left-target.left)<.25&&Math.abs(this.lastRect.top-target.top)<.25;
          if(!unchanged||scrolled){this.snap();this.lastRect=target;}
          return;
        }
        const distance=visual?Math.abs(visual.left-target.left):0;
        const canMove=animate&&!scrolled&&!reducedMotion()&&!this.composing&&!this.editor.composing&&visual&&Math.abs(visual.top-target.top)<1&&distance<=96&&distance>.2;
        this.animation?.cancel();this.animation=null;
        this.lastRect=target;
        if(!canMove){this.overlay.hidden=true;this.editor.dom.classList.remove('still-caret-moving');return;}
        this.overlay.hidden=false;this.editor.dom.classList.add('still-caret-moving');
        this.overlay.style.height=`${target.bottom-target.top}px`;
        this.overlay.style.transform=`translate3d(${target.left}px,${target.top}px,0)`;
        const duration=Math.round(Math.min(198,184+Math.min(14,distance*.22)));
        const animation=this.overlay.animate([
          {transform:`translate3d(${visual.left}px,${target.top}px,0)`},
          {transform:`translate3d(${target.left}px,${target.top}px,0)`}
        ],{duration,easing:'cubic-bezier(.22,.61,.36,1)'});
        this.animation=animation;
        animation.finished.then(()=>{if(this.animation===animation){this.animation=null;this.overlay.hidden=true;this.editor.dom.classList.remove('still-caret-moving');}},()=>{});
      }
    });
  }
  destroy(){this.snap();this.overlay.remove();if(caretMotion===this)caretMotion=null;}
});
motionPreference.addEventListener('change',()=>{caretMotion?.snap();if(reducedMotion()){clearTypingReveal(view);if(toolbar.dataset.state==='closing')hideToolbar(true);}});

const foldEffect = StateEffect.define();
const focusEffect = StateEffect.define();
const linkMetadataEffect = StateEffect.define();
const setAIPendingEffect=StateEffect.define();
const clearAIPendingEffect=StateEffect.define();
const aiPendingField=StateField.define({
  create:()=>null,
  update(value,transaction) {
    let next=value;
    if(value&&transaction.docChanged) {
      const from=transaction.changes.mapPos(value.from,1);
      const to=value.from===value.to?from:transaction.changes.mapPos(value.to,-1);
      next=to>=from&&transaction.state.doc.sliceString(from,to)===value.text?{...value,from,to}:null;
    }
    for(const effect of transaction.effects) {
      if(effect.is(clearAIPendingEffect))next=null;
      else if(effect.is(setAIPendingEffect))next=effect.value;
    }
    return next;
  }
});
const linkMetadataField = StateField.define({
  create:()=>activeLinkMetadata.id===documentId?activeLinkMetadata:{id:documentId,documents:[]},
  update(value,transaction) {
    for(const effect of transaction.effects)if(effect.is(linkMetadataEffect))value=effect.value;
    return value;
  }
});
const focusField = StateField.define({
  create:()=>false,
  update(value,transaction) {
    for(const effect of transaction.effects)if(effect.is(focusEffect))value=effect.value;
    return value;
  }
});
const typingRevealEffect=StateEffect.define();
const clearTypingRevealEffect=StateEffect.define();
let nextTypingRevealId=0;
const typingRevealDelay=30,typingRevealFade=60;
// Display-only marks preserve their first input timestamp so recreated Markdown spans can resume the same fade.
const typingRevealField=StateField.define({
  create:()=>[],
  update(value,transaction) {
    if(transaction.effects.some(effect=>effect.is(clearTypingRevealEffect))||transaction.effects.some(effect=>effect.is(focusEffect)&&!effect.value)||transaction.selection&&!transaction.docChanged)return [];
    let next=value;
    for(const effect of transaction.effects)if(effect.is(typingRevealEffect)) {
      const {id,remove}=effect.value;
      next=remove?next.filter(range=>range.id!==id):next.map(range=>range.id===id?{...range,stage:'revealing'}:range);
    }
    if(transaction.docChanged) {
      const event=transaction.annotation(Transaction.userEvent),changes=[];
      transaction.changes.iterChanges((from,to,fromNew,toNew)=>changes.push({from,to,fromNew,toNew}));
      const ordinaryTyping=typeof event==='string'&&event.startsWith('input.type')&&!event.includes('compose');
      const selection=transaction.selection;
      if(!ordinaryTyping||event!=='input.type'||changes.length!==1||changes[0].from!==changes[0].to||!transaction.startState.selection.main.empty||!selection?.main.empty||transaction.state.selection.ranges.length!==1||!transaction.state.field(focusField)||caretMotion?.composing||caretMotion?.editor?.composing||reducedMotion())return [];
      const change=changes[0],text=transaction.state.doc.sliceString(change.fromNew,change.toNew);
      if(!text||text.includes('\n')||text.includes('\r'))return [];
      const mapped=next.flatMap(range=>{
        const changed=changes.some(item=>item.from<range.to&&item.to>range.from||item.from===item.to&&item.from>range.from&&item.from<range.to);
        if(changed)return [];
        const from=transaction.changes.mapPos(range.from,1),to=transaction.changes.mapPos(range.to,-1);
        return to>from?[{...range,from,to}]:[];
      });
      return [...mapped,{id:++nextTypingRevealId,from:change.fromNew,to:change.toNew,stage:'waiting',startedAt:performance.now()}];
    }
    return next;
  },
  provide:field=>EditorView.decorations.from(field,ranges=>Decoration.set(ranges.map(range=>Decoration.mark({class:`still-typed-glyph still-typed-glyph--${range.stage}`,attributes:{'data-still-reveal-id':String(range.id),...(range.stage==='revealing'?{style:`animation-delay:-${Math.max(0,performance.now()-range.startedAt-typingRevealDelay)}ms`}:{})}}).range(range.from,range.to)),true))
});
const typingRevealTimerPlugin=ViewPlugin.fromClass(class {
  constructor(view){this.view=view;this.timers=new Map();this.sync();}
  update(){this.sync();}
  sync() {
    const ranges=this.view.state.field(typingRevealField),active=new Set(ranges.map(range=>range.id));
    for(const [id,timer] of this.timers)if(!active.has(id)){clearTimeout(timer);this.timers.delete(id);}
    for(const range of ranges)if(!this.timers.has(range.id)) {
      const reveal=range.stage==='waiting',due=range.startedAt+typingRevealDelay+(reveal?0:typingRevealFade);
      const timer=setTimeout(()=>{
        this.timers.delete(range.id);
        if(this.view.state.field(typingRevealField).some(current=>current.id===range.id))this.view.dispatch({effects:typingRevealEffect.of(reveal?{id:range.id}:{id:range.id,remove:true})});
      },Math.max(0,due-performance.now()));
      this.timers.set(range.id,timer);
    }
  }
  destroy(){for(const timer of this.timers.values())clearTimeout(timer);this.timers.clear();}
});
function clearTypingReveal(editor) {
  if(editor.state.field(typingRevealField).length)editor.dispatch({effects:clearTypingRevealEffect.of(null)});
}
const foldField = StateField.define({
  create: () => new Map(),
  update(value, transaction) {
    let next=value;
    if(transaction.docChanged)next=new Map([...value].map(([pos,closed])=>[transaction.changes.mapPos(pos),closed]));
    for(const effect of transaction.effects)if(effect.is(foldEffect)){if(next===value)next=new Map(value);next.set(effect.value.pos,effect.value.closed);}
    return next;
  }
});
function selectionLines(state) {
  if(!state.field(focusField))return {key:'',ranges:[]};
  const ranges=state.selection.ranges.map(range=>{
    const first=state.doc.lineAt(range.from),last=state.doc.lineAt(range.to);
    return {first:first.number,last:last.number,from:first.from,to:last.to};
  });
  return {key:ranges.map(range=>`${range.first}:${range.last}`).join(','),ranges};
}
const intersectsSelectionLines = (activeLines, from, to) => activeLines.ranges.some(range=>from<=range.to&&to>=range.from);
function editSource(view, pos) {
  view.dispatch({selection: {anchor: pos}, scrollIntoView: true});
  view.focus();
}
class BulletWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const bullet=document.createElement('span');bullet.className='md-list-marker';bullet.textContent='•';return bullet; }
  ignoreEvent() { return false; }
}
class CheckboxWidget extends WidgetType {
  constructor(pos, checked) { super(); this.pos = pos; this.checked = checked; }
  eq(other) { return other.pos === this.pos && other.checked === this.checked; }
  toDOM(view) {
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox'; checkbox.checked = this.checked; checkbox.className = 'md-checkbox';
    checkbox.setAttribute('aria-label', this.checked ? '☑' : '☐');
    checkbox.addEventListener('mousedown', event => event.preventDefault());
    checkbox.addEventListener('click', event => {
      event.preventDefault();
      const actual = view.state.doc.sliceString(this.pos, this.pos + 3);
      if (/^\[[ xX]\]$/.test(actual)) view.dispatch({changes: {from:this.pos+1, to:this.pos+2, insert:actual[1] === ' ' ? 'x' : ' '}, annotations: Transaction.userEvent.of('input')});
    });
    return checkbox;
  }
  ignoreEvent() { return true; }
}
class ImageWidget extends WidgetType {
  constructor(from, url, alt) { super(); this.from=from; this.url=url; this.alt=alt; }
  eq(other) { return other.from===this.from && other.url===this.url && other.alt===this.alt; }
  toDOM(view) {
    const wrapper = document.createElement('span'); wrapper.className='md-image';
    const img = document.createElement('img'); img.alt=this.alt || tr('imageAlt');
    const local = this.url.match(/^(?:\.\/)?attachments\/([^/\\?#]+)$/);
    if (local) img.src='still-asset://image/' + encodeURIComponent(local[1]);
    else if (/^(data:image\/|blob:)/i.test(this.url)) img.src=this.url;
    img.addEventListener('load', () => view.requestMeasure());
    img.addEventListener('error', () => { wrapper.classList.add('image-missing'); wrapper.title=this.alt || tr('imageAlt'); view.requestMeasure(); });
    wrapper.append(img); wrapper.title=tr('editSource');
    wrapper.addEventListener('click', () => editSource(view,this.from)); return wrapper;
  }
  ignoreEvent() { return true; }
}
class TableWidget extends WidgetType {
  constructor(from, rows) { super(); this.from=from; this.rows=rows; }
  eq(other) { return other.from===this.from && JSON.stringify(other.rows)===JSON.stringify(this.rows); }
  toDOM(view) {
    const wrap=document.createElement('div'); wrap.className='md-table-wrap'; wrap.title=tr('editSource');
    const table=document.createElement('table'); table.setAttribute('aria-label',tr('table'));
    this.rows.forEach((row,index) => {
      const trElement=document.createElement('tr');
      row.forEach(text => { const cell=document.createElement(index===0?'th':'td'); cell.textContent=text.trim(); trElement.append(cell); });
      table.append(trElement);
    });
    wrap.append(table); wrap.addEventListener('click', () => editSource(view,this.from)); return wrap;
  }
  ignoreEvent() { return true; }
}
class DetailsWidget extends WidgetType {
  constructor(from, title, closed) { super(); this.from=from; this.title=title; this.closed=closed; }
  eq(other) { return other.from===this.from && other.title===this.title && other.closed===this.closed; }
  toDOM(view) {
    const element=document.createElement('div'); element.className='md-disclosure'+(this.closed?' is-closed':'');
    const button=document.createElement('button'); button.className='disclosure-toggle'; button.type='button';
    button.setAttribute('aria-expanded', String(!this.closed));
    const arrow=document.createElement('span'); arrow.className='disclosure-arrow'; arrow.textContent='›';
    const label=document.createElement('span'); label.textContent=this.title;
    button.append(arrow,label); button.addEventListener('mousedown',event=>event.preventDefault());
    button.addEventListener('click',()=>view.dispatch({effects:foldEffect.of({pos:Number(element.dataset.source),closed:button.getAttribute('aria-expanded')==='true'})}));
    element.dataset.source=String(this.from);
    const edit=document.createElement('button'); edit.className='disclosure-edit'; edit.type='button'; edit.textContent='↗'; edit.title=tr('editSource'); edit.setAttribute('aria-label',tr('editSource'));
    edit.addEventListener('click',()=>editSource(view,this.from));
    element.append(button,edit); return element;
  }
  updateDOM(element) {
    if(element.dataset.source!==String(this.from))return false;
    element.classList.toggle('is-closed',this.closed);
    element.querySelector('.disclosure-toggle').setAttribute('aria-expanded',String(!this.closed));
    element.querySelector('.disclosure-toggle span:last-child').textContent=this.title;
    return true;
  }
  ignoreEvent() { return true; }
}
function tableCells(line) { return line.trim().replace(/^\|/,'').replace(/\|$/,'').split(/(?<!\\)\|/).map(cell=>cell.replace(/\\\|/g,'|')); }
function sanitizeLinkDocuments(documents) {
  return (Array.isArray(documents)?documents:[]).filter(item=>item&&typeof item.id==='string'&&typeof item.title==='string'&&['notes','wiki'].includes(item.section)&&typeof item.target==='string')
    .map(item=>({id:item.id,title:item.title,section:item.section,folders:Array.isArray(item.folders)?item.folders.filter(folder=>typeof folder==='string'):[],target:item.target}));
}
function normalizeTarget(target) { return String(target??''); }
function foldText(value) { return String(value??'').normalize('NFD').replace(/\p{Diacritic}/gu,'').toLocaleLowerCase('en-US'); }
function hasInvalidEscape(value) { return /%(?![\da-f]{2})/i.test(value); }
function decodeTargetComponents(value) {
  if(hasInvalidEscape(value))return null;
  try{return String(value).split('/').map(component=>decodeURIComponent(component));}catch{return null;}
}
function decodeOnce(value) { const components=decodeTargetComponents(value);return components?.length===1?components[0]:null; }
function targetKey(value) { const components=decodeTargetComponents(value);return components?JSON.stringify(components.map(foldText)):null; }
function folderPathFor(document) {
  if(document.folders?.length)return document.folders.join('/');
  return normalizeTarget(document.target).split('/').slice(1,-1).join('/');
}
const linkResolverCache=new WeakMap();
const emptyLinkMetadata={id:null,documents:[]};
const missingWikiTarget={status:'missing',document:null},ambiguousWikiTarget={status:'ambiguous',document:null};
function addIndexValue(index,key,document) {
  if(key===null)return;
  let matches=index.get(key);
  if(!matches)index.set(key,matches=[]);
  matches.push(document);
}
function compileWikiResolver(metadata) {
  metadata=metadata&&typeof metadata==='object'?metadata:emptyLinkMetadata;
  let resolver=linkResolverCache.get(metadata);
  if(resolver)return resolver;
  const docs=metadata.documents||[],targets=new Map(),titles=new Map(),folders=new Map(),resolutionCache=new Map();
  for(const document of docs) {
    addIndexValue(targets,targetKey(normalizeTarget(document.target)),document);
    addIndexValue(titles,foldText(document.title),document);
    folders.set(document,foldText(folderPathFor(document)));
  }
  const source=docs.find(document=>document.id===metadata.id);
  const sourceFolder=source?folders.get(source):null;
  resolver=target=>{
    if(resolutionCache.has(target))return resolutionCache.get(target);
    let resolution;
    const normalized=targetKey(normalizeTarget(target));
    if(normalized===null)resolution=missingWikiTarget;
    else {
      const exact=targets.get(normalized)||[];
      if(exact.length===1)resolution={status:'resolved',document:exact[0]};
      else if(exact.length>1)resolution=ambiguousWikiTarget;
      else if(target.includes('/'))resolution=missingWikiTarget;
      else {
        const decoded=decodeOnce(target);
        if(decoded===null)resolution=missingWikiTarget;
        else {
          const matches=[],seen=new Set();
          for(const key of new Set([foldText(target),foldText(decoded)]))for(const document of titles.get(key)||[])if(!seen.has(document)){seen.add(document);matches.push(document);}
          if(matches.length===1)resolution={status:'resolved',document:matches[0]};
          else if(!matches.length)resolution=missingWikiTarget;
          else if(source) {
            const inFolder=matches.filter(document=>document.section===source.section&&folders.get(document)===sourceFolder);
            if(inFolder.length===1)resolution={status:'resolved',document:inFolder[0]};
            else {
              const inSection=matches.filter(document=>document.section===source.section);
              resolution=inSection.length===1?{status:'resolved',document:inSection[0]}:ambiguousWikiTarget;
            }
          } else resolution=ambiguousWikiTarget;
        }
      }
    }
    resolutionCache.set(target,resolution);
    return resolution;
  };
  linkResolverCache.set(metadata,resolver);
  return resolver;
}
function resolveWikiTarget(target,metadata) { return compileWikiResolver(metadata)(target); }

const documentAnalysisCache=new WeakMap();
const codeAndImageNames=new Set(['FencedCode','CodeBlock','InlineCode','Image']);
function mergeRanges(ranges) {
  ranges.sort((left,right)=>left[0]-right[0]||left[1]-right[1]);
  const merged=[];
  for(const [from,to] of ranges) {
    const previous=merged.at(-1);
    if(previous&&from<=previous[1])previous[1]=Math.max(previous[1],to);
    else merged.push([from,to]);
  }
  return merged;
}
function rangeIndex(ranges) {
  const sorted=[...ranges].sort((left,right)=>left[0]-right[0]||left[1]-right[1]),prefixEnds=[];
  let maximum=-1;
  for(const [,to] of sorted){maximum=Math.max(maximum,to);prefixEnds.push(maximum);}
  return {ranges:sorted,prefixEnds};
}
function rangeIndexContains(index,from,to) {
  let low=0,high=index.ranges.length;
  while(low<high){const middle=(low+high)>>1;if(index.ranges[middle][0]<=from)low=middle+1;else high=middle;}
  return low>0&&index.prefixEnds[low-1]>=to;
}
function rangeIndexOverlaps(index,from,to) {
  let low=0,high=index.ranges.length;
  while(low<high){const middle=(low+high)>>1;if(index.ranges[middle][0]<to)low=middle+1;else high=middle;}
  return low>0&&index.prefixEnds[low-1]>from;
}
function documentAnalysis(state,source) {
  const doc=state.doc,tree=syntaxTree(state);
  let byTree=documentAnalysisCache.get(doc);
  if(!byTree)documentAnalysisCache.set(doc,byTree=new WeakMap());
  const cached=byTree.get(tree);
  if(cached)return cached;
  const raw=source??doc.toString(),lines=[],codeLines=new Set(),fenceRanges=[],codeRanges=[];
  let fence=null,fenceStart=0;
  for(let number=1;number<=doc.lines;number++) {
    const line=doc.line(number),marker=line.text.match(/^ {0,3}(`{3,}|~{3,})/);
    const item={number,line,from:line.from,to:line.to,text:line.text,marker,heading:line.text.match(/^(#{1,6})\s+/),quote:line.text.match(/^(\s*>\s?)+/),rule:/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(line.text),tableSeparator:number<doc.lines&&/^\s*\|?\s*:?-{3,}:?\s*\|/.test(doc.line(number+1).text)};
    lines.push(item);
    if(fence) {
      codeLines.add(number);
      if(marker&&marker[1][0]===fence[0]&&marker[1].length>=fence.length){fenceRanges.push([fenceStart,line.to]);codeRanges.push([fenceStart,line.to]);fence=null;}
    } else if(marker){fence=marker[1];fenceStart=line.from;codeLines.add(number);}
    else if(/^ {4,}\S|^\t\S/.test(line.text))codeRanges.push([line.from,line.to]);
  }
  if(fence){fenceRanges.push([fenceStart,doc.length]);codeRanges.push([fenceStart,doc.length]);}
  const syntaxNodes=[];
  tree.iterate({enter(node){
    if(codeAndImageNames.has(node.name))codeRanges.push([node.from,node.to]);
    if(node.name==='FencedCode'||node.name==='CodeBlock')return false;
    let depth=0;for(let parent=node.node.parent;parent;parent=parent.parent)depth++;
    syntaxNodes.push({from:node.from,to:node.to,name:node.name,parentName:node.node.parent?.name,node:node.node,depth});
    if(node.name==='Image')return false;
  }});
  const details=[];
  const detailsPattern=/<details\b[^>]*>\s*<summary\b[^>]*>([^]*?)<\/summary>/gi;
  let match;
  while((match=detailsPattern.exec(raw))) {
    const from=match.index,openEnd=detailsPattern.lastIndex;
    let depth=1,closeStart=-1,closeEnd=-1;
    const tags=/<\/?details\b[^>]*>/gi;tags.lastIndex=openEnd;
    let tag;
    while((tag=tags.exec(raw))){depth+=/^<\//.test(tag[0])?-1:1;if(!depth){closeStart=tag.index;closeEnd=tags.lastIndex;break;}}
    details.push({from,openEnd,closeStart,closeEnd,match:match[0],title:match[1],insideFence:fenceRanges.some(([fromFence,toFence])=>from>=fromFence&&from<toFence)});
  }
  const analysis={doc,tree,raw,lines,codeLines,fenceRanges,codeAndImageRanges:mergeRanges(codeRanges),syntaxNodes,details,wikiLinks:null,markdownLinks:null};
  byTree.set(tree,analysis);
  return analysis;
}
function codeAndImageRanges(state) { return documentAnalysis(state).codeAndImageRanges; }
function escapedAt(source, position) {
  let slashes=0;for(let index=position-1;index>=0&&source[index]==='\\';index--)slashes++;
  return slashes%2===1;
}
function insideImageAlt(source, position) {
  let opener=source.lastIndexOf('![',position);
  while(opener>=0) {
    if(!escapedAt(source,opener)) {
      const closer=source.indexOf(']',opener+2);
      if(closer<0||position<closer)return true;
    }
    opener=source.lastIndexOf('![',opener-1);
  }
  return false;
}
function insideHtmlComment(source, position) {
  return source.lastIndexOf('<!--',position)>source.lastIndexOf('-->',position);
}
function wikiLinks(state,analysis) {
  const source=analysis?.raw??state.doc.toString();
  if(!source.includes('[[')){if(analysis)analysis.wikiLinks=[];return [];}
  analysis=analysis||documentAnalysis(state,source);
  if(analysis.wikiLinks)return analysis.wikiLinks;
  const excluded=analysis.codeAndImageRanges,links=[];
  const pattern=/\[\[([^\n]*?)\]\]/g;
  let match;
  while((match=pattern.exec(source))) {
    const from=match.index,to=pattern.lastIndex;
    if(escapedAt(source,from)||insideImageAlt(source,from)||insideHtmlComment(source,from)||containsPosition(excluded,from))continue;
    if(match[1].includes('[['))continue;
    const separator=match[1].indexOf('|');
    const rawTarget=(separator<0?match[1]:match[1].slice(0,separator)).trim();
    if(!rawTarget)continue;
    const alias=separator<0?'':match[1].slice(separator+1).trim();
    links.push({from,to,original:match[0],target:rawTarget,alias});
  }
  return analysis.wikiLinks=links;
}
function containsPosition(ranges,position) {
  let low=0,high=ranges.length;
  while(low<high){const middle=(low+high)>>1;if(ranges[middle][0]<=position)low=middle+1;else high=middle;}
  const range=ranges[low-1];return !!range&&position<range[1];
}
function wikiCompletionContext(state, position=state.selection.main.head) {
  if(!state.selection.main.empty)return null;
  const line=state.doc.lineAt(position),before=state.doc.sliceString(line.from,position),match=/\[\[([^\]\n]*)$/.exec(before);
  if(!match)return null;
  if(state.doc.sliceString(position,line.to).includes(']]'))return null;
  const from=line.from+match.index;
  const source=state.doc.toString();
  if(escapedAt(source,from)||insideImageAlt(source,from)||insideHtmlComment(source,from)||containsPosition(codeAndImageRanges(state),from))return null;
  if(match[1].includes('|'))return null;
  return {from,to:position,query:match[1]};
}
function completionApplyFor(document, allDocuments) {
  const sameTitle=allDocuments.filter(item=>foldText(item.title)===foldText(document.title)).length;
  const simpleTitle=!['[',']','|','%','/','\\','\n','\r'].some(character=>document.title.includes(character));
  const target=sameTitle===1&&simpleTitle?document.title:document.target;
  return (editor,_completion,from,to)=>{
    const insert=`[[${target}]]`;
    editor.dispatch({changes:{from,to,insert},selection:{anchor:from+insert.length},annotations:Transaction.userEvent.of('input.complete'),scrollIntoView:true});
    editor.focus();
  };
}
function wikiCompletionSource(context) {
  const candidate=wikiCompletionContext(context.state,context.pos);
  if(!candidate)return null;
  const metadata=context.state.field(linkMetadataField),documents=metadata?.documents||[];
  if(!documents.length)return null;
  const queryComponents=decodeTargetComponents(candidate.query);
  const query=foldText(queryComponents?queryComponents.join('/'):candidate.query);
  const filtered=documents.filter(document=>{
    const searchable=foldText([document.title,document.target,document.section,...document.folders].join(' '));
    return !query||searchable.includes(query);
  }).sort((left,right)=>left.title.localeCompare(right.title)||left.target.localeCompare(right.target));
  const options=filtered.slice(0,80).map(document=>{
    const section=tr(document.section==='wiki'?'linkSectionWiki':'linkSectionNotes');
    const folder=document.folders.join('/');
    return {label:document.title,detail:[section,folder].filter(Boolean).join(' · '),type:document.section==='wiki'?'namespace':'text',apply:completionApplyFor(document,documents)};
  });
  return options.length?{from:candidate.from,to:candidate.to,options,filter:false,update:(_result,_from,_to,nextContext)=>wikiCompletionSource(nextContext)}:null;
}
function allowedExternalUrl(value) {
  if(typeof value!=='string'||/[\u0000-\u001f\u007f]/.test(value))return null;
  try {
    const parsed=new URL(value.trim());
    if(!['http:','https:','mailto:'].includes(parsed.protocol))return null;
    if((parsed.protocol==='http:'||parsed.protocol==='https:')&&!parsed.hostname)return null;
    if(parsed.protocol==='mailto:'&&!parsed.pathname)return null;
    return parsed.href;
  } catch { return null; }
}
function markdownLinks(state) {
  const analysis=documentAnalysis(state);
  if(analysis.markdownLinks)return analysis.markdownLinks;
  const links=[],skipped=[];
  for(const item of analysis.syntaxNodes) {
    const {from,to,name,parentName,node}=item;
    if(skipped.some(([start,end])=>from>=start&&to<=end))continue;
    if(name==='InlineCode'){skipped.push([from,to]);continue;}
    if(name==='Link'||name==='Autolink') {
      const url=node.getChild('URL');
      if(url)links.push({from,to,url:state.doc.sliceString(url.from,url.to),kind:name});
      skipped.push([from,to]);
    } else if(name==='URL'&&!['Link','Autolink'].includes(parentName)) {
      links.push({from,to,url:state.doc.sliceString(from,to),kind:'URL'});
      skipped.push([from,to]);
    }
  }
  return analysis.markdownLinks=links;
}
function linkAtPosition(state,position) {
  const wiki=wikiLinks(state).find(link=>position>=link.from&&position<=link.to);
  if(wiki)return {kind:'wiki',link:wiki};
  const external=markdownLinks(state).find(link=>position>=link.from&&position<=link.to&&allowedExternalUrl(link.url));
  return external?{kind:'external',link:external,url:allowedExternalUrl(external.url)}:null;
}
function activateWikiLink(link) {
  if(documentId===null)return false;
  post({type:'openWikiLink',id:documentId,target:link.target,from:link.from,to:link.to,original:link.original});
  return true;
}
function activateExternalLink(url) {
  const safe=allowedExternalUrl(url);
  if(!safe||documentId===null)return false;
  post({type:'openExternalLink',id:documentId,url:safe});
  return true;
}
function activateAtPosition(position) {
  const found=linkAtPosition(view.state,position);
  if(!found)return false;
  return found.kind==='wiki'?activateWikiLink(found.link):activateExternalLink(found.url);
}
function activateRenderedLink(element) {
  if(!element||!element.dataset.stillLinkKind)return false;
  const from=Number(element.dataset.stillLinkFrom),to=Number(element.dataset.stillLinkTo);
  if(!Number.isInteger(from)||!Number.isInteger(to))return false;
  if(element.dataset.stillLinkKind==='wiki') {
    const link=wikiLinks(view.state).find(candidate=>candidate.from===from&&candidate.to===to);
    return link?activateWikiLink(link):false;
  }
  const link=markdownLinks(view.state).find(candidate=>candidate.from===from&&candidate.to===to);
  return link?activateExternalLink(link.url):false;
}
class WikiLinkWidget extends WidgetType {
  constructor(link,resolution,id) { super();this.link=link;this.resolution=resolution;this.id=id; }
  eq(other) { return this.link.from===other.link.from&&this.link.to===other.link.to&&this.link.original===other.link.original&&this.link.target===other.link.target&&this.link.alias===other.link.alias&&this.resolution.status===other.resolution.status&&this.resolution.document?.id===other.resolution.document?.id&&this.resolution.document?.title===other.resolution.document?.title&&this.resolution.document?.section===other.resolution.document?.section&&this.id===other.id; }
  toDOM(editor) {
    const element=document.createElement('span'),{link,resolution}=this;
    const targetTitle=resolution.document?.title||decodeOnce(link.target.split('/').at(-1));
    const label=link.alias||targetTitle;
    element.className='md-wiki-link'+(resolution.status==='resolved'?' is-resolved':resolution.status==='ambiguous'?' is-ambiguous':' is-unresolved');
    element.textContent=label;element.setAttribute('role','link');element.tabIndex=0;
    element.dataset.stillLinkKind='wiki';element.dataset.stillLinkFrom=String(link.from);element.dataset.stillLinkTo=String(link.to);
    const stateText=resolution.status==='resolved'?(resolution.document.section==='wiki'?tr('linkOpenWiki'):tr('linkOpenNote')):resolution.status==='ambiguous'?tr('linkAmbiguous'):tr('linkCreateMissing');
    element.title=`${stateText}: ${label}`;element.setAttribute('aria-label',`${stateText}: ${label}`);
    element.addEventListener('mousedown',event=>event.preventDefault());
    element.addEventListener('click',event=>{
      event.preventDefault();event.stopPropagation();
      if(event.metaKey||event.ctrlKey)activateRenderedLink(element);
      else editSource(editor,link.from);
    });
    element.addEventListener('keydown',event=>{
      if(event.key==='Enter'){event.preventDefault();event.stopPropagation();activateRenderedLink(element);}
    });
    return element;
  }
  ignoreEvent() { return true; }
}
function decorationsFor(state,analysis=documentAnalysis(state),activeLines=selectionLines(state)) {
  const ranges=[], occupied=[];
  const add=(from,to,decoration)=> { if(to>=from) ranges.push(decoration.range(from,to)); };
  const replace=(from,to,widget,block=false)=>add(from,to,Decoration.replace({widget,block}));
  const {raw,lines,codeLines,fenceRanges,syntaxNodes,details}=analysis;
  const wiki=wikiLinks(state,analysis),metadata=state.field(linkMetadataField);
  // HTML details remains real Markdown source. Nested sections are folded independently when expanded.
  for(const detail of details) {
    const {from,openEnd,closeStart,closeEnd,match,title}=detail;
    if(detail.insideFence || closeStart<0 || occupied.some(([a,b])=>from>=a&&from<b)) continue;
    const closed=state.field(foldField).get(from) ?? !/<details\b[^>]*\bopen\b/i.test(match);
    const active=intersectsSelectionLines(activeLines,from,openEnd) || (closed && intersectsSelectionLines(activeLines,openEnd,closeEnd));
    if(active) continue;
    // Block replacements must begin and end at line boundaries.
    const startLine=state.doc.lineAt(from), endLine=state.doc.lineAt(closed?closeEnd:openEnd);
    if(startLine.from!==from || endLine.to!==(closed?closeEnd:openEnd)) continue;
    replace(from,closed?closeEnd:openEnd,new DetailsWidget(from,title.replace(/<[^>]+>/g,'').trim(),closed),true);
    occupied.push([from,closed?closeEnd:openEnd]);
    if(!closed && !intersectsSelectionLines(activeLines,closeStart,closeEnd)) { replace(closeStart,closeEnd); occupied.push([closeStart,closeEnd]); }
  }
  for(let index=0;index<lines.length;index++) {
    const item=lines[index],{number:n,line,from,to,text}=item;
    if(occupied.some(([from,to])=>line.from>=from&&line.from<to)) continue;
    const active=intersectsSelectionLines(activeLines,line.from,line.to);
    if(codeLines.has(n)) {
      add(line.from,line.from,Decoration.line({class:'md-fenced'}));
      if(item.marker&&!active)replace(line.from,line.to);
      continue;
    }
    if(item.tableSeparator&&text.includes('|')) {
      let lastIndex=index+1;
      while(lastIndex+1<lines.length&&lines[lastIndex+1].text.includes('|')&&lines[lastIndex+1].text.trim())lastIndex++;
      const last=lines[lastIndex].line;
      if(!intersectsSelectionLines(activeLines,line.from,last.to)) {
        const rows=[tableCells(text)];for(let j=index+2;j<=lastIndex;j++)rows.push(tableCells(lines[j].text));
        replace(line.from,last.to,new TableWidget(line.from,rows),true);occupied.push([line.from,last.to]);index=lastIndex;continue;
      }
    }
    const heading=item.heading;
    if(heading) { add(line.from,line.from,Decoration.line({class:'md-heading md-h'+heading[1].length})); if(!active) replace(line.from,line.from+heading[0].length); }
    const quote=item.quote;
    if(quote) { add(line.from,line.from,Decoration.line({class:'md-quote'})); if(!active) replace(line.from,line.from+quote[0].length); }
    if(item.rule&&!active) { add(line.from,line.from,Decoration.line({class:'md-rule'})); replace(line.from,line.to); continue; }
  }
  const wikiRanges=[],blockOccupied=rangeIndex(occupied);
  for(const link of wiki) {
    if(rangeIndexContains(blockOccupied,link.from,link.to))continue;
    const active=intersectsSelectionLines(activeLines,link.from,link.to), resolution=resolveWikiTarget(link.target,metadata);
    wikiRanges.push([link.from,link.to]);occupied.push([link.from,link.to]);
    if(active) {
      add(link.from,link.to,Decoration.mark({class:'md-wikilink-source',attributes:{'data-still-link-kind':'wiki','data-still-link-from':String(link.from),'data-still-link-to':String(link.to)}}));
    } else replace(link.from,link.to,new WikiLinkWidget(link,resolution,metadata.id));
  }
  const occupiedIndex=rangeIndex(occupied),wikiIndex=rangeIndex(wikiRanges),classes={StrongEmphasis:'md-bold',Emphasis:'md-italic',Strikethrough:'md-strike',InlineCode:'md-code'};
  let skippedDepth=-1;
  for(const item of syntaxNodes) {
    const {from,to,name,node,parentName,depth}=item;
    if(skippedDepth>=0){if(depth>skippedDepth)continue;skippedDepth=-1;}
    if(rangeIndexContains(occupiedIndex,from,to)){skippedDepth=depth;continue;}
    if(name==='Link'&&rangeIndexOverlaps(wikiIndex,from,to)){skippedDepth=depth;continue;}
    const active=intersectsSelectionLines(activeLines,from,to);
    if(classes[name])add(from,to,Decoration.mark({class:classes[name]}));
    if(name==='Image') {
      if(!active) {
        const url=node.getChild('URL');
        const imageSource=state.doc.sliceString(from,to);
        const alt=imageSource.slice(2,imageSource.indexOf(']'));
        if(url)replace(from,to,new ImageWidget(from,state.doc.sliceString(url.from,url.to),alt));
      }
      continue;
    }
    const externalNode=name==='Link'||name==='Autolink'||name==='URL'&&!['Link','Autolink'].includes(parentName);
    if(externalNode) {
      const urlNode=name==='URL'?node:node.getChild('URL'),safeUrl=urlNode?allowedExternalUrl(state.doc.sliceString(urlNode.from,urlNode.to)):null;
      const labelMatch=state.doc.sliceString(from,to).match(/^\[([^\]]*)\]/),label=(labelMatch?.[1]||state.doc.sliceString(from,to)).replace(/[*_~`<>]/g,'');
      const attributes={'data-still-link-kind':'external','data-still-link-from':String(from),'data-still-link-to':String(to)};
      if(safeUrl)attributes['data-still-link-url']=safeUrl;
      if(safeUrl&&!active){attributes.role='link';attributes.tabindex='0';attributes['aria-label']=`${tr('linkExternal')}: ${label||safeUrl}`;}
      add(from,to,Decoration.mark({class:'md-link',attributes}));
      if(name==='Link'&&!active) {
        let close=node.firstChild;
        while(close && !(close.name==='LinkMark'&&state.doc.sliceString(close.from,close.to)===']'))close=close.nextSibling;
        if(close){replace(from,from+1);replace(close.from,to);}
      }
      if(name==='Autolink'&&!active&&safeUrl) {
        const first=node.firstChild,last=node.lastChild;
        if(first?.name==='LinkMark'&&state.doc.sliceString(first.from,first.to)==='<')replace(first.from,first.to);
        if(last?.name==='LinkMark'&&state.doc.sliceString(last.from,last.to)==='>')replace(last.from,last.to);
      }
      // Descendant emphasis still needs its own styles; LinkMark and URL are handled above.
    }
    if(name==='Escape'&&!active)replace(from,from+1);
    if(!active && ['EmphasisMark','StrikethroughMark','CodeMark'].includes(name))replace(from,to);
    if(name==='TaskMarker'&&!active)replace(from,to,new CheckboxWidget(from,state.doc.sliceString(from+1,from+2)!==' '));
    if(name==='ListMark'&&!active && /^[-*+]$/.test(state.doc.sliceString(from,to))) {
      const remainder=state.doc.sliceString(to,state.doc.lineAt(to).to);
      replace(from,to,/^\s+\[[ xX]\]/.test(remainder)?undefined:new BulletWidget());
    }
  }
  const pending=state.field(aiPendingField);
  if(pending&&pending.id===documentId&&pending.from>=0&&pending.to>pending.from&&state.doc.sliceString(pending.from,pending.to)===pending.text) {
    add(pending.from,pending.to,Decoration.mark({class:'still-ai-pending-text'}));
  }
  return Decoration.set(ranges,true);
}
function decorationState(state,active=selectionLines(state)) {
  const analysis=documentAnalysis(state);
  return {doc:state.doc,tree:analysis.tree,activeKey:active.key,decorations:decorationsFor(state,analysis,active)};
}
const decorationField=StateField.define({
  create:state=>decorationState(state),
  update(value,transaction) {
    const state=transaction.state,effectsChanged=transaction.effects.some(effect=>effect.is(foldEffect)||effect.is(focusEffect)||effect.is(linkMetadataEffect)||effect.is(setAIPendingEffect)||effect.is(clearAIPendingEffect));
    if(transaction.docChanged||effectsChanged||syntaxTree(state)!==value.tree)return decorationState(state);
    if(transaction.selection) {
      const active=selectionLines(state);
      return value.doc===state.doc&&value.activeKey===active.key?value:decorationState(state,active);
    }
    return value;
  },
  provide:field=>EditorView.decorations.from(field,value=>value.decorations)
});
const aiPendingViewPlugin=ViewPlugin.fromClass(class {
  constructor(editor) {
    this.editor=editor;this.pending=null;this.generation=0;
    this.overlay=document.createElement('div');this.overlay.className='still-ai-loader';this.overlay.hidden=true;
    this.overlay.setAttribute('role','status');this.overlay.setAttribute('aria-live','polite');this.overlay.setAttribute('aria-atomic','true');
    this.orbit=document.createElement('span');this.orbit.className='still-ai-loader-orbit';this.orbit.setAttribute('aria-hidden','true');
    this.core=document.createElement('span');this.core.className='still-ai-loader-core';this.core.setAttribute('aria-hidden','true');
    this.label=document.createElement('span');this.label.className='still-sr-only';this.overlay.append(this.orbit,this.core,this.label);document.body.append(this.overlay);
    this.onLayout=()=>this.measure();
    editor.scrollDOM.addEventListener('scroll',this.onLayout,{passive:true});
    window.addEventListener('scroll',this.onLayout,true);window.addEventListener('resize',this.onLayout);
    this.resizeObserver=typeof ResizeObserver==='undefined'?null:new ResizeObserver(this.onLayout);
    this.resizeObserver?.observe(editor.dom);this.resizeObserver?.observe(editor.scrollDOM);
    aiPendingPlugin=this;this.sync();
  }
  update(update) {
    const before=update.startState.field(aiPendingField),after=update.state.field(aiPendingField);
    if(before!==after||update.docChanged||update.viewportChanged||update.geometryChanged)this.sync();
  }
  sync() {
    const pending=this.editor.state.field(aiPendingField);
    const active=pending&&pending.id===documentId&&pending.to>pending.from?pending:null;
    this.editor.dom.classList.toggle('still-ai-pending',!!active);
    this.pending=active;
    if(!active){this.overlay.hidden=true;this.generation++;return;}
    const status=aiLabel||tr('busy');this.label.textContent=status;this.overlay.setAttribute('aria-label',status);
    this.measure();
  }
  measure() {
    const pending=this.pending;if(!pending)return;
    const editor=this.editor,doc=editor.state.doc,generation=++this.generation;
    editor.requestMeasure({key:this,
      read:current=>{
        if(this.generation!==generation||this.pending!==pending||current.state.doc!==doc||current.state.field(aiPendingField)!==pending)return null;
        let fragments=[];
        try {
          const start=current.domAtPos(pending.from,1),end=current.domAtPos(pending.to,-1),range=document.createRange();
          range.setStart(start.node,start.offset);range.setEnd(end.node,end.offset);
          fragments=[...range.getClientRects()].filter(rect=>rect.width||rect.height);
        } catch {}
        if(!fragments.length) {
          const start=current.coordsAtPos(pending.from),end=current.coordsAtPos(pending.to);
          if(start&&end)fragments=[{left:Math.min(start.left,end.left),right:Math.max(start.right,end.right),top:Math.min(start.top,end.top),bottom:Math.max(start.bottom,end.bottom)}];
        }
        if(!fragments.length)return null;
        const left=Math.min(...fragments.map(rect=>rect.left)),right=Math.max(...fragments.map(rect=>rect.right));
        const top=Math.min(...fragments.map(rect=>rect.top)),bottom=Math.max(...fragments.map(rect=>rect.bottom));
        const bounds=current.dom.getBoundingClientRect();
        if(bottom<Math.max(0,bounds.top)||top>window.innerHeight||right<0||left>window.innerWidth)return null;
        return {left,right,top,bottom};
      },
      write:rect=>{
        if(this.generation!==generation||this.pending!==pending)return;
        if(!rect){this.overlay.hidden=true;return;}
        const size=this.overlay.offsetWidth||24,x=(rect.left+rect.right-size)/2,y=(rect.top+rect.bottom-size)/2;
        this.overlay.style.transform=`translate3d(${Math.round(x)}px,${Math.round(y)}px,0)`;this.overlay.hidden=false;
      }
    });
  }
  destroy() {
    this.pending=null;this.generation++;this.editor.dom.classList.remove('still-ai-pending');
    this.editor.scrollDOM.removeEventListener('scroll',this.onLayout);window.removeEventListener('scroll',this.onLayout,true);window.removeEventListener('resize',this.onLayout);
    this.resizeObserver?.disconnect();this.overlay.remove();if(aiPendingPlugin===this)aiPendingPlugin=null;
  }
});
function selectedSnapshot() {
  const {from,to}=view.state.selection.main;
  if(from===to || documentId===null) return null;
  return {id:documentId,from,to,text:view.state.doc.sliceString(from,to)};
}
function snapshotValid(selection) {
  return selection && selection.id===documentId && selection.from>=0 && selection.to<=view.state.doc.length && view.state.doc.sliceString(selection.from,selection.to)===selection.text;
}
function applyFormat(kind, supplied) {
  const cursor=view.state.selection.main;
  const selection=supplied || selectedSnapshot() || {id:documentId,from:cursor.from,to:cursor.to,text:''};
  if(!snapshotValid(selection)) return false;
  const {from,to,text}=selection;
  let insert, anchor, head;
  const wrapper={bold:'**',italic:'*',strikethrough:'~~',code:'`'}[kind];
  if(wrapper) {
    if(text.startsWith(wrapper)&&text.endsWith(wrapper)&&text.length>2*wrapper.length) {insert=text.slice(wrapper.length,-wrapper.length);anchor=from;head=from+insert.length;}
    else if(view.state.doc.sliceString(Math.max(0,from-wrapper.length),from)===wrapper && view.state.doc.sliceString(to,to+wrapper.length)===wrapper) {
      view.dispatch({changes:[{from:from-wrapper.length,to:from,insert:''},{from:to,to:to+wrapper.length,insert:''}],selection:{anchor:from-wrapper.length,head:to-wrapper.length},annotations:Transaction.userEvent.of('input')}); view.focus(); return true;
    } else {insert=wrapper+text+wrapper;anchor=from+wrapper.length;head=anchor+text.length;}
  } else if(kind==='link') { insert='['+text+'](https://)'; anchor=from+text.length+3; head=anchor+8; }
  else {
    const first=view.state.doc.lineAt(from),last=view.state.doc.lineAt(to);
    const prefix={heading1:'# ',heading2:'## ',quote:'> '}[kind]; if(!prefix)return false;
    const original=view.state.doc.sliceString(first.from,last.to);
    const lines=original.split('\n'); const already=lines.every(line=>line.startsWith(prefix));
    const updated=lines.map(line=>already?line.slice(prefix.length):prefix+line.replace(kind==='quote'?/^>\s?/:/^#{1,6}\s+/,''));
    insert=updated.join('\n');
    view.dispatch({changes:{from:first.from,to:last.to,insert},selection:{anchor:first.from,head:first.from+insert.length},annotations:Transaction.userEvent.of('input')}); view.focus(); return true;
  }
  view.dispatch({changes:{from,to,insert},selection:{anchor,head},annotations:Transaction.userEvent.of('input')}); view.focus(); return true;
}
function action(kind) {
  const selection=stableSelection;
  if(!snapshotValid(selection))return;
  if(kind==='wiki'||kind==='optimize') {
    if(aiAvailable&&!aiBusy) {
      suppressedSelection=`${selection.id}:${selection.from}:${selection.to}`;
      hideToolbar(true);aiBusy=true;aiLabel=tr('busy');makeToolbar();
      view.dispatch({effects:setAIPendingEffect.of({...selection,kind})});
      post({type:'action',action:kind,...selection});
    }
  } else applyFormat(kind,selection);
}
function makeToolbar() {
  toolbar.replaceChildren(); toolbar.setAttribute('aria-label',tr('selectionToolbar'));
  const items=[['bold','B'],['italic','I'],['strikethrough','S'],null,['heading1','H1'],['heading2','H2'],['quote','❞'],['code','‹›'],null,['link','↗'],null,['wiki','Wiki'],['optimize','✧']];
  for(const item of items) {
    if(!item) { const separator=document.createElement('span');separator.className='toolbar-separator';separator.setAttribute('role','separator');toolbar.append(separator);continue; }
    const [kind,icon]=item; const button=document.createElement('button');button.type='button';button.dataset.action=kind;
    const key=kind==='wiki'?'wikiAction':kind==='optimize'?'optimizeAction':kind;
    button.textContent=kind==='wiki'?tr(key):kind==='optimize'?'✧ '+tr(key):icon; button.title=tr(key);button.setAttribute('aria-label',tr(key));
    if(kind==='bold'||kind==='italic'||kind==='strikethrough')button.classList.add('toolbar-'+kind);
    if(kind==='wiki'||kind==='optimize') {button.disabled=!aiAvailable||aiBusy; if(aiBusy&&kind==='optimize'){button.classList.add('is-busy');button.title=tr('busy');}}
    button.addEventListener('mousedown',event=>event.preventDefault());
    button.addEventListener('click',()=>action(kind));toolbar.append(button);
  }
}
let toolbarExitTimer=0;
function showToolbar() {
  const entering=toolbar.hidden;
  if(entering)toolbar.dataset.entering='true';
  else if(toolbar.dataset.state==='closing')toolbar.dataset.entering='false';
  clearTimeout(toolbarExitTimer);toolbar.hidden=false;toolbar.inert=false;
  toolbar.setAttribute('aria-hidden','false');toolbar.dataset.state='open';
}
function hideToolbar(immediate=false) {
  stableSelection=null;toolbar.inert=true;toolbar.setAttribute('aria-hidden','true');
  if(toolbar.hidden||toolbar.dataset.state==='closing'&&!immediate)return;
  clearTimeout(toolbarExitTimer);
  if(immediate||reducedMotion()){toolbar.hidden=true;toolbar.dataset.state='closed';return;}
  toolbar.dataset.entering='false';toolbar.dataset.state='closing';
  toolbarExitTimer=setTimeout(()=>{toolbar.hidden=true;toolbar.dataset.state='closed';},130);
}
function scheduleToolbar() {if(!toolbarFrame)toolbarFrame=requestAnimationFrame(()=>{toolbarFrame=0;updateToolbar();});}
function updateToolbar() {
  const selection=selectedSnapshot();
  if(aiBusy){hideToolbar(true);return;}
  if(!selection || suppressedSelection===`${selection.id}:${selection.from}:${selection.to}` || (!view.hasFocus&&!toolbar.contains(document.activeElement))) {hideToolbar();return;}
  stableSelection=selection; showToolbar();
  const a=view.coordsAtPos(selection.from),b=view.coordsAtPos(selection.to),head=view.coordsAtPos(view.state.selection.main.head);
  if(!a||!b||!head){hideToolbar(true);return;}
  const rect=view.dom.getBoundingClientRect();
  if(b.bottom<Math.max(0,rect.top)||a.top>window.innerHeight){hideToolbar(true);return;}
  const width=toolbar.offsetWidth,height=toolbar.offsetHeight;
  const margin=Math.max(18,Math.ceil(width*.055/2)+4);
  const center=Math.abs(a.top-b.top)<1?(a.left+b.left)/2:head.left;
  toolbar.style.left=Math.max(margin,Math.min(window.innerWidth-width-margin,center-width/2))+'px';
  toolbar.style.top=Math.max(8,Math.min(window.innerHeight-height-8,head.top-height-10>=8?head.top-height-10:head.bottom+10))+'px';
}
async function sendImage(file, position) {
  if(!file?.type.startsWith('image/')||documentId===null)return;
  const requestId=crypto.randomUUID(); const id=documentId;
  const range=position??view.state.selection.main;
  pendingImages.set(requestId,{id,from:range.from,to:range.to,original:view.state.doc.sliceString(range.from,range.to)});
  const base64=await new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(',')[1]);reader.onerror=reject;reader.readAsDataURL(file);});
  if(documentId===id && pendingImages.has(requestId))post({type:'importImage',id,requestId,filename:file.name || 'image.png',mime:file.type,base64});
}
const view=new EditorView({parent:root,state:createState('')});
function scheduleWikiCompletion() {
  if(!wikiCompletionContext(view.state))return;
  const doc=view.state.doc,position=view.state.selection.main.head;
  queueMicrotask(()=>{if(view.state.doc===doc&&view.state.selection.main.head===position&&wikiCompletionContext(view.state))startCompletion(view);});
}
function localizedExtensions() {
  return [placeholder(strings['editor.emptyBody']||'Start writing…'),EditorView.contentAttributes.of({'aria-label':strings['editor.emptyBody']||'Document',spellcheck:'true',autocapitalize:'sentences'})];
}
function createState(doc) {
  return EditorState.create({doc,extensions:[
    history(),drawSelection(),caretMotionPlugin,markdown({extensions:[GFM]}),focusField,typingRevealField,foldField,aiPendingField,linkMetadataField,decorationField,typingRevealTimerPlugin,aiPendingViewPlugin,
    EditorView.lineWrapping,localizedExtension.of(localizedExtensions()),
    autocompletion({override:[wikiCompletionSource],maxRenderedOptions:12,interactionDelay:0}),
    keymap.of([
      {key:'Enter',run:()=>{const target=document.activeElement?.closest?.('[data-still-link-kind]');return target?activateRenderedLink(target):false;}},
      {key:'Mod-Enter',run:()=>activateAtPosition(view.state.selection.main.head)},
      {key:'Mod-b',run:()=>{caretMotion?.snap();post({type:'toggleSidebar'});return true;}},{key:'Mod-i',run:()=>applyFormat('italic')},{key:'Mod-k',run:()=>applyFormat('link')},
      {key:'Escape',run:()=>{const current=selectedSnapshot();suppressedSelection=current?`${current.id}:${current.from}:${current.to}`:null;hideToolbar();return true;}},
      {key:'Tab',run:()=>acceptCompletion(view)},
      ...historyKeymap,...markdownKeymap,...defaultKeymap,indentWithTab
    ]),
    EditorView.updateListener.of(update=>{
      if(update.docChanged) {
        for(const [key,pending] of pendingImages) {
          const from=update.changes.mapPos(pending.from,1),to=pending.from===pending.to?from:update.changes.mapPos(pending.to,-1);
          if(to<from)pendingImages.delete(key);else pendingImages.set(key,{...pending,from,to});
        }
        post({type:'change',id:documentId,markdown:update.state.doc.toString()});
      }
      if(update.selectionSet) suppressedSelection=null;
      if(update.docChanged||update.selectionSet||update.viewportChanged||update.focusChanged||update.geometryChanged)scheduleToolbar();
      if(update.docChanged)scheduleWikiCompletion();
      if(update.transactions.some(transaction=>transaction.effects.some(effect=>effect.is(linkMetadataEffect))))scheduleWikiCompletion();
    }),
    EditorView.domEventHandlers({
      beforeinput(event) {if(caretMotion&&['insertText','deleteContentBackward'].includes(event.inputType)&&!event.isComposing)caretMotion.inputIntent=performance.now();return false;},
      pointerdown(event,editor) {
        caretMotion?.snap();
        clearTypingReveal(editor);
        if(event.metaKey||event.ctrlKey) {
          const rendered=event.target.closest?.('[data-still-link-kind]');
          if(rendered&&!rendered.classList.contains('md-wiki-link')) {
            if(activateRenderedLink(rendered)){event.preventDefault();event.stopPropagation();return true;}
          } else if(!rendered) {
            const position=editor.posAtCoords({x:event.clientX,y:event.clientY},false);
            if(position!==null&&activateAtPosition(position)){event.preventDefault();event.stopPropagation();return true;}
          }
        }
        return false;
      },
      keydown(event,editor) {
        if(event.key==='Enter') {
          clearTypingReveal(editor);
          const rendered=event.target.closest?.('[data-still-link-kind]');
          const activated=rendered?activateRenderedLink(rendered):event.metaKey||event.ctrlKey?activateAtPosition(editor.state.selection.main.head):false;
          if(activated){event.preventDefault();return true;}
        }
        if(event.metaKey||event.ctrlKey||event.altKey||event.key.length!==1&&event.key!=='Backspace') {caretMotion?.snap();clearTypingReveal(editor);}
        else if(event.key==='Backspace')clearTypingReveal(editor);
        return false;
      },
      compositionstart(_event,editor) {if(caretMotion){caretMotion.composing=true;caretMotion.snap();}clearTypingReveal(editor);return false;},
      compositionend() {if(caretMotion){caretMotion.composing=false;caretMotion.snap();caretMotion.measure(false);}return false;},
      focus(event,editor) {editor.dispatch({effects:focusEffect.of(true)});post({type:'focus',id:documentId,focused:true});return false;},
      blur(event,editor) {
        editor.dispatch({effects:focusEffect.of(false)});
        post({type:'focus',id:documentId,focused:false});
        caretMotion?.snap();if(!toolbar.contains(event.relatedTarget))hideToolbar(true);
        return false;
      },
      paste(event) {
        const file=[...(event.clipboardData?.files||[])].find(file=>file.type.startsWith('image/'));
        if(file){event.preventDefault();sendImage(file);return true;}return false;
      },
      drop(event,editor) {
        const files=[...(event.dataTransfer?.files||[])].filter(file=>file.type.startsWith('image/'));
        if(!files.length)return false;
        event.preventDefault();const pos=editor.posAtCoords({x:event.clientX,y:event.clientY})??editor.state.selection.main.head;
        files.forEach(file=>sendImage(file,{from:pos,to:pos}));return true;
      },
      dragover(event) { if(event.dataTransfer?.types.includes('Files')){event.preventDefault();return true;}return false; },
      scroll() {caretMotion?.snap();scheduleToolbar();return false;}
    })
  ]});
}
window.addEventListener('resize',()=>{caretMotion?.snap();scheduleToolbar();});
window.addEventListener('scroll',()=>{caretMotion?.snap();scheduleToolbar();},true);
window.addEventListener('blur',()=>{caretMotion?.snap();clearTypingReveal(view);hideToolbar(true);});
window.stillEditor={
  setDocument({id,markdown:source='',strings:localized={},theme='light',reduceMotion=false,aiAvailable:available=false}) {
    const sameDocument=id===documentId;
    const sameSource=sameDocument&&source===view.state.doc.toString();
    const localizationChanged=Object.keys(strings).length!==Object.keys(localized).length||Object.keys(strings).some(key=>strings[key]!==localized[key]);
    const availabilityChanged=aiAvailable!==available;
    strings=localized;aiAvailable=available;
    this.setAppearance({theme,reduceMotion});
    if(sameSource) {
      if(localizationChanged)view.dispatch({effects:[localizedExtension.reconfigure(localizedExtensions()),linkMetadataEffect.of(activeLinkMetadata)]});
      if(localizationChanged||availabilityChanged){makeToolbar();scheduleToolbar();}
      return;
    }
    const oldSelection=view.state.selection.main;
    if(!sameDocument)closeCompletion(view);
    if(!sameDocument) {
      activeLinkMetadata=pendingLinkMetadata?.id===id?pendingLinkMetadata:{id,documents:[]};
      pendingLinkMetadata=null;
    }
    documentId=id;stableSelection=null;suppressedSelection=null;pendingImages.clear();caretMotion?.snap();hideToolbar(true);
    if(!sameDocument){aiBusy=false;aiLabel=null;}
    let state=createState(source);
    if(sameDocument)state=state.update({selection:{anchor:Math.min(oldSelection.anchor,source.length),head:Math.min(oldSelection.head,source.length)}}).state;
    view.setState(state);
    if(view.hasFocus)view.dispatch({effects:focusEffect.of(true)});
    post({type:'focus',id:documentId,focused:view.hasFocus});
    if(!sameDocument)view.scrollDOM.scrollTop=0;
    makeToolbar();
  },
  setLinkDocuments({id,documents=[]}) {
    if(typeof id!=='string')return;
    const safeDocuments=sanitizeLinkDocuments(documents);
    const snapshot={id,documents:safeDocuments};
    if(id!==documentId){pendingLinkMetadata=snapshot;return;}
    activeLinkMetadata=snapshot;
    view.dispatch({effects:linkMetadataEffect.of(snapshot)});
    scheduleWikiCompletion();
  },
  setAIState({busy=false,label}) {
    const nextLabel=busy?(label??null):null;
    const clearPending=!busy&&view.state.field(aiPendingField)!==null;
    if(aiBusy===busy&&aiLabel===nextLabel&&!clearPending)return;
    aiBusy=busy;aiLabel=nextLabel;
    if(clearPending)view.dispatch({effects:clearAIPendingEffect.of(null)});
    if(busy)hideToolbar(true);
    makeToolbar();aiPendingPlugin?.sync();
    if(label){const button=toolbar.querySelector('[data-action="optimize"]');button.title=label;}
    scheduleToolbar();
  },
  replaceSelection({id,from,to,original,replacement}) {
    if(id!==documentId||typeof replacement!=='string'||!Number.isInteger(from)||!Number.isInteger(to)||from<0||to<from||to>view.state.doc.length||view.state.doc.sliceString(from,to)!==original)return false;
    view.dispatch({changes:{from,to,insert:replacement},selection:{anchor:from+replacement.length},annotations:[Transaction.userEvent.of('input'),isolateHistory.of('full')],scrollIntoView:true});view.focus();return true;
  },
  insertMarkdown(text) {
    if(typeof text!=='string')return;
    const {from,to}=view.state.selection.main;
    view.dispatch({changes:{from,to,insert:text},selection:{anchor:from+text.length},annotations:Transaction.userEvent.of('input'),scrollIntoView:true});view.focus();
  },
  insertImage({url,alt,requestId,id}) {
    if(typeof url!=='string'||!/^attachments\/[^/\\?#]+$/.test(url))return false;
    let selection;
    if(requestId){selection=pendingImages.get(requestId);pendingImages.delete(requestId);if(!selection||selection.id!==documentId||id!==documentId||selection.from<0||selection.to<selection.from||selection.to>view.state.doc.length||view.state.doc.sliceString(selection.from,selection.to)!==selection.original)return false;}
    else {if(id!==undefined&&id!==documentId)return false;selection=view.state.selection.main;}
    const {from,to}=selection;const insert=`![${(alt||tr('imageAlt')).replace(/[\]\n]/g,'')}](${url})`;
    view.dispatch({changes:{from,to,insert},selection:{anchor:from+insert.length},annotations:Transaction.userEvent.of('input'),scrollIntoView:true});view.focus();return true;
  },
  setAppearance({theme,reduceMotion}) {
    const nextTheme=theme==='dark'?'dark':'light',nextMotion=String(!!reduceMotion);
    if(document.documentElement.dataset.theme!==nextTheme||document.documentElement.dataset.reduceMotion!==nextMotion)caretMotion?.snap();
    document.documentElement.dataset.theme=nextTheme;document.documentElement.dataset.reduceMotion=nextMotion;
    if(reducedMotion())clearTypingReveal(view);
    if(reducedMotion()&&toolbar.dataset.state==='closing')hideToolbar(true);
  },
  undo(){view.focus();return undoCommand(view);},
  redo(){view.focus();return redoCommand(view);},
  historyState(){return {canUndo:undoDepth(view.state)>0,canRedo:redoDepth(view.state)>0};},
  focus(){view.focus();},
  getMarkdown(){return view.state.doc.toString();}
};
makeToolbar();post({type:'ready'});
