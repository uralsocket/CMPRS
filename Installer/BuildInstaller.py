#!/usr/bin/env python3
from pathlib import Path
import argparse,subprocess,shutil,plistlib
p=argparse.ArgumentParser();p.add_argument('--app',required=True);p.add_argument('--identity',default='-');p.add_argument('--output-dir',default='SetupBuild');a=p.parse_args()
root=Path(__file__).resolve().parents[1];build=root/a.output_dir;build.mkdir(exist_ok=True);bundle=build/'Install CMPRS.app';contents=bundle/'Contents';resources=contents/'Resources';mac=contents/'MacOS';helpers=contents/'Helpers'
for d in [resources,mac,helpers]:d.mkdir(parents=True,exist_ok=True)
def run(args):subprocess.run([str(x) for x in args],check=True)
parts=[]
app=Path(a.app).resolve()
appArchs=subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/CMPRS')],text=True).split()
for arch in appArchs:
 part=build/('CMPRSSetup-'+arch);run(['xcrun','swiftc','-swift-version','5','-suppress-warnings','-O','-target',arch+'-apple-macos13','-module-cache-path',build/'modules',root/'Installer/InstallCore.swift',root/'Installer/InstallerMain.swift','-o',part]);parts.append(part)
if len(parts)>1:run(['xcrun','lipo','-create',*parts,'-output',mac/'CMPRSSetup'])
else:shutil.copy2(parts[0],mac/'CMPRSSetup')
app=Path(a.app).resolve();target=helpers/'CMPRS.app'
if target.exists():shutil.rmtree(target)
run(['/usr/bin/ditto',app,target])
shutil.copy2(root/'Resources/CMPRS-Eye.icns',resources/'CMPRS-Eye.icns')
licenses=resources/'Licenses';licenses.mkdir(exist_ok=True);shutil.copy2(root/'LICENSE',licenses/'LICENSE')
info={'CFBundleIdentifier':'com.glebkaravaev.cmprs.setup','CFBundleName':'Install CMPRS','CFBundleDisplayName':'Install CMPRS','CFBundleExecutable':'CMPRSSetup','CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.0.0','CFBundleVersion':'15','CFBundleIconFile':'CMPRS-Eye.icns','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ru'],'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'© 2026 Gleb Karavaev. AGPL-3.0-or-later.'}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
cmd=['codesign','--force','--options','runtime','--sign',a.identity]
if a.identity!='-':cmd+=['--timestamp']
run(cmd+[bundle]);run(['codesign','--verify','--deep','--strict',bundle]);print(bundle)
