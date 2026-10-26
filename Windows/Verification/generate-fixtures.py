import pathlib,subprocess,concurrent.futures,json,os
root=pathlib.Path(__file__).resolve().parent.parent
p=root/'Build/Fixtures';p.mkdir(exist_ok=True)
bin=root.parent/'CMPRS-Compact/Resources/bin';ff=str(bin/'ffmpeg')
def make(name,video,extra=(),duration='1',audio=False):
 args=[ff,'-y','-hide_banner','-loglevel','error','-f','lavfi','-i',video]
 if audio:args+=['-f','lavfi','-i','anullsrc=r=48000:cl=5.1']
 args+=['-t',duration]+(list(extra) if '-c:v' in extra else ['-c:v','prores_ks','-profile:v','1','-pix_fmt','yuv422p10le']+list(extra))
 if audio:args+=['-c:a','pcm_s16le']
 args+=[str(p/name)]
 subprocess.run(args,check=True)
 print(name,flush=True)
jobs=[('normal.mov','testsrc2=size=960x540:rate=30',('-c:v','libx264','-preset','ultrafast','-crf','0','-pix_fmt','yuv420p'),'2',False),
('120fps.mov','testsrc2=size=320x180:rate=120',('-c:v','libx264','-preset','ultrafast','-crf','0','-pix_fmt','yuv420p'),'1',False),
('4k.mov','testsrc2=size=3840x2160:rate=24',('-c:v','libx264','-preset','ultrafast','-crf','0','-pix_fmt','yuv420p'),'0.5',False),
('portrait.mov','testsrc2=size=360x640:rate=30',('-c:v','libx264','-preset','ultrafast','-crf','0','-pix_fmt','yuv420p'),'1',False),
('vfr.mov','testsrc2=size=320x180:rate=30',('-vf','setpts=if(lt(N\\,15)\\,N/30/TB\\,(15/30+(N-15)/15)/TB)','-fps_mode','vfr','-c:v','libx264','-crf','0','-pix_fmt','yuv420p'),'1.5',False),
('audio-surround.mov','testsrc2=size=320x180:rate=30',('-c:v','libx264','-crf','0','-pix_fmt','yuv420p'),'1',True),
('10bit.mov','testsrc2=size=320x180:rate=30',(),'1',False),
('hdr.mov','testsrc2=size=320x180:rate=30',('-c:v','libx264','-crf','0','-pix_fmt','yuv420p10le','-vf','setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc','-x264-params','colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc'),'1',False),
('alpha.mov','color=red:size=320x180:rate=30',('-vf','format=yuva444p10le','-profile:v','4','-pix_fmt','yuva444p10le'),'1',False),
('odd.mkv','testsrc=size=321x181:rate=30',('-c:v','ffv1','-pix_fmt','yuv444p'),'1',False),
('small.mp4','color=black:size=320x180:rate=30',('-c:v','libx264','-crf','51','-pix_fmt','yuv420p'),'1',False)]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
 for result in ex.map(lambda job:make(*job),jobs):pass
subprocess.run([ff,'-y','-v','error','-i',str(p/'portrait.mov'),'-c','copy','-metadata:s:v:0','rotate=90',str(p/'rotation.mov')],check=True)
(p/'invalid.mov').write_text('not a video')
(p/'source.json').write_bytes(subprocess.check_output([str(bin/'ffprobe'),'-v','error','-show_streams','-show_format','-of','json',str(p/'normal.mov')]))
stalled=p/'stalled';stalled.mkdir(exist_ok=True)
(stalled/'ffprobe').write_text('#!/usr/bin/python3\nimport time\ntime.sleep(60)\n');(stalled/'ffprobe').chmod(0o755)
stalled=p/'encode-stalled';stalled.mkdir(exist_ok=True)
(stalled/'ffprobe').symlink_to(bin/'ffprobe')
(stalled/'ffmpeg').write_text('#!/usr/bin/python3\nimport time\nwhile True:\n print("frame=1\\nout_time_us=0\\ntotal_size=1",flush=True)\n time.sleep(.05)\n');(stalled/'ffmpeg').chmod(0o755)
