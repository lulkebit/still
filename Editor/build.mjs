import { build } from 'esbuild';
import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
const out = new URL('../Sources/Still/Resources/Editor/', import.meta.url);
await mkdir(out, { recursive: true });
const result=await build({entryPoints: ['src/editor.js'], bundle: true, format: 'iife', target: ['safari18'], outfile: new URL('editor.js', out).pathname, minify: true, legalComments: 'none',metafile:true});
await Promise.all(['index.html', 'editor.css'].map(name => copyFile(new URL('src/' + name, import.meta.url), new URL(name, out))));
const packages=new Set(Object.keys(result.metafile.inputs).filter(file=>file.startsWith('node_modules/')).map(file=>{
  const parts=file.split('/');return path.join('node_modules',parts[1],...(parts[1].startsWith('@')?[parts[2]]:[]));
}));
const notices=['Third-party software included in still.’s offline Markdown editor.\n'];
for(const directory of [...packages].sort()) {
  const pkg=JSON.parse(await readFile(path.join(directory,'package.json'),'utf8'));
  let license;
  for(const filename of ['LICENSE','LICENSE.md','LICENSE.txt','license']) {
    try {license=await readFile(path.join(directory,filename),'utf8');break;}catch(error){if(error.code!=='ENOENT')throw error;}
  }
  if(!license)throw new Error(`No license found for bundled dependency ${pkg.name}`);
  notices.push(`${'='.repeat(72)}\n${pkg.name} ${pkg.version}\n${'='.repeat(72)}\n${license.trim()}\n`);
}
await writeFile(new URL('THIRD_PARTY_NOTICES.txt',out),notices.join('\n'));
