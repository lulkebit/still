import { createServer } from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromium } from '@playwright/test';

const distribution=process.env.STILL_PERF_ASSET_DIR?pathToFileURL(path.resolve(process.env.STILL_PERF_ASSET_DIR)+'/'):new URL('../../Sources/Still/Resources/Editor/',import.meta.url);
const resultPath='/tmp/still-smooth-perf.json';
const server=createServer(async(req,res)=>{
  const name=req.url==='/'?'index.html':req.url.slice(1);
  if(!['index.html','editor.js','editor.css'].includes(name)){res.writeHead(404).end();return;}
  res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html');
  res.end(await readFile(new URL(name,distribution)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true});
const page=await browser.newPage({viewport:{width:1000,height:900}});
await page.goto(`http://127.0.0.1:${server.address().port}`);
await page.waitForFunction(()=>!!window.stillEditor);

const buildMarkdown=target=>{
  const section=[
    '# Field notes',
    '',
    'This paragraph records a practical observation with **emphasis**, `inline code`, a [source](https://example.com/reference), and a [[Project Atlas|related note]].',
    '- [ ] Review the supporting evidence and keep the wording precise.',
    '> Capture the reason for the change so the next person can follow the decision.',
    '',
    '```md',
    'A short sample block with syntax that should stay stable while typing.',
    '```',
    ''
  ].join('\n');
  let markdown='';
  while(markdown.length<target)markdown+=section;
  return markdown.slice(0,target);
};
const summarize=samples=>{
  const sorted=[...samples].sort((left,right)=>left-right);
  const percentile=fraction=>sorted[Math.min(sorted.length-1,Math.ceil(sorted.length*fraction)-1)];
  return {count:samples.length,meanMs:Number((samples.reduce((sum,value)=>sum+value,0)/samples.length).toFixed(3)),p50Ms:Number(percentile(.5).toFixed(3)),p95Ms:Number(percentile(.95).toFixed(3)),maxMs:Number(Math.max(...samples).toFixed(3))};
};
const results={phase:process.env.STILL_PERF_PHASE||'unspecified',browser:browser.version(),cases:[]};
try {
  for(const targetLength of [20_000,100_000]) {
    const markdown=buildMarkdown(targetLength);
    await page.evaluate(markdown=>window.stillEditor.setDocument({id:'perf-document',markdown,aiAvailable:false}),markdown);
    await page.waitForFunction(()=>document.querySelector('.cm-content')?.cmTile?.root?.view?.state.doc.length>0);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const paragraphOffset=markdown.indexOf('This paragraph',Math.floor(markdown.length/2));
    const measurements=await page.locator('.cm-content').evaluate((content,paragraphOffset)=>{
      const view=content.cmTile.root.view;
      const line=view.state.doc.lineAt(paragraphOffset);
      const middle=line.from+Math.min(20,Math.floor(line.length/2));
      view.dispatch({selection:{anchor:middle}});
      const sample=operation=>{
        const durations=[];
        for(let index=0;index<60;index++) {
          const start=performance.now();operation(index);durations.push(performance.now()-start);
        }
        return durations;
      };
      const selection=sample(index=>view.dispatch({selection:{anchor:line.from+Math.min(line.length-1,20+(index%4))}}));
      let head=view.state.selection.main.head;
      const typing=sample(()=>{
        const insert='x';
        view.dispatch({changes:{from:head,to:head,insert},selection:{anchor:head+insert.length},userEvent:'input.type'});
        head++;
      });
      return {selection,typing};
    },paragraphOffset);
    results.cases.push({characters:markdown.length,lines:markdown.split('\n').length,selection:summarize(measurements.selection),typing:summarize(measurements.typing)});
    console.log(`${markdown.length} chars: selection mean ${results.cases.at(-1).selection.meanMs}ms, typing mean ${results.cases.at(-1).typing.meanMs}ms`);
  }
  let saved={};
  try{saved=JSON.parse(await readFile(resultPath,'utf8'));}catch(error){if(error.code!=='ENOENT')throw error;}
  saved[results.phase]=results;
  await writeFile(resultPath,JSON.stringify(saved,null,2)+'\n');
  console.log(`Saved ${results.phase} results to ${resultPath}`);
} finally {
  await browser.close();
  await new Promise(resolve=>server.close(resolve));
}
