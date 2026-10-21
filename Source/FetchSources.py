from pathlib import Path
import hashlib, subprocess
root=Path(__file__).resolve().parent.parent/'ThirdPartySources'
root.mkdir(exist_ok=True)
sources=[
 ('ffmpeg-8.0.1.tar.xz','https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz','05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41'),
 ('x264-c24e06c.tar.gz','https://github.com/mirror/x264/archive/c24e06c2e184345ceb33eb20a15d1024d9fd3497.tar.gz','090d730e867fc63631782a1287974635d1237d0fa7c6fd1d09fd543620a56689'),
 ('dav1d-1.5.1.tar.gz','https://github.com/videolan/dav1d/archive/refs/tags/1.5.1.tar.gz','fa635e2bdb25147b1384007c83e15de44c589582bb3b9a53fc1579cb9d74b695'),
 ('pkgconf-2.4.3.tar.xz','https://distfiles.dereferenced.org/pkgconf/pkgconf-2.4.3.tar.xz','51203d99ed573fa7344bf07ca626f10c7cc094e0846ac4aa0023bd0c83c25a41')]
for name,url,sha in sources:
    p=root/name
    if not p.exists(): subprocess.run(['curl','-fL','--retry','2',url,'-o',str(p)],check=True)
    if hashlib.sha256(p.read_bytes()).hexdigest()!=sha: raise SystemExit('Source checksum mismatch: '+name)
    print('Verified: '+name)
