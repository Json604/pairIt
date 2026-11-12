#!/usr/bin/env python3
"""Decode the rendered corpus and verify its source timing and audio headroom.

This validates actual media artifacts. It does not measure relay/headphone output
and does not run unit tests or claim that a listening test has passed.
"""
from pathlib import Path
import json
import subprocess
import sys
import numpy as np

ROOT=Path(__file__).resolve().parent.parent
PUBLIC=ROOT/'artifacts/corpus/public'
sys.path.insert(0,str(ROOT/'scripts'))
from importlib.util import spec_from_file_location,module_from_spec
spec=spec_from_file_location('corpus_builder',ROOT/'scripts/build-corpus.py')
builder=module_from_spec(spec);spec.loader.exec_module(builder)


def capture(args): return subprocess.check_output(args)


def verify(clip):
    path=PUBLIC/clip['src']
    info=json.loads(capture(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(path)]))
    video=next(s for s in info['streams'] if s['codec_type']=='video')
    audio=next(s for s in info['streams'] if s['codec_type']=='audio')
    errors=[]
    if (video['width'],video['height'])!=(1280,720): errors.append('Unexpected dimensions')
    if abs(float(info['format']['duration'])-clip['seconds'])>.06: errors.append('Unexpected duration')
    if int(audio['sample_rate'])!=clip['rate'] or audio['channels']!=2: errors.append('Unexpected audio format')
    if abs(float(video.get('start_time',0)))>.001 or abs(float(audio.get('start_time',0)))>.001: errors.append('Nonzero stream start')
    fps_a,fps_b=map(int,video['avg_frame_rate'].split('/'))
    if abs(fps_a/fps_b-clip['fps'])>.001: errors.append('Unexpected video frame rate')
    samples=np.frombuffer(capture(['ffmpeg','-v','error','-xerror','-i',str(path),'-map','0:a:0','-ac','2','-ar',str(clip['rate']),'-f','f32le','-']),dtype='<f4').reshape(-1,2)
    peak=float(np.max(np.abs(samples)))
    if peak>=.999: errors.append('Decoded audio reaches full scale')
    result=dict(id=clip['id'],sha256=clip['sha256'],duration=float(info['format']['duration']),fps=fps_a/fps_b,
                sampleRate=int(audio['sample_rate']),decodedPeakDbfs=round(20*np.log10(max(peak,1e-12)),2),errors=errors)
    events=clip.get('events',[])
    if events:
        values=np.frombuffer(capture(['ffmpeg','-v','error','-xerror','-i',str(path),'-map','0:v:0','-an',
            '-vf','crop=32:32:1090:312,scale=1:1:flags=area,format=gray','-f','rawvideo','-']),dtype=np.uint8)
        bright=values>130
        rises=np.flatnonzero(bright & ~np.r_[False,bright[:-1]])
        expected=np.array([round(e['visual']*60) for e in events])
        result['visualCueCount']=len(rises)
        if not np.array_equal(rises,expected): errors.append('Rendered cue frames differ from the source schedule')
        reference=builder.pulse(clip['rate'])
        offsets=[];source_errors=[]
        mono=samples.mean(axis=1)
        for event in events:
            start=max(0,round((event['audio']-.04)*clip['rate']))
            end=min(len(mono),round((event['audio']+.07)*clip['rate']))
            correlation=np.correlate(mono[start:end],reference,mode='valid')
            detected=(start+int(np.argmax(correlation)))/clip['rate']
            offsets.append((detected-event['visual'])*1000)
            source_errors.append(abs(detected-event['audio'])*1000)
        result['audioMinusVisualMs']={'median':round(float(np.median(offsets)),3),'min':round(min(offsets),3),'max':round(max(offsets),3)}
        result['maximumAudioScheduleErrorMs']=round(max(source_errors),3)
        if max(source_errors)>2: errors.append('Decoded audio cue differs from its intended schedule by more than 2 ms')
    else:
        subprocess.run(['ffmpeg','-v','error','-xerror','-i',str(path),'-map','0:v:0','-an','-f','null','-'],check=True)
    if clip['kind']=='silence':
        levels=[]
        for start,end in [(0,3),(8,9),(14,19),(24,39),(44,74),(84,86)]:
            segment=samples[round((start+.1)*clip['rate']):round((end-.1)*clip['rate'])]
            rms=float(np.sqrt(np.mean(segment.astype(np.float64)**2)))
            levels.append(round(20*np.log10(max(rms,1e-12)),1))
        result['silenceInteriorRmsDbfs']=levels
        if max(levels)>-80: errors.append('Unexpected sound in an intended silence interval')
    result['passed']=not errors
    print(clip['id'],'PASS' if result['passed'] else 'FAIL',errors,flush=True)
    return result


def main():
    manifest=json.loads(PUBLIC.joinpath('manifest.json').read_text())
    results=[verify(clip) for clip in manifest['clips']]
    report={'scope':'Source media only. No headphone-output measurement or relay reliability claim.',
            'corpusVersion':manifest['version'],'passed':all(r['passed'] for r in results),'clips':results}
    PUBLIC.joinpath('verification.json').write_text(json.dumps(report,indent=2)+'\n')
    raise SystemExit(0 if report['passed'] else 1)

if __name__=='__main__':main()
