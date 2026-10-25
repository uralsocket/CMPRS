import {build} from 'esbuild';
import fs from 'node:fs/promises';
await fs.mkdir('dist',{recursive:true});
await build({entryPoints:['src/App.jsx'],bundle:true,minify:true,outfile:'dist/app.js',format:'iife',target:['safari16'],jsx:'automatic',define:{'process.env.NODE_ENV':'"production"'},legalComments:'eof'});
await fs.copyFile('src/index.html','dist/index.html');
await fs.copyFile('src/style.css','dist/style.css');
await fs.copyFile('../Resources/icon.svg','dist/icon.svg');
