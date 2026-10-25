#!/usr/bin/env python3
"""Build the compact React app with the bundled GPL FFmpeg/x264 engine."""
from pathlib import Path
import argparse,subprocess,shutil,plistlib,os
p=argparse.ArgumentParser();p.add_argument('--identity',default='-');p.add_argument('--arch',choices=['universal','arm64','x86_64'],default='arm64');p.add_argument('--output-dir',default='Build');a=p.parse_args()
r=Path(__file__).resolve().parent;build=r/a.output_dir;build.mkdir(parents=True,exist_ok=True);app=build/'CMPRS.app';contents=app/'Contents';res=contents/'Resources';helpers=contents/'Helpers';mac=contents/'MacOS'
for d in [res,helpers,mac]:d.mkdir(parents=True,exist_ok=True)
cache=build/'module-cache';archs=['arm64','x86_64'] if a.arch=='universal' else [a.arch]
def run(cmd,**kw):subprocess.run([str(x) for x in cmd],check=True,**kw)
def compile(name,sources,destination):
 binaries=[]
 for arch in archs:
  output=build/f'{name}-{arch}'
  run(['xcrun','swiftc','-swift-version','5','-suppress-warnings','-O','-target',arch+'-apple-macos13','-module-cache-path',cache,*[r/'Native'/s for s in sources],'-o',output]);binaries.append(output)
 if len(binaries)>1:run(['xcrun','lipo','-create',*binaries,'-output',destination])
 else:shutil.copy2(binaries[0],destination)
# Never label an app universal when its required encoder is architecture-specific.
engineSource=r/'Resources/bin'
for name in ['ffmpeg','ffprobe']:
 source=engineSource/name
 available=subprocess.check_output(['lipo','-archs',str(source)],text=True).split()
 assert all(arch in available for arch in archs),f'{name} needs architectures: {archs}, available: {available}'
 (res/'bin').mkdir(exist_ok=True)
 shutil.copy2(source,res/'bin'/name)
compile('CMPRS',['Media.swift','MemoryProcess.swift','Compressor.swift','EngineRunner.swift','FinderRequest.swift','AppMain.swift'],mac/'CMPRS')
ui=r/'UI/dist';assert (ui/'app.js').exists(),'Run the UI build first.'
shutil.copytree(ui,res/'UI',dirs_exist_ok=True)
icon=r/'Resources/CMPRS-Eye.icns';shutil.copy2(icon,res/'CMPRS-Eye.icns')
manifest={'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ru'],'CFBundleDisplayName':'CMPRS','CFBundleName':'CMPRS','CFBundleIdentifier':'com.glebkaravaev.cmprs','CFBundleExecutable':'CMPRS','CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.0.0','CFBundleVersion':'15','CFBundleIconFile':'CMPRS-Eye.icns','LSMinimumSystemVersion':'13.0','LSApplicationCategoryType':'public.app-category.video','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'© 2026 Gleb Karavaev. AGPL-3.0-or-later. FFmpeg/x264: GPL. React: MIT.','CFBundleDocumentTypes':[{'CFBundleTypeName':'Video','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['public.movie','public.video']},{'CFBundleTypeName':'CMPRS Finder Request','CFBundleTypeRole':'Viewer','LSHandlerRank':'Owner','LSItemContentTypes':['com.glebkaravaev.cmprs.request']}],'UTImportedTypeDeclarations':[{'UTTypeIdentifier':'com.glebkaravaev.cmprs.request','UTTypeDescription':'CMPRS Finder Request','UTTypeConformsTo':['public.data'],'UTTypeTagSpecification':{'public.filename-extension':['cmprsrequest']}}]}
manifest['NSServices']=[{'NSMenuItem':{'default':'CMPRS — Compress video'},'NSMessage':'compressSelection','NSPortName':'CMPRS','NSRequiredContext':{},'NSRestricted':False,'NSSendFileTypes':['public.movie','public.video'],'NSSendTypes':['public.file-url','NSFilenamesPboardType'],'NSTimeout':'30000'}]
for language,title in [('en','CMPRS — Compress video'),('ru','CMPRS — Сжать видео')]:
 local=res/(language+'.lproj');local.mkdir(exist_ok=True)
 (local/'ServicesMenu.strings').write_text('"CMPRS — Compress video" = "'+title+'";\n',encoding='utf-8')
with (contents/'Info.plist').open('wb') as f:plistlib.dump(manifest,f)
privacy={'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyCollectedDataTypes':[],'NSPrivacyAccessedAPITypes':[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryUserDefaults','NSPrivacyAccessedAPITypeReasons':['CA92.1']},{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryFileTimestamp','NSPrivacyAccessedAPITypeReasons':['C617.1','3B52.1']} ]}
with (res/'PrivacyInfo.xcprivacy').open('wb') as f:plistlib.dump(privacy,f)
licenseFolder=res/'Licenses';licenseFolder.mkdir(exist_ok=True)
for name in ['LICENSE','NOTICE.md']:
 if (r/name).exists():shutil.copy2(r/name,licenseFolder/name)
for source in (r/'Resources/ThirdPartyLicenses').glob('*'):
 if source.is_file():shutil.copy2(source,licenseFolder/source.name)
for name in ['react','react-dom']:
 source=r/'Resources/ThirdPartyLicenses'/(name+'.txt')
 if not source.exists():source=r/'UI/node_modules'/name/'LICENSE'
 if source.exists():shutil.copy2(source,licenseFolder/(name+'.txt'))
sign=['codesign','--force','--options','runtime','--sign',a.identity]
if a.identity!='-':sign+=['--timestamp']
for name in ['ffmpeg','ffprobe']:run(sign+['--entitlements',r/'Helper.entitlements',res/'bin'/name])
run(sign+['--entitlements',r/'App.entitlements',app])
run(['codesign','--verify','--deep','--strict',app])
print(app)
