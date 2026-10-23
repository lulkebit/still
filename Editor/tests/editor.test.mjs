import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { chromium, webkit } from '@playwright/test';

const distribution=new URL('../../Sources/Still/Resources/Editor/',import.meta.url);
const server=createServer(async(req,res)=>{
  const name=req.url==='/'?'index.html':req.url.slice(1);
  if(!['index.html','editor.js','editor.css'].includes(name)){res.writeHead(404).end();return;}
  res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html');
  res.end(await readFile(new URL(name,distribution)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browserName=process.env.STILL_TEST_BROWSER||'chromium';
const browserType={chromium,webkit}[browserName];
if(!browserType)throw new Error(`Unsupported STILL_TEST_BROWSER: ${browserName}. Choose chromium or webkit.`);
const browser=await browserType.launch({headless:true});
console.log(`Browser: ${browserName} ${browser.version()}`);
const page=await browser.newPage({viewport:{width:1000,height:900}});
const errors=[];page.on('pageerror',error=>errors.push(error.message));
await page.addInitScript(()=>{window.messages=[];window.webkit={messageHandlers:{still:{postMessage:message=>window.messages.push(message)}}};});
await page.goto(`http://127.0.0.1:${server.address().port}`);
await page.waitForFunction(()=>!!window.stillEditor);
const source=()=>page.evaluate(()=>window.stillEditor.getMarkdown());
const load=async(markdown,id='doc-1',aiAvailable=true)=>{
  await page.evaluate(({markdown,id,aiAvailable})=>window.stillEditor.setDocument({id,markdown,aiAvailable,strings:{'editor.optimizeAction':'Optimieren'}}),{markdown,id,aiAvailable});
  await page.locator('.cm-content').evaluate(content=>{content.cmTile.root.view.dispatch({selection:{anchor:0}});window.stillEditor.focus();});
};
// CodeMirror's own DOM association permits exact UTF-16 selections without shipping a test API.
const select=async(from,to=from)=>{
  await page.locator('.cm-content').evaluate((content,{from,to})=>{const view=content.cmTile.root.view;view.dispatch({selection:{anchor:from,head:to},scrollIntoView:true});view.focus();},{from,to});
  await page.waitForTimeout(50);
};
const waitForCompletionLabels=expected=>page.waitForFunction(values=>{
  const actual=[...document.querySelectorAll('.cm-tooltip-autocomplete .cm-completionLabel')].map(label=>label.textContent);
  return actual.length===values.length&&actual.every((label,index)=>label===values[index]);
},expected);
const tests=[];
function test(name,body){tests.push([name,body]);}
test('source fidelity, active syntax and live styled typography',async()=>{
  const markdown='Intro\n\n## Heading\n\n**bold** and *italic*, ~~strike~~, `code`, [link](https://example.com)\n\nEnd';
  await load(markdown);
  assert.equal(await source(),markdown);
  assert.equal(await page.locator('.md-h2').textContent(),'Heading');
  assert.equal(await page.locator('.md-bold').textContent(),'bold');
  assert.equal(await page.locator('.md-italic').textContent(),'italic');
  await select(markdown.indexOf('**bold**'));
  assert.ok((await page.locator('.cm-content').textContent()).includes('**bold**'));
  assert.equal(await page.locator('.md-bold').textContent(),'**bold**');
  await select(markdown.length);
  assert.ok(!(await page.locator('.cm-content').textContent()).includes('**bold**'));
  assert.equal(await source(),markdown);
});
test('blur previews all syntax and refocus restores caret, selection and undo',async()=>{
  const markdown='## Zweck\n\n**bold** text\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n<details><summary>More</summary>\n\nHidden detail\n\n</details>';
  await load(markdown,'focus-doc');await select(0,8);
  assert.equal(await page.locator('.md-h2').textContent(),'## Zweck');
  const blur=()=>page.locator('.cm-content').evaluate(content=>content.blur());
  await blur();
  assert.equal(await page.locator('.md-h2').textContent(),'Zweck');
  assert.equal(await page.locator('.md-bold').textContent(),'bold');
  assert.equal(await page.locator('#toolbar').isVisible(),false);
  await page.evaluate(()=>window.stillEditor.focus());
  assert.equal(await page.locator('.md-h2').textContent(),'## Zweck');
  let selection=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return {from:range.from,to:range.to};});
  assert.deepEqual(selection,{from:0,to:8});
  const tableStart=markdown.indexOf('| A');await select(tableStart);
  assert.equal(await page.locator('table').count(),0);
  await blur();assert.equal(await page.locator('table').count(),1);
  await page.evaluate(()=>window.stillEditor.focus());assert.equal(await page.locator('table').count(),0);
  const detailsStart=markdown.indexOf('<details>');await select(detailsStart);
  assert.equal(await page.locator('.md-disclosure').count(),0);
  await blur();assert.equal(await page.locator('.md-disclosure').count(),1);
  await page.evaluate(()=>window.stillEditor.focus());assert.equal(await page.locator('.md-disclosure').count(),0);
  await select(0,8);await page.locator('[data-action=bold]').click();
  await blur();await page.evaluate(()=>window.stillEditor.focus());
  await page.keyboard.press('Meta+z');assert.equal(await source(),markdown);
  // Switching documents while blurred must preview its first line immediately.
  await blur();await page.evaluate(()=>window.stillEditor.setDocument({id:'unfocused-new',markdown:'## New first line'}));
  assert.equal(await page.locator('.md-h2').textContent(),'New first line');
});
test('nested and escaped syntax plus multi-backtick code follow Markdown parsing',async()=>{
  await load('Intro\n\n***both*** and \\*literal\\* and ``a ` b``\n\nEnd');
  assert.equal(await page.locator('.md-bold').textContent(),'both');
  assert.equal(await page.locator('.md-italic').textContent(),'both');
  assert.equal(await page.locator('.md-code').textContent(),'a ` b');
  assert.ok((await page.locator('.cm-content').textContent()).includes('*literal*'));
  await load('');await page.keyboard.press('Meta+i');await page.keyboard.type('italic');
  assert.equal(await source(),'*italic*');
});
test('selection toolbar preserves exact Unicode range and undo',async()=>{
  await load('Before 🪴 café 中文 after');
  await select(7,17);
  await page.locator('[data-action=bold]').click();
  assert.equal(await source(),'Before **🪴 café 中文** after');
  await page.keyboard.press('Meta+z');
  assert.equal(await source(),'Before 🪴 café 中文 after');
  await select(7,17);
  await page.locator('[data-action=optimize]').click();
  const action=await page.evaluate(()=>window.messages.filter(message=>message.type==='action').at(-1));
  assert.deepEqual(action,{type:'action',action:'optimize',id:'doc-1',from:7,to:17,text:'🪴 café 中文'});
  assert.equal(await page.locator('[data-action=optimize]').textContent(),'✧ Optimieren');
  await page.evaluate(()=>window.stillEditor.setAIState({busy:true}));
  assert.equal(await page.locator('[data-action=optimize]').isDisabled(),true);
});
test('heading, quote and link actions are source edits',async()=>{
  await load('Some text\nOther line');await select(0,9);
  await page.locator('[data-action=heading2]').click();
  assert.equal(await source(),'## Some text\nOther line');
  await page.keyboard.press('Meta+z');await select(0,9);
  await page.locator('[data-action=quote]').click();
  assert.equal(await source(),'> Some text\nOther line');
  await page.keyboard.press('Meta+z');await select(0,9);
  await page.keyboard.press('Meta+k');
  assert.equal(await source(),'[Some text](https://)\nOther line');
});
test('checkbox transactions are undoable without moving the cursor',async()=>{
  await load('Intro\n\n- [ ] A task\n\nTail');
  await page.locator('.md-checkbox').click();
  assert.equal(await source(),'Intro\n\n- [x] A task\n\nTail');
  await page.keyboard.press('Meta+z');
  assert.equal(await source(),'Intro\n\n- [ ] A task\n\nTail');
});
test('table, image and details widgets reveal their original Markdown',async()=>{
  const markdown='Intro\n\n| Name | Value |\n| --- | --- |\n| Café | 42 |\n\n![Plant](attachments/plant.png)\n\n<details><summary>More</summary>\n\nHidden **detail**\n\n</details>\n\nTail';
  await load(markdown);
  assert.equal(await page.locator('table th').count(),2);
  assert.equal(await page.locator('table td').first().textContent(),'Café');
  assert.equal(await page.locator('.md-image img').getAttribute('src'),'still-asset://image/plant.png');
  assert.equal(await page.locator('.disclosure-toggle').getAttribute('aria-expanded'),'false');
  assert.ok(!(await page.locator('.cm-content').textContent()).includes('Hidden'));
  await page.locator('.disclosure-toggle').click();
  assert.equal(await page.locator('.disclosure-toggle').getAttribute('aria-expanded'),'true');
  assert.ok((await page.locator('.cm-content').textContent()).includes('Hidden detail'));
  await page.locator('.disclosure-toggle').click();
  await page.locator('.disclosure-edit').click();
  assert.ok((await page.locator('.cm-content').textContent()).includes('<details>'));
  await select(0);
  await page.locator('table').click();
  assert.equal(await page.locator('table').count(),0);
  assert.ok((await page.locator('.cm-content').textContent()).includes('| Name | Value |'));
  assert.equal(await source(),markdown);
});
test('fenced code protects literal task, table and emphasis syntax',async()=>{
  await load('Intro\n\n```md\n**literal**\n- [ ] task\n| A | B |\n| --- | --- |\n<details><summary>literal</summary>\n</details>\n```\n\nEnd');
  assert.equal(await page.locator('.md-checkbox').count(),0);
  assert.equal(await page.locator('table').count(),0);
  assert.equal(await page.locator('.md-disclosure').count(),0);
  assert.equal(await page.locator('.md-bold').count(),0);
  assert.ok((await page.locator('.cm-content').textContent()).includes('**literal**'));
});
const linkDocuments=[
  {id:'doc-1',title:'Source',section:'notes',folders:['Garden'],target:'notes/Garden/Source'},
  {id:'note-fern',title:'Fern',section:'notes',folders:['Garden'],target:'notes/Garden/Fern'},
  {id:'wiki-fern',title:'Fern',section:'wiki',folders:['Plants'],target:'wiki/Plants/Fern'},
  {id:'special',title:'A/B [Fern]|%',section:'wiki',folders:['Plants'],target:'wiki/Plants/A%2FB%20%5BFern%5D%7C%25'}
];
test('wiki links render aliases, resolve within source context and activate through the native bridge',async()=>{
  const markdown='[[Fern|my plant]] · [[wiki/Plants/Fern]] · [[Missing]]';
  await load(markdown,'doc-1');
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.locator('.cm-content').evaluate(content=>content.blur());
  const links=page.locator('.md-wiki-link');
  assert.equal(await links.count(),3);
  assert.equal(await links.nth(0).textContent(),'my plant');
  assert.ok((await links.nth(0).getAttribute('class')).includes('is-resolved'),'Same-folder note should win a duplicate-title match');
  assert.equal(await links.nth(1).textContent(),'Fern');
  assert.ok((await links.nth(1).getAttribute('class')).includes('is-resolved'),'Canonical paths resolve a specific wiki target');
  assert.equal(await links.nth(2).getAttribute('title'),'Nicht gefunden – mit ⌘-Klick erstellen: Missing');
  await links.nth(0).click({modifiers:['Meta']});
  let message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openWikiLink').at(-1));
  assert.deepEqual(message,{type:'openWikiLink',id:'doc-1',target:'Fern',from:0,to:'[[Fern|my plant]]'.length,original:'[[Fern|my plant]]'});
  await links.nth(2).focus();await page.keyboard.press('Enter');
  message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openWikiLink').at(-1));
  assert.equal(message.target,'Missing');assert.equal(message.original,'[[Missing]]');
  await links.nth(1).click();
  assert.equal(await page.locator('.cm-content').evaluate(content=>content===document.activeElement),true,'A normal click returns the rendered token to editing');
  assert.equal(await source(),markdown);
});
test('wiki autocomplete filters notes and wiki paths and supports pointer and keyboard selection',async()=>{
  await load('','doc-1');
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.keyboard.type('[[');
  await page.locator('.cm-tooltip-autocomplete').waitFor();
  let labels=await page.locator('.cm-tooltip-autocomplete .cm-completionLabel').allTextContents();
  assert.ok(labels.includes('Source')&&labels.includes('Fern'),'Suggestions include both the current note and wiki targets');
  await page.keyboard.type('wiki/Plants/Fern');
  await waitForCompletionLabels(['Fern']);
  labels=await page.locator('.cm-tooltip-autocomplete .cm-completionLabel').allTextContents();
  assert.deepEqual(labels,['Fern']);
  await page.keyboard.press('Enter');
  assert.equal(await source(),'[[wiki/Plants/Fern]]');
  await page.keyboard.press('Meta+z');assert.equal(await source(),'[[wiki/Plants/Fern','Undo restores the full query that completion replaced');
  await load('','doc-1');await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.keyboard.type('[[wiki/Plants/Fern');await waitForCompletionLabels(['Fern']);
  await page.keyboard.press('Tab');assert.equal(await source(),'[[wiki/Plants/Fern]]','Tab accepts the selected completion before the editor indents');
  await load('','doc-1');await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.keyboard.type('[[A/B');await waitForCompletionLabels(['A/B [Fern]|%']);
  await page.locator('.cm-tooltip-autocomplete li').filter({hasText:'A/B [Fern]|%'}).click();
  assert.equal(await source(),'[[wiki/Plants/A%2FB%20%5BFern%5D%7C%25]]','Delimiter titles use their canonical escaped target');
  await load('','doc-1');await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.keyboard.type('[[Fe');await waitForCompletionLabels(['A/B [Fern]|%','Fern','Fern']);
  await page.getByRole('option',{name:'Fern Wiki · Plants',exact:true}).click();
  assert.equal(await source(),'[[wiki/Plants/Fern]]','Pointer selection inserts the selected duplicate target unambiguously');

  const cafeDocuments=[
    {id:'doc-1',title:'Source',section:'notes',folders:['Garden'],target:'notes/Garden/Source'},
    {id:'cafe-note',title:'Cafe',section:'notes',folders:['Garden'],target:'notes/Garden/Cafe'},
    {id:'cafe-wiki',title:'Café',section:'wiki',folders:['Plants'],target:'wiki/Plants/Café'}
  ];
  await load('','doc-1');await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),cafeDocuments);
  await page.keyboard.type('[[Caf');
  await page.waitForFunction(()=>{
    const labels=[...document.querySelectorAll('.cm-tooltip-autocomplete .cm-completionLabel')].map(item=>item.textContent);
    return labels.length===2&&labels.includes('Cafe')&&labels.includes('Café');
  });
  await page.getByRole('option',{name:'Café Wiki · Plants',exact:true}).click();
  assert.equal(await source(),'[[wiki/Plants/Café]]','Fold-equivalent titles use the canonical target to avoid resolving to the source-local duplicate');
});
test('wiki autocomplete stays closed when editing inside an already complete token',async()=>{
  await load('[[Fern]]','doc-1');
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await select(4);
  await page.waitForTimeout(120);
  assert.equal(await page.locator('.cm-tooltip-autocomplete').count(),0,'A completion must not leave stale closing brackets after replacing a complete token');
  assert.equal(await source(),'[[Fern]]');
});
test('wiki metadata refresh preserves document, cursor, selection and undo history',async()=>{
  await load('Fern body','doc-1');await select(0,4);
  await page.locator('[data-action=bold]').click();
  const markdown=await source(),before=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return{anchor:range.anchor,head:range.head};});
  const history=await page.evaluate(()=>window.stillEditor.historyState());
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  const after=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return{anchor:range.anchor,head:range.head};});
  assert.deepEqual(after,before);assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),history);assert.equal(await source(),markdown);
  await page.keyboard.press('Meta+z');assert.equal(await source(),'Fern body');

  await load('[[wiki/Plants/Fern]] body','doc-1');
  const metadata=structuredClone(linkDocuments);
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),metadata);
  await page.locator('.cm-content').evaluate(content=>content.blur());
  const link=page.locator('.md-wiki-link');
  assert.equal(await link.textContent(),'Fern');
  const beforeRename={history:await page.evaluate(()=>window.stillEditor.historyState()),cursor:await page.locator('.cm-content').evaluate(content=>content.cmTile.root.view.state.selection.main.head)};
  metadata.find(document=>document.id==='wiki-fern').title='Fern renamed';
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),metadata);
  assert.equal(await link.textContent(),'Fern renamed','A metadata-only rename refreshes the rendered link label');
  assert.match(await link.getAttribute('title'),/Fern renamed/,'The refreshed label also updates the link tooltip');
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),beforeRename.history);
  assert.equal(await page.locator('.cm-content').evaluate(content=>content.cmTile.root.view.state.selection.main.head),beforeRename.cursor);
});
test('wiki parsing excludes escaped, code, image-alt and HTML-comment tokens',async()=>{
  const markdown='`[[Inline]]`\n\n    [[Indented]]\n\n```md\n[[Fenced]]\n```\n\n![alt [[Image]]](attachments/x.png)\n\n\\[[Escaped]]\n\n<!-- [[Comment]] -->\n\n[[Visible]]';
  await load(markdown,'doc-1');await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),linkDocuments);
  await page.locator('.cm-content').evaluate(content=>content.blur());
  assert.deepEqual(await page.locator('.md-wiki-link').allTextContents(),['Visible']);
  assert.equal(await source(),markdown);
});
test('Markdown links and GFM autolinks open only allowed web and mail URLs',async()=>{
  await load('[Site](https://example.com/path) and [Mail](mailto:hello@example.com) and [Unsafe](javascript:alert(1)) and <https://auto.example> and https://bare.example/path.','doc-1');
  await page.locator('.cm-content').evaluate(content=>content.blur());
  const links=page.locator('.md-link[role=link]');
  assert.equal(await links.count(),4);
  assert.equal(await links.nth(0).getAttribute('role'),'link');
  assert.equal(await links.nth(0).getAttribute('tabindex'),'0');
  await links.nth(0).click({modifiers:['Meta']});
  let message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openExternalLink').at(-1));
  assert.deepEqual(message,{type:'openExternalLink',id:'doc-1',url:'https://example.com/path'});
  await links.nth(1).focus();await page.keyboard.press('Enter');
  message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openExternalLink').at(-1));
  assert.equal(message.url,'mailto:hello@example.com');
  await page.locator('[data-still-link-url="https://auto.example/"]').click({modifiers:['Meta']});
  message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openExternalLink').at(-1));assert.equal(message.url,'https://auto.example/');
  await page.locator('[data-still-link-url="https://bare.example/path"]').click({modifiers:['Meta']});
  message=await page.evaluate(()=>window.messages.filter(item=>item.type==='openExternalLink').at(-1));assert.equal(message.url,'https://bare.example/path');
  await page.locator('.md-link').filter({hasText:'Unsafe'}).click({modifiers:['Meta']});
  assert.equal((await page.evaluate(()=>window.messages.filter(item=>item.type==='openExternalLink').length)),4,'Unsafe URL schemes never reach native navigation');
});
test('wiki resolution folds case and accents, preserves path separators and rejects malformed escapes',async()=>{
  const markdown='[[cafe]] · [[WIKI/PLANTS/cafe]] · [[wiki//Plants/Café]] · [[wiki\\Plants\\Café]] · [[bad%]] · [[A/B [Fern]|x]] · [[wiki/A%2FB]] · [[wiki/A/B]]';
  await load(markdown,'doc-1');
  const docs=[
    {id:'doc-1',title:'Source',section:'notes',folders:['Garden'],target:'notes/Garden/Source'},
    {id:'cafe-note',title:'Café',section:'notes',folders:['Garden'],target:'notes/Garden/Café'},
    {id:'cafe-wiki',title:'Café',section:'wiki',folders:['Plants'],target:'wiki/Plants/Café'},
    {id:'slash-title',title:'wiki//Plants/Café',section:'notes',folders:['Odd'],target:'notes/Odd/Slash'},
    {id:'encoded-slash',title:'A/B',section:'wiki',folders:[],target:'wiki/A%2FB'},
    {id:'folder-and-title',title:'B',section:'wiki',folders:['A'],target:'wiki/A/B'}
  ];
  await page.evaluate(documents=>window.stillEditor.setLinkDocuments({id:'doc-1',documents}),docs);
  await page.locator('.cm-content').evaluate(content=>content.blur());
  const rendered=page.locator('.md-wiki-link');
  assert.equal(await rendered.nth(0).getAttribute('class').then(value=>value.includes('is-resolved')),true,'Short names match case and accents');
  assert.equal(await rendered.nth(1).getAttribute('class').then(value=>value.includes('is-resolved')),true,'Canonical paths match case and accents');
  assert.equal(await rendered.nth(2).getAttribute('class').then(value=>value.includes('is-unresolved')),true,'Empty slash components are preserved');
  assert.equal(await rendered.nth(3).getAttribute('class').then(value=>value.includes('is-unresolved')),true,'Backslashes are preserved rather than normalized as path separators');
  assert.equal(await rendered.nth(4).getAttribute('class').then(value=>value.includes('is-unresolved')),true,'Invalid percent escapes remain unresolved');
  assert.equal(await rendered.nth(5).textContent(),'x','Aliases still render when the target needs canonical escaping');
  assert.equal(await rendered.nth(5).getAttribute('class').then(value=>value.includes('is-unresolved')),true,'Qualified targets do not fall back to a similarly named short title');
  assert.equal(await rendered.nth(6).getAttribute('class').then(value=>value.includes('is-resolved')),true,'An encoded slash stays inside its target component');
  assert.equal(await rendered.nth(7).getAttribute('class').then(value=>value.includes('is-resolved')),true,'A literal path separator stays a component boundary');
});
test('AI replacement checks document, range and original; document changes reset undo',async()=>{
  await load('🪴 old text');
  let replaced=await page.evaluate(()=>window.stillEditor.replaceSelection({id:'wrong',from:3,to:6,original:'old',replacement:'new'}));assert.equal(replaced,false);
  replaced=await page.evaluate(()=>window.stillEditor.replaceSelection({id:'doc-1',from:3,to:6,original:'bad',replacement:'new'}));assert.equal(replaced,false);
  replaced=await page.evaluate(()=>window.stillEditor.replaceSelection({id:'doc-1',from:3,to:6,original:'old',replacement:'new'}));assert.equal(replaced,true);
  assert.equal(await source(),'🪴 new text');
  await page.keyboard.press('Meta+z');assert.equal(await source(),'🪴 old text');
  await page.evaluate(()=>window.stillEditor.insertMarkdown('edit'));
  await load('Second document','doc-2');
  await page.keyboard.press('Meta+z');assert.equal(await source(),'Second document');
  assert.equal(await page.locator('#toolbar').isVisible(),false);
});
test('native undo and redo APIs restore focus and preserve exact replacements',async()=>{
  await load('Before old after','native-history-doc');
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:false,canRedo:false});
  await page.locator('.cm-content').evaluate(content=>content.blur());
  const replaced=await page.evaluate(()=>window.stillEditor.replaceSelection({id:'native-history-doc',from:7,to:10,original:'old',replacement:'optimized'}));assert.equal(replaced,true);
  assert.equal(await page.locator('.cm-content').evaluate(content=>content===document.activeElement),true);
  assert.equal(await source(),'Before optimized after');
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:true,canRedo:false});
  await page.locator('.cm-content').evaluate(content=>content.blur());
  assert.equal(await page.evaluate(()=>window.stillEditor.undo()),true);
  assert.equal(await source(),'Before old after');
  assert.equal(await page.locator('.cm-content').evaluate(content=>content===document.activeElement),true);
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:false,canRedo:true});
  assert.equal(await page.evaluate(()=>window.stillEditor.redo()),true);
  assert.equal(await source(),'Before optimized after');
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:true,canRedo:false});
  await page.locator('.cm-content').evaluate(content=>content.blur());
  assert.equal(await page.evaluate(()=>window.stillEditor.insertImage({id:'native-history-doc',url:'attachments/test.png',alt:'Test'})),true);
  assert.equal(await page.locator('.cm-content').evaluate(content=>content===document.activeElement),true);
  const focusMessages=await page.evaluate(()=>window.messages.filter(message=>message.type==='focus'&&message.id==='native-history-doc'));
  assert.ok(focusMessages.some(message=>message.focused===false));
  assert.equal(focusMessages.at(-1).focused,true);
  await load('Fresh','new-history-doc');
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:false,canRedo:false});
  assert.equal(await page.evaluate(()=>window.stillEditor.undo()),false);
});
test('same document availability refresh preserves selection, undo and toolbar DOM',async()=>{
  await load('Keep selection', 'availability-doc',false);await select(0,4);
  await page.locator('[data-action=bold]').click();
  const formatted=await source();
  const before=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return {from:range.from,to:range.to};});
  await page.evaluate(markdown=>window.stillEditor.setDocument({id:'availability-doc',markdown,aiAvailable:true,strings:{'editor.optimizeAction':'Optimieren'}}),formatted);
  const after=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return {from:range.from,to:range.to};});
  assert.deepEqual(after,before);
  assert.equal(await page.locator('[data-action=optimize]').isDisabled(),false);
  const stable=await page.locator('[data-action=optimize]').evaluate(button=>{window.savedToolbarButton=button;window.stillEditor.setAIState({busy:false});return window.savedToolbarButton===document.querySelector('[data-action=optimize]');});assert.equal(stable,true);
  await page.keyboard.press('Meta+z');assert.equal(await source(),'Keep selection');
});
test('paste image roundtrip is tied to document and pending selection',async()=>{
  await load('Before after');await select(7,7);
  await page.locator('.cm-content').evaluate(content=>{
    const data=new DataTransfer();data.items.add(new File([new Uint8Array([137,80,78,71])],'plant.png',{type:'image/png'}));
    content.dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));
  });
  await page.waitForFunction(()=>window.messages.some(message=>message.type==='importImage'));
  const request=await page.evaluate(()=>window.messages.filter(message=>message.type==='importImage').at(-1));
  assert.equal(request.id,'doc-1');assert.equal(request.filename,'plant.png');assert.equal(request.base64,'iVBORw==');
  await page.evaluate(()=>window.stillEditor.insertMarkdown('typed '));
  const inserted=await page.evaluate(request=>window.stillEditor.insertImage({id:request.id,requestId:request.requestId,url:'attachments/plant.png',alt:'Plant'}),request);
  assert.equal(inserted,true);assert.equal(await source(),'Before typed ![Plant](attachments/plant.png)after');
  const reused=await page.evaluate(request=>window.stillEditor.insertImage({id:request.id,requestId:request.requestId,url:'attachments/plant.png'}),request);assert.equal(reused,false);
  await load('Other','doc-2');
  const stale=await page.evaluate(request=>window.stillEditor.insertImage({id:request.id,requestId:request.requestId,url:'attachments/plant.png'}),request);assert.equal(stale,false);
});
test('toolbar clamps near edges, dismisses on Escape and follows scrolling',async()=>{
  await load('First selection\n\n'+Array.from({length:60},(_,n)=>`Line ${n}`).join('\n'));
  await select(0,15);
  let rect=await page.locator('#toolbar').boundingBox();assert.ok(rect.x>=0&&rect.y>=0&&rect.x+rect.width<=1000);
  await page.keyboard.press('Escape');await page.waitForTimeout(160);assert.equal(await page.locator('#toolbar').isVisible(),false);
  await select(0,5);assert.equal(await page.locator('#toolbar').isVisible(),true);
  await page.locator('.cm-scroller').evaluate(element=>{element.scrollTop=1400;element.dispatchEvent(new Event('scroll'));});
  await page.waitForTimeout(160);assert.equal(await page.locator('#toolbar').isVisible(),false);
  await page.setViewportSize({width:380,height:700});await select(0,5);
  rect=await page.locator('#toolbar').boundingBox();assert.ok(rect.x>=0&&rect.x+rect.width<=380&&rect.y>=0);
  await page.setViewportSize({width:1000,height:900});
});
test('Cmd+B requests the sidebar and leaves source, selection and history unchanged',async()=>{
  await load('Selected text','sidebar-doc');await select(0,8);
  await page.keyboard.press('Meta+b');
  assert.equal(await source(),'Selected text');
  assert.deepEqual(await page.evaluate(()=>window.messages.filter(message=>message.type==='toggleSidebar').at(-1)),{type:'toggleSidebar'});
  assert.deepEqual(await page.evaluate(()=>window.stillEditor.historyState()),{canUndo:false,canRedo:false});
  await page.locator('[data-action=bold]').click();assert.equal(await source(),'**Selected** text');
});
test('caret motion is visual only, short, and snaps for navigation, lines, selection and IME',async()=>{
  await load('Typing','caret-doc');await select(6);await page.waitForTimeout(80);
  const inspect=()=>page.evaluate(()=>{
    const content=document.querySelector('.cm-content'),editor=content.cmTile.root.view,overlay=document.querySelector('.still-smooth-caret');
    return {source:window.stillEditor.getMarkdown(),head:editor.state.selection.main.head,empty:editor.state.selection.main.empty,visible:!overlay.hidden,moving:editor.dom.classList.contains('still-caret-moving'),animations:overlay.getAnimations().map(animation=>({duration:animation.effect.getTiming().duration,easing:animation.effect.getTiming().easing})),nativeCursor:document.querySelector('.cm-cursor-primary')?getComputedStyle(document.querySelector('.cm-cursor-primary')).visibility:null};
  });
  await page.keyboard.type('!');
  assert.equal(await source(),'Typing!'); // source is immediate, before any visual settle.
  await page.waitForFunction(()=>document.querySelector('.still-smooth-caret').getAnimations().length>0);
  let state=await inspect();assert.equal(state.head,7);assert.equal(state.moving,true);assert.equal(state.visible,true);
  assert.equal(state.animations[0].duration,115);assert.equal(state.animations[0].easing,'cubic-bezier(0.22, 0.61, 0.36, 1)');
  await page.waitForTimeout(150);state=await inspect();assert.equal(state.visible,false);assert.equal(state.moving,false);assert.ok(['visible','hidden'].includes(state.nativeCursor));
  await page.keyboard.press('Backspace');await page.waitForFunction(()=>document.querySelector('.still-smooth-caret').getAnimations().length>0);
  assert.equal(await source(),'Typing');
  await page.keyboard.press('ArrowLeft');state=await inspect();assert.equal(state.moving,false);assert.equal(state.visible,false);assert.equal(state.head,5);
  await page.keyboard.press('End');await page.keyboard.press('Enter');await page.waitForTimeout(30);assert.equal((await inspect()).visible,false);
  await select(0,3);assert.equal((await inspect()).visible,false);assert.equal((await inspect()).empty,false);
  await select(0);await page.locator('.cm-content').evaluate(content=>content.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true,data:''})));
  await page.locator('.cm-content').evaluate(content=>content.cmTile.root.view.dispatch({changes:{from:0,insert:'あ'},selection:{anchor:1},userEvent:'input.type.compose'}));
  await page.waitForTimeout(25);assert.equal((await inspect()).visible,false);
  await page.locator('.cm-content').evaluate(content=>content.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'あ'})));
  await load('New document','caret-new');assert.equal((await inspect()).visible,false);
  await select(12);await page.waitForTimeout(40);await page.keyboard.type('x');
  await page.waitForFunction(()=>document.querySelector('.still-smooth-caret').getAnimations().length>0);
  await page.locator('.cm-content').dispatchEvent('pointerdown',{pointerType:'mouse',clientX:90,clientY:35});
  assert.equal((await inspect()).visible,false);assert.equal((await inspect()).moving,false);
  await select(13);await page.waitForTimeout(40);await page.keyboard.type('y');
  await page.waitForFunction(()=>document.querySelector('.still-smooth-caret').getAnimations().length>0);
  await page.locator('.cm-scroller').evaluate(element=>element.dispatchEvent(new Event('scroll')));
  assert.equal((await inspect()).visible,false);assert.equal((await inspect()).moving,false);
  await page.locator('.cm-content').evaluate(content=>content.blur());assert.equal((await inspect()).visible,false);
});
test('real caret screen coordinates interpolate through geometry updates and repeated input',async()=>{
  await load('Wide glyphs ','caret-screen');await select(12);await page.waitForTimeout(70);
  const probe=async(duration=400)=>page.locator('.cm-content').evaluate((content,duration)=>{
    const editor=content.cmTile.root.view,plugin=editor.plugins.map(item=>item.value).find(value=>value?.overlay);
    window.caretProbe={frames:[],geometryUpdates:0};
    const original=plugin.update;
    plugin.update=function(update){if(!update.docChanged&&update.geometryChanged)window.caretProbe.geometryUpdates++;return original.call(this,update);};
    const start=performance.now();
    const sample=()=>{
      const overlay=plugin.overlay,head=editor.state.selection.main.head,target=editor.coordsAtPos(head),primary=document.querySelector('.cm-cursor-primary');
      window.caretProbe.frames.push({time:performance.now()-start,head,source:editor.state.doc.toString(),target:target?.left,left:overlay.hidden?primary?.getBoundingClientRect().left:overlay.getBoundingClientRect().left,hidden:overlay.hidden,moving:editor.dom.classList.contains('still-caret-moving'),primaryVisibility:primary?getComputedStyle(primary).visibility:null});
      if(performance.now()-start<duration)requestAnimationFrame(sample);else plugin.update=original;
    };requestAnimationFrame(sample);
    // A real layout-only geometry update: note padding changes below the text,
    // leaving caret coordinates and the actual scroll position unchanged.
    setTimeout(()=>{editor.contentDOM.style.setProperty('padding-bottom','451px','important');editor.requestMeasure();},35);
  },duration);
  await probe(240);await page.keyboard.type('m');await page.waitForTimeout(270);
  let result=await page.evaluate(()=>window.caretProbe);
  assert.ok(result.geometryUpdates>0,'A real geometryChanged update was observed');
  let moving=result.frames.filter(frame=>frame.source==='Wide glyphs m'&&frame.moving);
  assert.ok(moving.length>=3,`Caret must visibly move for several frames: ${JSON.stringify(result)}`);
  const intermediate=moving.filter(frame=>Math.abs(frame.left-frame.target)>.4);
  assert.ok(intermediate.length>=2,'Screen position must interpolate, not merely own an Animation');
  assert.ok(intermediate.every(frame=>!frame.hidden&&frame.primaryVisibility==='hidden'));
  assert.ok(intermediate.at(-1).left>intermediate[0].left+.3,'Caret moves toward newly inserted glyph');
  let last=result.frames.at(-1);assert.equal(last.hidden,true);assert.ok(Math.abs(last.left-last.target)<1);
  await probe(520);await page.keyboard.type('mmmm',{delay:28});await page.waitForTimeout(360);
  result=await page.evaluate(()=>window.caretProbe);
  moving=result.frames.filter(frame=>frame.head>13&&frame.moving);
  assert.ok(new Set(moving.map(frame=>frame.head)).size>=3,'Every part of a typing series keeps visible motion');
  assert.ok(moving.every(frame=>!frame.hidden&&frame.primaryVisibility==='hidden'));
  for(let i=1;i<moving.length;i++)assert.ok(moving[i].left>=moving[i-1].left-.3,'Retarget from the current visual position without moving backwards');
  assert.equal(await source(),'Wide glyphs mmmmm');
  await probe(480);for(let n=0;n<4;n++){await page.keyboard.press('Backspace');await page.waitForTimeout(28);}await page.waitForTimeout(320);
  result=await page.evaluate(()=>window.caretProbe);moving=result.frames.filter(frame=>frame.head<17&&frame.moving);
  assert.ok(new Set(moving.map(frame=>frame.head)).size>=3,'Repeated backspace remains smooth');
  for(let i=1;i<moving.length;i++)assert.ok(moving[i].left<=moving[i-1].left+.3,'Backspace retarget remains continuous');
  assert.equal(await source(),'Wide glyphs m');
});
test('pointer drag toolbar follows the active selection without replaying entrance or animating position',async()=>{
  const markdown=Array.from({length:45},(_,index)=>`Line ${index} contains enough words for a real dragged selection.`).join('\n');
  await load(markdown,'drag-doc');
  await page.locator('#toolbar').evaluate(element=>{window.toolbarEntrances=0;element.addEventListener('animationstart',event=>{if(event.animationName==='toolbar-in')window.toolbarEntrances++;});});
  const coords=position=>page.locator('.cm-content').evaluate((content,position)=>{const rect=content.cmTile.root.view.coordsAtPos(position);return{x:rect.left,y:(rect.top+rect.bottom)/2};},position);
  const first=markdown.indexOf('enough'),later=markdown.indexOf('Line 5')+25,earlier=markdown.indexOf('Line 2')+10;
  const start=await coords(first),end=await coords(later),back=await coords(earlier);
  await page.mouse.move(start.x,start.y);await page.mouse.down();await page.mouse.move(end.x,end.y,{steps:12});await page.waitForTimeout(290);
  let state=await page.locator('#toolbar').evaluate(element=>({left:parseFloat(element.style.left),top:parseFloat(element.style.top),visible:!element.hidden,entrances:window.toolbarEntrances,transition:getComputedStyle(element).transitionProperty}));
  assert.equal(state.visible,true);assert.equal(state.entrances,1);assert.equal(state.transition,'none');
  const forward=state;
  await page.mouse.move(back.x,back.y,{steps:10});await page.waitForTimeout(40);
  state=await page.locator('#toolbar').evaluate(element=>({left:parseFloat(element.style.left),top:parseFloat(element.style.top),entrances:window.toolbarEntrances}));
  assert.ok(Math.abs(state.top-forward.top)>35,'Toolbar follows the moving multi-line selection head');assert.equal(state.entrances,1);
  await page.mouse.up();
  await page.evaluate(markdown=>{window.stillEditor.setDocument({id:'drag-doc',markdown,aiAvailable:false,strings:{'editor.optimizeAction':'Optimieren'}});window.stillEditor.setAIState({busy:true,label:'Working'});window.stillEditor.setAIState({busy:false});},markdown);
  assert.equal(await page.evaluate(()=>window.toolbarEntrances),1,'Native redraw/availability never replays entrance');
  const oldTop=await page.locator('#toolbar').evaluate(element=>parseFloat(element.style.top));
  await page.locator('.cm-scroller').evaluate(element=>{element.scrollTop=25;element.dispatchEvent(new Event('scroll'));});await page.waitForTimeout(40);
  assert.ok(Math.abs(await page.locator('#toolbar').evaluate(element=>parseFloat(element.style.top))-oldTop)>10,'Toolbar tracks scroll immediately');
  // Reverse-direction selection preserves the same active-head anchoring.
  await page.locator('.cm-scroller').evaluate(element=>{element.scrollTop=0;});await select(0);
  const reverseStart=await coords(later),reverseEnd=await coords(first);
  await page.mouse.move(reverseStart.x,reverseStart.y);await page.mouse.down();await page.mouse.move(reverseEnd.x,reverseEnd.y,{steps:14});await page.mouse.up();await page.waitForTimeout(50);
  const selection=await page.locator('.cm-content').evaluate(content=>{const range=content.cmTile.root.view.state.selection.main;return{anchor:range.anchor,head:range.head};});
  assert.ok(selection.anchor>selection.head,'Real pointer drag selected backwards');
  assert.equal(await page.locator('#toolbar').isVisible(),true);
});
test('toolbar uses a restrained bounce and shorter exit; both reduced-motion preferences snap',async()=>{
  await load('Motion selection','motion-doc');await select(0,6);
  let motion=await page.locator('#toolbar').evaluate(element=>({name:getComputedStyle(element).animationName,duration:getComputedStyle(element).animationDuration,frames:element.getAnimations()[0]?.effect.getKeyframes()}));
  assert.equal(motion.name,'toolbar-in');assert.equal(motion.duration,'0.26s');assert.ok(motion.frames.some(frame=>frame.transform.includes('1.055')));
  assert.equal(await page.locator('[data-action=bold]').evaluate(element=>getComputedStyle(element).cursor),'pointer');
  await page.keyboard.press('Escape');
  motion=await page.locator('#toolbar').evaluate(element=>({state:element.dataset.state,duration:getComputedStyle(element).animationDuration,inert:element.inert}));
  assert.equal(motion.state,'closing');assert.equal(motion.duration,'0.13s');assert.equal(motion.inert,true);
  await page.waitForTimeout(160);assert.equal(await page.locator('#toolbar').isVisible(),false);
  for(const preference of ['native','system']) {
    await page.emulateMedia({reducedMotion:preference==='system'?'reduce':'no-preference'});
    await page.evaluate(native=>window.stillEditor.setAppearance({theme:'light',reduceMotion:native}),preference==='native');
    await select(0,6);
    assert.equal(await page.locator('#toolbar').evaluate(element=>getComputedStyle(element).animationName),'none');
    await page.keyboard.press('Escape');assert.equal(await page.locator('#toolbar').isVisible(),false);
    await select(6);await page.keyboard.type('x');await page.waitForTimeout(25);
    assert.equal(await page.locator('.still-smooth-caret').evaluate(element=>element.hidden&&element.getAnimations().length===0),true);
    assert.equal(await page.locator('.cm-editor').evaluate(element=>element.classList.contains('still-caret-moving')),false);
  }
  await page.emulateMedia({reducedMotion:'no-preference'});await page.evaluate(()=>window.stillEditor.setAppearance({theme:'light',reduceMotion:false}));
});
test('toolbar bounce peak stays inside desktop and mobile viewport edges',async()=>{
  for(const width of [1000,380]) {
    await page.setViewportSize({width,height:700});
    const markdown='Edge '+('wide text '.repeat(18));
    for(const range of [[0,4],[markdown.length-5,markdown.length]]) {
      await load(markdown,`peak-${width}-${range[0]}`);await select(...range);
      const bounds=await page.locator('#toolbar').evaluate(async element=>{
        const animation=element.getAnimations().find(item=>item.animationName==='toolbar-in');
        animation.pause();animation.currentTime=187.2;
        await new Promise(resolve=>requestAnimationFrame(resolve));
        const rect=element.getBoundingClientRect();
        return {left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom,viewport:innerWidth};
      });
      assert.ok(bounds.left>=0&&bounds.right<=bounds.viewport&&bounds.top>=0&&bounds.bottom<=700,`Peak scale clips at viewport edge: ${JSON.stringify(bounds)}`);
    }
  }
  await page.setViewportSize({width:1000,height:900});
});
let failed=0;
try {
  for(const [name,body] of tests){try{await body();console.log(`PASS ${name}`);}catch(error){failed++;console.error(`FAIL ${name}\n${error.stack}`);}}
  assert.deepEqual(errors,[],'No uncaught browser errors');
} finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
if(failed)process.exitCode=1;
