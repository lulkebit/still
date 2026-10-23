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
const fallback = {bold:'Bold', italic:'Italic', strikethrough:'Strikethrough', heading1:'Heading 1', heading2:'Heading 2', quote:'Quote', code:'Code', link:'Link', wikiAction:'Wiki', optimizeAction:'Optimize', editSource:'Edit source', importImage:'Import image', selectionToolbar:'Text formatting', busy:'Working…', imageAlt:'Image', table:'Table', linkOpenNote:'Notiz öffnen', linkOpenWiki:'Wiki-Seite öffnen', linkCreateMissing:'Nicht gefunden – mit ⌘-Klick erstellen', linkAmbiguous:'Mehrdeutiger Link', linkExternal:'Externen Link öffnen', linkSectionNotes:'Notizen', linkSectionWiki:'Wiki'};
const tr = key => strings['editor.' + key] || fallback[key] || key;
const post = message => window.webkit?.messageHandlers?.still?.postMessage(message);
// Only a short visual caret overlay moves. CodeMirror selection, input and its
// normal cursor/blink stay authoritative; every non-typing interaction snaps.
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
        const canMove=animate&&!scrolled&&!reducedMotion()&&!this.composing&&!this.editor.composing&&visual&&Math.abs(visual.top-target.top)<1&&Math.abs(visual.left-target.left)<=96&&Math.abs(visual.left-target.left)>.2;
        this.animation?.cancel();this.animation=null;
        this.lastRect=target;
        if(!canMove){this.overlay.hidden=true;this.editor.dom.classList.remove('still-caret-moving');return;}
        this.overlay.hidden=false;this.editor.dom.classList.add('still-caret-moving');
        this.overlay.style.height=`${target.bottom-target.top}px`;
        this.overlay.style.transform=`translate3d(${target.left}px,${target.top}px,0)`;
        const animation=this.overlay.animate([
          {transform:`translate3d(${visual.left}px,${target.top}px,0)`},
          {transform:`translate3d(${target.left}px,${target.top}px,0)`}
        ],{duration:115,easing:'cubic-bezier(.22,.61,.36,1)'});
        this.animation=animation;
        animation.finished.then(()=>{if(this.animation===animation){this.animation=null;this.overlay.hidden=true;this.editor.dom.classList.remove('still-caret-moving');}},()=>{});
      }
    });
  }
  destroy(){this.snap();this.overlay.remove();if(caretMotion===this)caretMotion=null;}
});
motionPreference.addEventListener('change',()=>{caretMotion?.snap();if(reducedMotion()&&toolbar.dataset.state==='closing')hideToolbar(true);});

