#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/VideoEditeur.app/Contents/MacOS/VideoEditeur"
CHECK_DIR="$(mktemp -d /tmp/video-editeur-editing.XXXXXX)"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=24:duration=3 -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$CHECK_DIR/a.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=blue:size=360x640:rate=30:duration=3 -f lavfi -i sine=frequency=880:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$CHECK_DIR/b.mp4"
for mode in hlg pq; do
  transfer=arib-std-b67
  if [ "$mode" = pq ]; then transfer=smpte2084; fi
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'nullsrc=size=640x360:rate=24:duration=2,format=yuv420p10le,geq=lum=64+876*X/W:cb=512:cr=512' -c:v libx265 -x265-params "log-level=error:colorprim=bt2020:transfer=$transfer:colormatrix=bt2020nc" -tag:v hvc1 "$CHECK_DIR/$mode.mp4"
done
"$APP" --smoke-editing "$CHECK_DIR"
python3 - "$CHECK_DIR" <<'PY'
import subprocess,json,array,statistics,sys
from pathlib import Path
root=Path(sys.argv[1])
for name in ['edited','hlg-out','pq-out','hlg-sdr','pq-sdr']:
    data=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(root/(name+'.mp4'))]))
    video=next(v for v in data['streams'] if v['codec_type']=='video')
    assert (video['width'],video['height'])==(640,360)
    assert abs(float(video['duration'])-(5 if name=='edited' else 2))<.05
    if name.endswith('-out'):
        assert video['codec_name']=='hevc' and video['pix_fmt']=='yuv420p10le' and video['color_primaries']=='bt2020'
        assert video['color_transfer']==('arib-std-b67' if name.startswith('hlg') else 'smpte2084')
    else:
        assert video['codec_name']=='h264' and video['color_transfer']=='bt709'
    print('PASS',name,'dimensions, duration, codec, color metadata')
for name in ['hlg','pq']:
    def plane(n):
        data=subprocess.check_output(['ffmpeg','-v','error','-i',str(root/(n+'.mp4')),'-frames:v','1','-pix_fmt','yuv420p10le','-f','rawvideo','-'])
        a=array.array('H');a.frombytes(data);return a[:640*100]
    a,b=plane(name),plane(name+'-out');differences=[abs(x-y) for x,y in zip(a,b)]
    assert statistics.mean(differences)<5 and max(b)>930
    assert len(set(y for x,y in zip(a,b) if x>800))>50
    print('PASS',name,'highlight gradient; mean code error',statistics.mean(differences),'max',max(differences))
print('Artifacts:',root)
PY
