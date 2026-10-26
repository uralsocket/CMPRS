import {build} from 'esbuild';
import fs from 'node:fs/promises';
await fs.mkdir('dist',{recursive:true});
await build({entryPoints:['src/App.jsx'],bundle:true,minify:true,outfile:'dist/app.js',format:'iife',target:['chrome100'],jsx:'automatic',define:{'process.env.NODE_ENV':'"production"'},legalComments:'eof'});
for(const file of ['index.html','style.css'])await fs.copyFile('src/'+file,'dist/'+file);
