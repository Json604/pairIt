#!/usr/bin/env python3
"""Render repeatable listening material, not relay unit tests.

Run with artifacts/corpus/venv/bin/python. NumPy and Pillow are the only Python
dependencies; ffmpeg, ffprobe, and macOS say supply media encoding and speech.
"""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import json
import shutil
import subprocess
import wave

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/corpus/public'
WORK = ROOT / 'artifacts/corpus/work'
SOURCE = ROOT / 'artifacts/corpus/sources/tears-of-steel-720p.mov'
FONT = '/System/Library/Fonts/Supplemental/Arial.ttf'
MONO = '/System/Library/Fonts/Menlo.ttc'
BG, FG, MUTED, ACCENT = '#101c21', '#f2f3ec', '#a6b8bd', '#efba68'

CLIPS = [
    dict(id='01', title='Picture meets sound', kind='sync', seconds=45, rate=48000,
         instruction='The tone should land exactly when the amber square lights up.',
         detail='One cue every second. Judge the square; the moving dot helps show early or late sound.'),
    dict(id='02', title='Clean sustained tone', kind='tone', seconds=60, rate=48000,
         instruction='Listen for clicks, roughness, interruptions, or sudden changes.',
         detail='A steady 440 Hz tone. Only the first and last 50 ms fade; there are no intentional clicks.'),
    dict(id='03', title='Smooth musical texture', kind='texture', seconds=90, rate=48000,
         instruction='Listen for unwanted ticks or breaks in the smooth sound.',
         detail='Original synthesized chords with gentle crossfades. There are no drums or sharp attacks.'),
    dict(id='04', title='Silence, then sound', kind='silence', seconds=96, rate=48000,
         instruction='At each amber cue, sound should return promptly and stay clean.',
         detail='Deliberate silent gaps of 1, 5, 15, 30, and 2 seconds are labeled on screen.'),
    dict(id='05', title='Seek and identify', kind='seek', seconds=60, rate=48000,
         instruction='Seek around. The spoken chapter must match the new picture.',
         detail='Twelve five-second chapters. A tone marks each boundary; the chapter is spoken 300 ms later.'),
    dict(id='06', title='Natural dialogue', kind='film', seconds=75, rate=48000, sourceStart=375,
         instruction='Watch mouth movements, especially short, sharp syllables.',
         detail='Human dialogue from Tears of Steel. Compare with direct playback; the film is not a calibrated timing source.'),
    dict(id='07', title='Dialogue and effects', kind='film', seconds=60, rate=48000, sourceStart=440,
         instruction='Check speech sync and breaks through a busier soundtrack.',
         detail='Tears of Steel dialogue and effects. Effects in the original are intentional; compare the same passage directly.'),
    dict(id='08', title='Left, right, both', kind='stereo', seconds=36, rate=48000,
         instruction='Match the highlighted side to the sound in your headphones.',
         detail='Alternating left, right, and both channels, with spoken labels. Quiet intervals between cues are intentional.'),
    dict(id='09', title='Ten-minute steady run', kind='endurance', seconds=600, rate=48000,
         instruction='Leave this running. Log any crackle, gap, or change in sync.',
         detail='Continuous original musical texture. A deliberate tone and amber square appear every ten seconds.'),
    dict(id='10', title='44.1 kHz source', kind='sync', seconds=45, rate=44100,
         instruction='Repeat the sync check with a different source sample rate.',
         detail='The file is 44.1 kHz. The operating system may resample it; this does not force a Bluetooth route rate change.'),
    dict(id='R0', title='Reference: aligned', kind='sync', seconds=12, rate=48000, reference=True, offset=0,
         instruction='Reference: the picture and tone are aligned in the file.',
         detail='Use direct playback to learn the reference. Your playback path can still add an offset.'),
    dict(id='R1', title='Reference: audio early', kind='sync', seconds=12, rate=48000, reference=True, offset=-0.12,
         instruction='Deliberate offset: the tone leads the square by 120 ms.',
         detail='Training material only. Do not score this deliberate mismatch as a relay failure.'),
    dict(id='R2', title='Reference: audio late', kind='sync', seconds=12, rate=48000, reference=True, offset=0.12,
         instruction='Deliberate offset: the tone follows the square by 120 ms.',
         detail='Training material only. Do not score this deliberate mismatch as a relay failure.'),
]


