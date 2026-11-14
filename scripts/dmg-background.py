#!/usr/bin/env python3
"""Render PairIt's deterministic DMG artwork, using the app's blue/black palette."""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
import math,sys
scale=2;w,h=660,420
im=Image.new('RGB',(w*scale,h*scale));pix=im.load()
for y in range(h*scale):
 for x in range(w*scale):
  nx=x/(w*scale);ny=y/(h*scale)
  glow=max(0,1-math.hypot((nx-.06)/1.15,(ny-1)/.9))**2
  pix[x,y]=(int(8+20*glow),int(11+90*glow),int(20+190*glow))
d=ImageDraw.Draw(im)
def font(size):return ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',size*scale)
def centered(text,y,size,color):d.text((w*scale/2,y*scale),text,font=font(size),fill=color,anchor='mt')
for y in range(130,330,18):
 for x in range(35,640,18):
  strength=max(0,1-math.hypot((x-330)/330,(y-230)/150));c=int(45+strength*40)
  d.ellipse((x*scale,y*scale,x*scale+2,y*scale+2),fill=(c,c+5,c+12))
centered('PairIt',34,30,'#ffffff');centered('Drag PairIt into Applications',82,17,'#c5d2e6')
d.line([(300*scale,210*scale),(355*scale,210*scale)],fill='#b8cbe4',width=3*scale)
d.line([(345*scale,200*scale),(355*scale,210*scale),(345*scale,220*scale)],fill='#b8cbe4',width=3*scale)
centered('Then open PairIt from Applications to finish setup.',356,13,'#c5d2e6')
# Finder draws PNG backgrounds at pixel size, independent of display scale.
# Light label plates keep Finder's black filename labels legible in dark mode.
for cx in (170,490):
 d.rounded_rectangle(((cx-69)*scale,260*scale,(cx+69)*scale,288*scale),radius=14*scale,fill='#e9eef7')
im=im.resize((w,h),Image.Resampling.LANCZOS)
Path(sys.argv[1]).parent.mkdir(parents=True,exist_ok=True);im.save(sys.argv[1])
