from pathlib import Path
import shutil,subprocess,plistlib
root=Path(__file__).resolve().parent.parent
app=root/'CMPRS Ironclad.app';content=app/'Contents';res=content/'Resources'
(content/'MacOS').mkdir(parents=True,exist_ok=True);(res/'bin').mkdir(parents=True,exist_ok=True)
shutil.copy2(root/'Resources/Info.plist',content/'Info.plist')
for name in ['ffmpeg','ffprobe']:shutil.copy2(root/'build/prefix/bin'/name,res/'bin'/name)
for name in ['Source','Licenses']:shutil.copytree(root/name,res/name,dirs_exist_ok=True)
shutil.copytree(root/'Resources/CMPRS Ironclad 100%.workflow',root/'CMPRS Ironclad 100%.workflow',dirs_exist_ok=True)
workflow=root/'CMPRS Ironclad 100%.workflow/Contents/document.wflow'
w=plistlib.loads(workflow.read_bytes());w['workflowMetaData']['customImageFileData']=(root/'Artwork/CMPRS-Icon.png').read_bytes();workflow.write_bytes(plistlib.dumps(w))
iconset=root/'build/CMPRS.iconset';iconset.mkdir(parents=True,exist_ok=True)
for size in [16,32,128,256,512]:
    for scale in [1,2]:
        name=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
        subprocess.run(['sips','-s','format','png','-z',str(size*scale),str(size*scale),str(root/'Artwork/CMPRS-Icon.png'),'--out',str(iconset/name)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(root/'Artwork/CMPRS.icns')],check=True)
shutil.copy2(root/'Artwork/CMPRS.icns',res/'CMPRS.icns')
print(app)