def run(args, **kw):
    return subprocess.run(args, check=True, **kw)


def text(draw, xy, value, size=24, fill=FG, mono=False):
    draw.text(xy, value, font=ImageFont.truetype(MONO if mono else FONT, size), fill=fill)


def plate(clip):
    image = Image.new('RGB', (1280, 720), BG)
    d = ImageDraw.Draw(image)
    text(d, (56, 36), 'AUDIO RELAY  /  LISTENING CORPUS', 19, MUTED)
    text(d, (56, 104), clip['id'], 72, ACCENT, True)
    text(d, (200, 117), clip['title'], 42)
    text(d, (56, 199), clip['instruction'], 25)
    d.rounded_rectangle((56, 260, 1224, 558), radius=12, fill='#17292f', outline='#3c545c')
    if clip['kind'] in ('sync', 'seek', 'endurance', 'silence'):
        text(d, (90, 285), 'PICTURE CUE', 20, MUTED)
        d.rectangle((1064, 288, 1152, 376), fill='#31444b')
        cue_text = 'Tone starts when the square lights up.'
        if clip.get('offset',0)<0: cue_text='Reference: tone starts 120 ms BEFORE the square.'
        if clip.get('offset',0)>0: cue_text='Reference: tone starts 120 ms AFTER the square.'
        text(d, (90, 337), cue_text, 27)
        if clip['kind'] in ('sync', 'endurance'):
            d.line((120, 459, 1160, 459), fill='#647e88', width=2)
            for x, label in [(120, '-500 ms'), (380, '-250'), (640, 'CUE'), (900, '+250'), (1160, '+500 ms')]:
                d.line((x, 441, x, 477), fill=ACCENT if x == 640 else '#647e88', width=3)
                text(d, (x - 33, 490), label, 18, ACCENT if x == 640 else MUTED)
        elif clip['kind'] == 'seek':
            text(d, (90, 475), 'Use the player controls to jump backward and forward.', 24, MUTED)
    elif clip['kind'] == 'stereo':
        for x, label in [(120, 'LEFT'), (510, 'RIGHT'), (910, 'BOTH')]:
            text(d, (x, 370), label, 43, MUTED)
    else:
        text(d, (90, 307), 'CLEAN SOURCE', 20, ACCENT)
        text(d, (90, 363), 'No intentional clicks or dropouts.', 37)
        text(d, (90, 430), 'Notice a fault? Mark it in the test player.', 27, MUTED)
    text(d, (56, 610), 'ELAPSED', 18, MUTED)
    text(d, (850, 610), f"{clip['rate']/1000:g} kHz  /  stereo  /  60 fps", 18, MUTED)
    text(d, (56, 680), 'LOCAL TEST MATERIAL  •  Comfortable listening volume  •  No microphone recording', 17, MUTED)
    name = WORK / f"{clip['id']}-plate.png"
    image.save(name)
    return name


def pulse(rate):
    t = np.arange(round(.025 * rate), dtype=np.float64) / rate
    envelope = np.minimum(1, np.minimum(t / .002, (.025 - t) / .002))
    return (.20 * np.sin(2 * np.pi * 1000 * t) * envelope).astype(np.float32)


def add(audio, sample, time, rate, channel=None):
    start = round(time * rate)
    end = min(len(audio), start + len(sample))
    if start < 0 or end <= start: return
    sample = sample[:end-start]
    if channel is None: audio[start:end] += sample[:, None]
    else: audio[start:end, channel] += sample


