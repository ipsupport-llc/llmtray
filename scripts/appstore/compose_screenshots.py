"""App Store screenshots: each raw 2880x1800 capture on the brand background
with a title and a line under it (appstore/screenshots/).

Usage: python3 compose_screenshots.py <raw captures dir> <output dir>
Needs Pillow. Raw captures: sRGB, no alpha, named as in `shots` below.
Crops: SETTINGS is where the Settings window sat in the captures; NO_MENUBAR
drops macOS's menu bar (and, for the song, the Dock).
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageCms
D, OUT = sys.argv[1], sys.argv[2]
W, H = 2880, 1800
SF = "/System/Library/Fonts/SFNS.ttf"
def font(size, weight):
    f = ImageFont.truetype(SF, size); f.set_variation_by_name(weight); return f
TITLE, SUB = font(120, "Bold"), font(56, "Regular")
SETTINGS = (720, 175, 2160, 1455)   # the Settings window, in the 2880x1800 shot
NO_MENUBAR = (0, 60, 2880, 1800)

shots = [
 ("01-image-generation", "LLMTray-01-image-generation.png", NO_MENUBAR,
  "Draw on your Mac", "Pictures from a sentence, made on Apple silicon. No cloud, no queue."),
 ("02-music", "LLMTray-08-music.png", (0, 60, 2880, 1645),
  "Make a song", "A song with vocals from a description, made on your Mac."),
 ("03-chat", "LLMTray-02-chat.png", None,
  "Less data center. More Mac.", "Open models like Gemma and Nemotron run right here. Your chats stay on your Mac."),
 ("04-getting-started", "LLMTray-03-getting-started.png", NO_MENUBAR,
  "Up and running in minutes", "A guided start: chat, add your files, enable images, music and voice."),
 ("05-models", "LLMTray-04-models.png", SETTINGS,
  "All your models in one place", "Chat, image, music and voice models, downloaded once and kept on your disk."),
 ("06-profiles", "LLMTray-05-profiles.png", SETTINGS,
  "Tuned for each model", "Sampling, KV cache and speculative decoding, set per profile."),
 ("07-benchmark", "LLMTray-06-benchmark.png", SETTINGS,
  "Make local AI fast", "Measure your Mac and let LLMTray tune the server for it."),
]

def background():
    top, bottom = (16, 52, 32), (6, 20, 13)
    bg = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return bg

def centered(d, y, text, f, fill):
    w = d.textlength(text, font=f); d.text(((W - w) / 2, y), text, font=f, fill=fill)

srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
for name, src, crop, title, sub in shots:
    shot = Image.open(os.path.join(D, src)).convert("RGB")
    if crop: shot = shot.crop(crop)
    # Fit below the caption; never enlarged (text stays sharp).
    box_w, box_h = 2560, 1300
    s = min(box_w / shot.width, box_h / shot.height, 1.0)
    shot = shot.resize((round(shot.width * s), round(shot.height * s)), Image.LANCZOS)
    canvas = background()
    d = ImageDraw.Draw(canvas)
    centered(d, 110, title, TITLE, (255, 255, 255))
    centered(d, 262, sub, SUB, (178, 214, 192))
    x, y = (W - shot.width) // 2, 400 + (box_h - shot.height) // 2
    r = 28
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y + 24, x + shot.width, y + shot.height + 24), r, fill=150)
    canvas.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(40)))
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), r, fill=255)
    canvas.paste(shot, (x, y), mask)
    canvas.save(os.path.join(OUT, f"LLMTray-{name}.png"), icc_profile=srgb, dpi=(72, 72))
    print(name, shot.size)
