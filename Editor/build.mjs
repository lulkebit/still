import { build } from 'esbuild';
import { createHash } from 'node:crypto';
import { mkdir, copyFile, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const editorRoot = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(editorRoot, '..');
const out = new URL('../Sources/Still/Resources/Editor/', import.meta.url);
await mkdir(out, { recursive: true });
const result=await build({entryPoints: ['src/editor.js'], bundle: true, format: 'iife', target: ['safari18'], outfile: fileURLToPath(new URL('editor.js', out)), minify: true, legalComments: 'none',metafile:true});
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

async function filesUnder(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...await filesUnder(absolutePath));
    } else if (entry.isFile()) {
      files.push(absolutePath);
    }
  }
  return files;
}

const sourceFiles = await filesUnder(path.join(editorRoot, 'src'));
const fingerprintPaths = [
  ...sourceFiles.map(file => path.relative(projectRoot, file).split(path.sep).join('/')),
  'Editor/package.json',
  'Editor/package-lock.json',
  'Editor/build.mjs',
  'Sources/Still/Resources/Editor/editor.js',
  'Sources/Still/Resources/Editor/editor.css',
  'Sources/Still/Resources/Editor/index.html',
  'Sources/Still/Resources/Editor/THIRD_PARTY_NOTICES.txt',
].sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));

const fingerprintLines = [];
for (const relativePath of fingerprintPaths) {
  const contents = await readFile(path.join(projectRoot, relativePath));
  const digest = createHash('sha256').update(contents).digest('hex');
  fingerprintLines.push(`${digest}  ${relativePath}`);
}

const fingerprintPath = path.join(editorRoot, 'bundle.sha256');
const temporaryFingerprintPath = `${fingerprintPath}.${process.pid}.tmp`;
await writeFile(temporaryFingerprintPath, `${fingerprintLines.join('\n')}\n`);
await rename(temporaryFingerprintPath, fingerprintPath);
