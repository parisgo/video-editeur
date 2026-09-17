#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/VideoEditeur.app/Contents/MacOS/VideoEditeur"
if [ ! -x "$APP" ]; then ./scripts/build-app.sh; fi
CHECK_DIR="$(mktemp -d /tmp/video-editeur-smoke.XXXXXX)"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=24:duration=3 -f lavfi -i sine=frequency=440:duration=3 -c:v libx264 -pix_fmt yuv420p -c:a aac "$CHECK_DIR/横屏 sample.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=360x640:rate=30:duration=3 -c:v libx264 -pix_fmt yuv420p "$CHECK_DIR/portrait.mp4"
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i "$CHECK_DIR/横屏 sample.mp4" -c copy "$CHECK_DIR/rotated.mp4"
"$APP" --smoke-export "$CHECK_DIR/横屏 sample.mp4" "$CHECK_DIR/landscape-out.mp4"
"$APP" --smoke-export "$CHECK_DIR/portrait.mp4" "$CHECK_DIR/portrait-out.mp4"
"$APP" --smoke-export "$CHECK_DIR/rotated.mp4" "$CHECK_DIR/rotated-out.mp4"
"$APP" --smoke-services "$CHECK_DIR/横屏 sample.mp4" "$CHECK_DIR/services"
python3 - "$CHECK_DIR" <<'PY'
import json, subprocess, sys
from pathlib import Path
for name,width,height,audio in [('landscape',640,360,True),('portrait',360,640,False),('rotated',360,640,True)]:
    path=Path(sys.argv[1])/(name+'-out.mp4')
    data=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-of','json',str(path)]))
    streams=data['streams']; video=next(x for x in streams if x['codec_type']=='video')
    assert (video['width'],video['height'],video['codec_name'])==(width,height,'h264'),video
    assert abs(float(video['duration'])-3)<0.05,video
    tracks=[x for x in streams if x['codec_type']=='audio']
    assert bool(tracks)==audio
    if audio: assert tracks[0]['codec_name']=='aac'
    print('PASS',name,'codec, dimensions, duration, audio')
print('Artifacts:',sys.argv[1])
PY