const foldEffect = StateEffect.define();
const focusEffect = StateEffect.define();
const linkMetadataEffect = StateEffect.define();
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
const foldField = StateField.define({
  create: () => new Map(),
  update(value, transaction) {
    let next = new Map([...value].map(([pos, closed]) => [transaction.changes.mapPos(pos), closed]));
    for (const effect of transaction.effects) if (effect.is(foldEffect)) next.set(effect.value.pos, effect.value.closed);
    return next;
  }
});
const intersectsSelectionLines = (state, from, to) => state.field(focusField) && state.selection.ranges.some(range => {
  const first = state.doc.lineAt(range.from).from;
  const last = state.doc.lineAt(range.to).to;
  return from <= last && to >= first;
});
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
function resolveWikiTarget(target, metadata) {
  const normalized=targetKey(normalizeTarget(target));
  if(normalized===null)return {status:'missing',document:null};
  const docs=metadata?.documents||[];
  const exact=docs.filter(document=>targetKey(normalizeTarget(document.target))===normalized);
  if(exact.length===1)return {status:'resolved',document:exact[0]};
  if(exact.length>1)return {status:'ambiguous',document:null};
  if(target.includes('/'))return {status:'missing',document:null};
  const decoded=decodeOnce(target);
  if(decoded===null)return {status:'missing',document:null};
  const matches=docs.filter(document=>foldText(document.title)===foldText(target)||foldText(document.title)===foldText(decoded));
  if(matches.length===1)return {status:'resolved',document:matches[0]};
  if(!matches.length)return {status:'missing',document:null};
  const source=docs.find(document=>document.id===metadata.id);
  if(source) {
    const folder=foldText(folderPathFor(source)),inFolder=matches.filter(document=>document.section===source.section&&foldText(folderPathFor(document))===folder);
    if(inFolder.length===1)return {status:'resolved',document:inFolder[0]};
    const inSection=matches.filter(document=>document.section===source.section);
    if(inSection.length===1)return {status:'resolved',document:inSection[0]};
  }
  return {status:'ambiguous',document:null};
}
function codeAndImageRanges(state) {
  const ranges=[];
  let fence=null,fenceStart=0;
  for(let number=1;number<=state.doc.lines;number++) {
    const line=state.doc.line(number),marker=line.text.match(/^ {0,3}(`{3,}|~{3,})/);
    if(fence) {
      if(marker&&marker[1][0]===fence[0]&&marker[1].length>=fence.length){ranges.push([fenceStart,line.to]);fence=null;}
    } else if(marker){fence=marker[1];fenceStart=line.from;}
    else if(/^ {4,}\S|^\t\S/.test(line.text))ranges.push([line.from,line.to]);
  }
  if(fence)ranges.push([fenceStart,state.doc.length]);
  syntaxTree(state).iterate({enter(node){
    if(['FencedCode','CodeBlock','InlineCode','Image'].includes(node.name)) {ranges.push([node.from,node.to]);return false;}
  }});
  return ranges;
}
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
function wikiLinks(state) {
  const source=state.doc.toString(), excluded=codeAndImageRanges(state), links=[];
  const pattern=/\[\[([^\n]*?)\]\]/g;
  let match;
  while((match=pattern.exec(source))) {
    const from=match.index,to=pattern.lastIndex;
    if(escapedAt(source,from)||insideImageAlt(source,from)||insideHtmlComment(source,from)||excluded.some(([a,b])=>from>=a&&from<b))continue;
    if(match[1].includes('[['))continue;
    const separator=match[1].indexOf('|');
    const rawTarget=(separator<0?match[1]:match[1].slice(0,separator)).trim();
    if(!rawTarget)continue;
    const alias=separator<0?'':match[1].slice(separator+1).trim();
    links.push({from,to,original:match[0],target:rawTarget,alias});
  }
  return links;
}
function wikiCompletionContext(state, position=state.selection.main.head) {
  if(!state.selection.main.empty)return null;
  const line=state.doc.lineAt(position),before=state.doc.sliceString(line.from,position),match=/\[\[([^\]\n]*)$/.exec(before);
  if(!match)return null;
  if(state.doc.sliceString(position,line.to).includes(']]'))return null;
  const from=line.from+match.index;
  const source=state.doc.toString();
  if(escapedAt(source,from)||insideImageAlt(source,from)||insideHtmlComment(source,from)||codeAndImageRanges(state).some(([a,b])=>from>=a&&from<b))return null;
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
  const links=[];
  syntaxTree(state).iterate({enter(node){
    if(node.name==='Image'||node.name==='FencedCode'||node.name==='CodeBlock'||node.name==='InlineCode')return false;
    if(node.name==='Link'||node.name==='Autolink') {
      const url=node.node.getChild('URL');
      if(url)links.push({from:node.from,to:node.to,url:state.doc.sliceString(url.from,url.to),kind:node.name});
      return false;
    }
    if(node.name==='URL'&&!['Link','Autolink'].includes(node.node.parent?.name)) {
      links.push({from:node.from,to:node.to,url:state.doc.sliceString(node.from,node.to),kind:'URL'});
      return false;
    }
  }});
  return links;
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
function decorationsFor(state) {
  const ranges=[], occupied=[];
  const add=(from,to,decoration)=> { if(to>=from) ranges.push(decoration.range(from,to)); };
  const replace=(from,to,widget,block=false)=>add(from,to,Decoration.replace({widget,block}));
  const raw=state.doc.toString(), wiki=wikiLinks(state), metadata=state.field(linkMetadataField);
  const codeLines=new Set(); const codeRanges=[]; let fence=null, fenceStart=0;
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n), marker=line.text.match(/^ {0,3}(`{3,}|~{3,})/);
    if(fence) {
      codeLines.add(n);
      if(marker&&marker[1][0]===fence[0]&&marker[1].length>=fence.length) {codeRanges.push([fenceStart,line.to]);fence=null;}
    } else if(marker) {fence=marker[1];fenceStart=line.from;codeLines.add(n);}
  }
  if(fence)codeRanges.push([fenceStart,state.doc.length]);
  // HTML details remains real Markdown source. Nested sections are folded independently when expanded.
  const detailsPattern=/<details\b[^>]*>\s*<summary\b[^>]*>([^]*?)<\/summary>/gi;
  let match;
  while ((match=detailsPattern.exec(raw))) {
    const from=match.index, openEnd=detailsPattern.lastIndex;
    let depth=1, closeStart=-1, closeEnd=-1;
    const tags=/<\/?details\b[^>]*>/gi; tags.lastIndex=openEnd;
    let tag; while((tag=tags.exec(raw))) { depth+=/^<\//.test(tag[0])?-1:1; if(!depth){closeStart=tag.index;closeEnd=tags.lastIndex;break;} }
    if(codeRanges.some(([a,b])=>from>=a&&from<b) || closeStart<0 || occupied.some(([a,b])=>from>=a&&from<b)) continue;
    const closed=state.field(foldField).get(from) ?? !/<details\b[^>]*\bopen\b/i.test(match[0]);
    const active=intersectsSelectionLines(state,from,openEnd) || (closed && intersectsSelectionLines(state,openEnd,closeEnd));
    if(active) continue;
    // Block replacements must begin and end at line boundaries.
    const startLine=state.doc.lineAt(from), endLine=state.doc.lineAt(closed?closeEnd:openEnd);
    if(startLine.from!==from || endLine.to!==(closed?closeEnd:openEnd)) continue;
    replace(from,closed?closeEnd:openEnd,new DetailsWidget(from,match[1].replace(/<[^>]+>/g,'').trim(),closed),true);
    occupied.push([from,closed?closeEnd:openEnd]);
    if(!closed && !intersectsSelectionLines(state,closeStart,closeEnd)) { replace(closeStart,closeEnd); occupied.push([closeStart,closeEnd]); }
  }
  for(let n=1;n<=state.doc.lines;n++) {
    const line=state.doc.line(n), text=line.text;
    if(occupied.some(([from,to])=>line.from>=from&&line.from<to)) continue;
    const active=intersectsSelectionLines(state,line.from,line.to);
    if(codeLines.has(n)) {
      add(line.from,line.from,Decoration.line({class:'md-fenced'}));
      if(/^ {0,3}(`{3,}|~{3,})/.test(text)&&!active)replace(line.from,line.to);
      continue;
    }
    if(n<state.doc.lines && text.includes('|') && /^\s*\|?\s*:?-{3,}:?\s*\|/.test(state.doc.line(n+1).text)) {
      let end=n+1; while(end<state.doc.lines && state.doc.line(end+1).text.includes('|') && state.doc.line(end+1).text.trim()) end++;
      const last=state.doc.line(end);
      if(!intersectsSelectionLines(state,line.from,last.to)) {
        const rows=[tableCells(text)]; for(let j=n+2;j<=end;j++) rows.push(tableCells(state.doc.line(j).text));
        replace(line.from,last.to,new TableWidget(line.from,rows),true); occupied.push([line.from,last.to]); n=end; continue;
      }
    }
    const heading=text.match(/^(#{1,6})\s+/);
    if(heading) { add(line.from,line.from,Decoration.line({class:'md-heading md-h'+heading[1].length})); if(!active) replace(line.from,line.from+heading[0].length); }
    const quote=text.match(/^(\s*>\s?)+/);
    if(quote) { add(line.from,line.from,Decoration.line({class:'md-quote'})); if(!active) replace(line.from,line.from+quote[0].length); }
    if(/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(text) && !active) { add(line.from,line.from,Decoration.line({class:'md-rule'})); replace(line.from,line.to); continue; }
  }
  const wikiRanges=[];
  for(const link of wiki) {
    if(occupied.some(([from,to])=>link.from>=from&&link.to<=to))continue;
    const active=intersectsSelectionLines(state,link.from,link.to), resolution=resolveWikiTarget(link.target,metadata);
    wikiRanges.push([link.from,link.to]);occupied.push([link.from,link.to]);
    if(active) {
      add(link.from,link.to,Decoration.mark({class:'md-wikilink-source',attributes:{'data-still-link-kind':'wiki','data-still-link-from':String(link.from),'data-still-link-to':String(link.to)}}));
    } else replace(link.from,link.to,new WikiLinkWidget(link,resolution,metadata.id));
  }
  syntaxTree(state).iterate({enter(node) {
    const {from,to,name}=node;
    if(occupied.some(([a,b])=>from>=a&&to<=b))return false;
    if(name==='FencedCode'||name==='CodeBlock')return false;
    if(name==='Link'&&wikiRanges.some(([a,b])=>from<b&&to>a))return false;
    const active=intersectsSelectionLines(state,from,to);
    const classes={StrongEmphasis:'md-bold',Emphasis:'md-italic',Strikethrough:'md-strike',InlineCode:'md-code'};
    if(classes[name])add(from,to,Decoration.mark({class:classes[name]}));
    if(name==='Image') {
      if(!active) {
        const url=node.node.getChild('URL');
        const imageSource=state.doc.sliceString(from,to);
        const alt=imageSource.slice(2,imageSource.indexOf(']'));
        if(url)replace(from,to,new ImageWidget(from,state.doc.sliceString(url.from,url.to),alt));
      }
      return false;
    }
    const parentName=node.node.parent?.name;
    const externalNode=name==='Link'||name==='Autolink'||name==='URL'&&!['Link','Autolink'].includes(parentName);
    if(externalNode) {
      const urlNode=name==='URL'?node.node:node.node.getChild('URL'),safeUrl=urlNode?allowedExternalUrl(state.doc.sliceString(urlNode.from,urlNode.to)):null;
      const labelMatch=state.doc.sliceString(from,to).match(/^\[([^\]]*)\]/),label=(labelMatch?.[1]||state.doc.sliceString(from,to)).replace(/[*_~`<>]/g,'');
      const attributes={'data-still-link-kind':'external','data-still-link-from':String(from),'data-still-link-to':String(to)};
      if(safeUrl)attributes['data-still-link-url']=safeUrl;
      if(safeUrl&&!active){attributes.role='link';attributes.tabindex='0';attributes['aria-label']=`${tr('linkExternal')}: ${label||safeUrl}`;}
      add(from,to,Decoration.mark({class:'md-link',attributes}));
      if(name==='Link'&&!active) {
        let close=node.node.firstChild;
        while(close && !(close.name==='LinkMark'&&state.doc.sliceString(close.from,close.to)===']'))close=close.nextSibling;
        if(close){replace(from,from+1);replace(close.from,to);}
      }
      if(name==='Autolink'&&!active&&safeUrl) {
        const first=node.node.firstChild,last=node.node.lastChild;
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
  }});
  return Decoration.set(ranges,true);
}
const decorationField=StateField.define({
  create:decorationsFor,
  update(value,transaction) { return transaction.docChanged || transaction.selection || transaction.effects.some(effect=>effect.is(foldEffect)||effect.is(focusEffect)||effect.is(linkMetadataEffect)) || syntaxTree(transaction.state)!==syntaxTree(transaction.startState) ? decorationsFor(transaction.state) : value; },
  provide:field=>EditorView.decorations.from(field)
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
    if(aiAvailable && !aiBusy) post({type:'action',action:kind,...selection});
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
    history(),drawSelection(),caretMotionPlugin,markdown({extensions:[GFM]}),focusField,foldField,linkMetadataField,decorationField,
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
          const rendered=event.target.closest?.('[data-still-link-kind]');
          const activated=rendered?activateRenderedLink(rendered):event.metaKey||event.ctrlKey?activateAtPosition(editor.state.selection.main.head):false;
          if(activated){event.preventDefault();return true;}
        }
        if(event.metaKey||event.ctrlKey||event.altKey||event.key.length!==1&&event.key!=='Backspace')caretMotion?.snap();
        return false;
      },
      compositionstart() {if(caretMotion){caretMotion.composing=true;caretMotion.snap();}return false;},
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
window.addEventListener('blur',()=>{caretMotion?.snap();hideToolbar(true);});
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
    const nextLabel=label??null;
    if(aiBusy===busy&&aiLabel===nextLabel)return;
    aiBusy=busy;aiLabel=nextLabel;makeToolbar();
    if(label){const button=toolbar.querySelector('[data-action="optimize"]');button.title=label;}
    scheduleToolbar();
  },
  replaceSelection({id,from,to,original,replacement}) {
    if(id!==documentId||typeof replacement!=='string'||!Number.isInteger(from)||!Number.isInteger(to)||from<0||to<from||to>view.state.doc.length||view.state.doc.sliceString(from,to)!==original)return false;
    view.dispatch({changes:{from,to,insert:replacement},selection:{anchor:from,head:from+replacement.length},annotations:[Transaction.userEvent.of('input'),isolateHistory.of('full')]});view.focus();return true;
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
    if(reducedMotion()&&toolbar.dataset.state==='closing')hideToolbar(true);
  },
  undo(){view.focus();return undoCommand(view);},
  redo(){view.focus();return redoCommand(view);},
  historyState(){return {canUndo:undoDepth(view.state)>0,canRedo:redoDepth(view.state)>0};},
  focus(){view.focus();},
  getMarkdown(){return view.state.doc.toString();}
};
makeToolbar();post({type:'ready'});
