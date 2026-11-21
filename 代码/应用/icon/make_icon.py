# 生成 回响 的应用图标：白底圆角方形，三根青绿竖条由高到低、由深到浅，一声出去渐渐变弱，就是回声（对比过程见 设计/应用图标/）。
# 用法：python3 代码/应用/icon/make_icon.py
#   → icon/AppIcon.svg（矢量原稿）、AppIcon-1024.png、AppIcon.iconset/（16～1024 各尺寸，build.sh 用它打 icns）
# 照伙伴云NAS应用 mac/icon/make_icon.py：1024 画布，圆角方形在 (100,100)，边长 824，圆角 186，外面一圈投影；
# 各尺寸都从矢量直接渲染（本机 Chrome 无头模式），小尺寸比从 1024 缩小更清楚。改图标只改这个文件，再跑一次，把生成的文件一起提交。
import os, subprocess, tempfile

D = os.path.dirname(os.path.abspath(__file__))
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

BARS = [(440, '#006b6e'), (300, '#2aa8a3'), (170, '#9bd9d4')]   # 高度、颜色：深绿、中青、浅青
W, GAP = 100, 46            # 竖条宽、间隔
SHIFT = 10                  # 整组往右挪：高条那边重，几何居中看着偏左

def icon():
    total = len(BARS) * W + (len(BARS) - 1) * GAP
    x = 512 - total / 2 + SHIFT
    bars = ''
    for h, c in BARS:
        bars += f'<rect x="{x:g}" y="{512 - h / 2:g}" width="{W}" height="{h}" rx="{W / 2:g}" fill="{c}"/>'
        x += W + GAP
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
<linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#edf5f5"/></linearGradient>
<filter id="sh" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#032a2a" flood-opacity=".14"/></filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#bg)" filter="url(#sh)"/>
{bars}
</svg>
'''

def render(svg, px, out):
    with tempfile.TemporaryDirectory() as t:
        h = os.path.join(t, 'i.html')
        open(h, 'w').write(f'<html><body style="margin:0;background:transparent"><img src="file://{svg}" width="{px}" height="{px}" style="display:block"></body></html>')
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--default-background-color=00000000',
                        f'--window-size={px},{px}', f'--screenshot={out}', f'file://{h}'], check=True, capture_output=True)

if __name__ == '__main__':
    svg = os.path.join(D, 'AppIcon.svg')
    open(svg, 'w').write(icon())
    iconset = os.path.join(D, 'AppIcon.iconset')
    os.makedirs(iconset, exist_ok=True)
    for pt in (16, 32, 128, 256, 512):
        render(svg, pt, os.path.join(iconset, f'icon_{pt}x{pt}.png'))
        render(svg, pt * 2, os.path.join(iconset, f'icon_{pt}x{pt}@2x.png'))
    render(svg, 1024, os.path.join(D, 'AppIcon-1024.png'))
    print('已生成', iconset)
