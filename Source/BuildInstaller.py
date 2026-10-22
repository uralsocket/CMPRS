from pathlib import Path
import shutil, plistlib, sys
package=Path(__file__).resolve().parent.parent
stage=Path(sys.argv[1]) if len(sys.argv)>1 else package/'Installer-build'; stage.mkdir(parents=True,exist_ok=True)
app=stage/'CMPRS Installer.app'
contents=app/'Contents';resources=contents/'Resources'
(contents/'MacOS').mkdir(parents=True,exist_ok=True)
resources.mkdir(exist_ok=True)
info={'CFBundleIdentifier':'local.gleb.cmprs-installer','CFBundleName':'CMPRS Installer','CFBundleDisplayName':'CMPRS Installer','CFBundleExecutable':'CMPRSInstaller','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.6','CFBundleVersion':'8','CFBundleIconFile':'CMPRS.icns','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ru'],'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.utilities','NSHumanReadableCopyright':'© 2026 Gleb Karavaev. AGPL-3.0-or-later.'}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copy2(package/'Artwork/CMPRS.icns',resources/'CMPRS.icns')
for locale,name in [('en','Install CMPRS'),('ru','Установить CMPRS')]:
 (resources/(locale+'.lproj')).mkdir(exist_ok=True)
 (resources/(locale+'.lproj')/'InfoPlist.strings').write_text('"CFBundleDisplayName" = "'+name+'";\n')
licensepath=resources/'Licenses'
if not licensepath.exists():shutil.copytree(package/'Licenses',licensepath)
source=resources/'Source';source.mkdir(exist_ok=True)
shutil.copy2(package/'Source/Installer.swift',source/'Installer.swift')
(source/'Build.txt').write_text('xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 Installer.swift -framework AppKit -o CMPRSInstaller\nContents/Helpers: CMPRS Ironclad.app. Resources/Payload: CMPRS Ironclad 100%.workflow.\nThe complete source and build scripts are distributed separately in CMPRS-Ironclad.zip.\n')
payload=resources/'Payload';payload.mkdir(exist_ok=True)
# Nested executables belong in a standard code location. This keeps the inner
# notarization ticket outside the outer resource seal after Xcode re-signing.
helpers=contents/'Helpers';helpers.mkdir(exist_ok=True)
main=helpers/'CMPRS Ironclad.app'
if main.exists():shutil.rmtree(main)
shutil.copytree(package/'CMPRS Ironclad.app',main)
legacy=payload/'CMPRS Ironclad.app'
if legacy.exists():shutil.rmtree(legacy)
for name in ['CMPRS Ironclad 100%.workflow']:
 dest=payload/name
 if dest.exists():shutil.rmtree(dest)
 shutil.copytree(package/name,dest)
print(app)
