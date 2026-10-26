import hashlib,json,urllib.request,zipfile,tarfile,pathlib,concurrent.futures
root=pathlib.Path(__file__).parent
p=root/'Dependencies'
meta=json.loads((p/'resolved.json').read_text())
locked=json.loads((p/'downloads.lock.json').read_text()) if (p/'downloads.lock.json').exists() else {}
def download(url,name,sha=None,kind='sha256'):
 f=p/name
 if name in locked: sha=locked[name]['hash'];kind=locked[name]['algorithm']
 if not f.exists():
  urllib.request.urlretrieve(url,f)
 digest=hashlib.new(kind,f.read_bytes()).hexdigest()
 if sha and digest.lower()!=sha.lower(): raise RuntimeError('Checksum mismatch: '+name)
 print(name, f.stat().st_size, kind, digest,flush=True)
 return f,digest
jobs=[(meta['sdk']['url'],'dotnet-sdk.tar.gz',meta['sdk']['hash'],'sha512'),
('https://github.com/GyanD/codexffmpeg/releases/download/7.1.1/ffmpeg-7.1.1-essentials_build.zip','ffmpeg-7.1.1.zip',None,'sha256'),
('https://go.microsoft.com/fwlink/p/?LinkId=2124703','MicrosoftEdgeWebview2Setup.exe',None,'sha256')]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex: results=list(ex.map(lambda a:download(*a),jobs))
lock={name:{'url':url,'hash':digest,'algorithm':kind} for (url,name,sha,kind),(file,digest) in zip(jobs,results)}
(p/'downloads.lock.json').write_text(json.dumps(lock,indent=2))
sdk=p/'dotnet';sdk.mkdir(exist_ok=True)
with tarfile.open(results[0][0]) as z:z.extractall(sdk,filter='data')
engine=p/'ffmpeg';engine.mkdir(exist_ok=True)
with zipfile.ZipFile(results[1][0]) as z:
 for n in z.namelist():
  if n.endswith(('/bin/ffmpeg.exe','/bin/ffprobe.exe')) or '/doc/' in n or n.endswith(('/LICENSE','/LICENSE.txt','/README.txt')):
   dest=engine/pathlib.Path(n).name
   if not n.endswith('/'):dest.write_bytes(z.read(n))
print('Dependencies ready.',flush=True)