def fade(audio, rate, seconds=.05):
    n = min(round(seconds * rate), len(audio)//2)
    ramp = np.linspace(0, 1, n, dtype=np.float32)[:, None]
    audio[:n] *= ramp
    audio[-n:] *= ramp[::-1]


def texture(seconds, rate):
    audio = np.zeros((round(seconds * rate), 2), dtype=np.float32)
    chords = [(130.81,164.81,196.00), (110.00,130.81,164.81), (87.31,110.00,130.81), (98.00,123.47,146.83)]
    for k, center in enumerate(range(0, seconds + 9, 8)):
        start, end = max(0,center-8), min(seconds,center+8)
        t = np.arange(round(start*rate), round(end*rate), dtype=np.float64) / rate
        weight = np.cos(np.pi * (t-center) / 16) ** 2
        freqs = chords[k % len(chords)]
        for channel in range(2):
            signal = sum(np.sin(2*np.pi*f*t + channel*.12) + .2*np.sin(4*np.pi*f*t + channel*.24) for f in freqs)
            audio[round(start*rate):round(end*rate), channel] += (.038*weight*signal).astype(np.float32)
    fade(audio, rate, .3)
    return audio


def speech(word, rate):
    aiff = WORK / f"voice-{word}.aiff"
    if not aiff.exists(): run(['say', '-v', 'Daniel', '-r', '165', '-o', str(aiff), word])
    data = subprocess.check_output(['ffmpeg','-v','error','-i',str(aiff),'-af',
        'silenceremove=start_periods=1:start_duration=0.01:start_threshold=-50dB',
        '-ar',str(rate),'-ac','1','-f','f32le','-'])
    samples = np.frombuffer(data,dtype='<f4').copy()
    peak = float(np.max(np.abs(samples)))
    if peak: samples *= .22 / peak
    return samples


def audio_for(clip):
    rate, duration, kind = clip['rate'], clip['seconds'], clip['kind']
    audio = texture(duration,rate) if kind in ('texture','endurance') else np.zeros((duration*rate,2),np.float32)
    events=[]
    if kind == 'sync':
        for second in range(1,duration):
            at=second+clip.get('offset',0)
            add(audio,pulse(rate),at,rate)
            events.append(dict(visual=second,audio=at))
    elif kind == 'tone':
        t=np.arange(duration*rate,dtype=np.float64)/rate
        audio[:]=(.075*np.sin(2*np.pi*440*t))[:,None]
        fade(audio,rate)
    elif kind == 'endurance':
        for second in range(10,duration,10):
            add(audio,pulse(rate),second,rate)
            events.append(dict(visual=second,audio=second))
    elif kind == 'silence':
        clip['soundWindows']=[[3,8],[9,14],[19,24],[39,44],[74,84],[86,96]]
        for start,end in clip['soundWindows']:
            t=np.arange((end-start)*rate,dtype=np.float64)/rate
            sound=np.repeat((.065*np.sin(2*np.pi*440*t))[:,None],2,axis=1).astype(np.float32)
            fade(sound,rate,.03)
            audio[start*rate:end*rate] += sound
            add(audio,pulse(rate),start,rate)
            events.append(dict(visual=start,audio=start))
    elif kind == 'seek':
        words=['one','two','three','four','five','six','seven','eight','nine','ten','eleven','twelve']
        for k,word in enumerate(words):
            add(audio,pulse(rate),k*5,rate)
            add(audio,speech('Chapter '+word,rate),k*5+.3,rate)
            events.append(dict(visual=k*5,audio=k*5))
    elif kind == 'stereo':
        for k in range(12):
            label=['Left','Right','Both'][k%3]
            channel=[0,1,None][k%3]
            add(audio,pulse(rate),k*3+1,rate,channel)
            add(audio,speech(label,rate),k*3+1.3,rate,channel)
    peak=float(np.max(np.abs(audio)))
    if peak >= .9: raise ValueError(f"Unexpected source peak: {clip['id']} {peak}")
    clip['events']=events
    clip['sourcePeakDbfs']=round(20*np.log10(max(peak,1e-12)),2)
    wav=WORK/f"{clip['id']}.wav"
    with wave.open(str(wav),'wb') as f:
        f.setnchannels(2);f.setsampwidth(2);f.setframerate(rate)
        f.writeframes((audio*32767).astype('<i2').tobytes())
    return wav


def drawtext(value,x,y,size=28,color='0xf2f3ec',enable=None):
    result=f"drawtext=fontfile='{FONT}':text='{value}':x='{x}':y='{y}':fontsize={size}:fontcolor={color}"
    if enable: result+=f":enable='{enable}'"
    return result


def render(clip, force=False):
    filename=f"{clip['id']}-{clip['kind']}.mp4"
    clip['src']='media/'+filename
    path=OUT/clip['src']
    if clip['kind']=='film':
        clip['attribution']='Tears of Steel (2012), (CC) Blender Foundation | mango.blender.org — CC BY 3.0. Excerpt, scaled, labeled, and audio attenuated for this corpus.'
        clip['licenseUrl']='https://creativecommons.org/licenses/by/3.0/'
        clip['sourceUrl']='https://mango.blender.org/sharing/'
        clip['fps']=24
        if force or not path.exists():
            vf=','.join(['scale=1280:534','pad=1280:720:0:82:color=0x101c21',
                drawtext(clip['id']+' / '+clip['title'],32,25,28),
                drawtext('Tears of Steel | (CC) Blender Foundation | mango.blender.org | CC BY 3.0',32,658,20),
                drawtext("%{pts\\:hms}",32,625,21)])
            run(['ffmpeg','-hide_banner','-loglevel','error','-y','-ss',str(clip['sourceStart']),'-i',str(SOURCE),
                '-t',str(clip['seconds']),'-vf',vf,'-af','volume=0.7','-ar',str(clip['rate']),'-ac','2',
                '-c:v','libx264','-threads','2','-preset','veryfast','-crf','20','-pix_fmt','yuv420p',
                '-c:a','aac','-b:a','256k','-movflags','+faststart',str(path)])
    else:
        clip['fps']=60
        wav=audio_for(clip)
        if force or not path.exists():
            filters=[drawtext("%{pts\\:hms}",56,637,27)]
            events=clip.get('events',[])
            if events:
                expr='+'.join(f'between(n,{round(e["visual"]*60)},{round(e["visual"]*60)+2})' for e in events)
                filters.append(f"drawbox=x=1064:y=288:w=88:h=88:color=0xefba68:t=fill:enable='{expr}'")
            kind=clip['kind']
            if kind in ('sync','endurance'):
                # Text x evaluates every frame; the dot crosses the center at integer seconds.
                enable = 'gte(t,9.5)*lt(mod(t+0.5,10),1)' if kind=='endurance' else None
                filters.append(drawtext('●',"120+1040*mod(t+0.5,1)-12",435,32,'0xefba68',enable))
            if kind=='seek':
                for k in range(12): filters.append(drawtext(f'CHAPTER {k+1:02}',90,409,41,enable=f'gte(t,{k*5})*lt(t,{(k+1)*5})'))
            if kind=='silence':
                for start,end in clip['soundWindows']:
                    filters.append(drawtext('SOUND',90,444,37,'0xefba68',f'gte(t,{start})*lt(t,{end})'))
                gaps=[(0,3),(8,9),(14,19),(24,39),(44,74),(84,86)]
                for start,end in gaps:
                    filters.append(drawtext(f'INTENTIONAL SILENCE / {end-start} seconds',90,444,32,'0xa6b8bd',f'gte(t,{start})*lt(t,{end})'))
            if kind=='stereo':
                for k in range(12):
                    x=[95,485,885][k%3]
                    filters.append(f"drawbox=x={x}:y=337:w=275:h=110:color=0xefba68:t=3:enable='gte(t,{k*3})*lt(t,{(k+1)*3})'")
            run(['ffmpeg','-hide_banner','-loglevel','error','-y','-loop','1','-framerate','60','-i',str(plate(clip)),
                '-i',str(wav),'-t',str(clip['seconds']),'-vf',','.join(filters),
                '-c:v','libx264','-threads','2','-preset','veryfast','-crf','21','-pix_fmt','yuv420p',
                '-c:a','aac','-b:a','256k','-ar',str(clip['rate']),'-movflags','+faststart',str(path)])
    clip['sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    clip['bytes']=path.stat().st_size
    print('Rendered',clip['id'],clip['title'],flush=True)
    return clip


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--force',action='store_true');parser.add_argument('--only',nargs='*')
    args=parser.parse_args()
    OUT.joinpath('media').mkdir(parents=True,exist_ok=True);WORK.mkdir(parents=True,exist_ok=True)
    selected=[c for c in CLIPS if not args.only or c['id'] in args.only]
    # Keep generation bounded so it doesn't overload the development Mac.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda c: render(c,args.force),selected))
    if args.only: return
    manifest=dict(version='2026-11-05.1',clips=CLIPS,quickRun=['01','02','04','06'],
        sourceFilmSha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest())
    OUT.joinpath('manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    OUT.joinpath('manifest.js').write_text('window.CORPUS = '+json.dumps(manifest)+';\n')
    for name in ['index.html','app.js','style.css','GUIDE.md','ATTRIBUTION.md']:
        source=ROOT/'test-corpus'/name
        if source.exists(): shutil.copy2(source,OUT/name)
    print('Corpus ready:',OUT,flush=True)


if __name__=='__main__': main()
