import math
B='M90.7 116H61.8V95.6h28.9c5.6 0 10.2 4.6 10.2 10.2 0 5.7-4.6 10.2-10.2 10.2m0-54.3c5.2 0 9.3 4.2 9.3 9.3 0 5.2-4.2 9.3-9.3 9.3H61.8V61.7h28.9zm24.6 9.3c0-13.6-11-24.6-24.6-24.6H46.5v84.9h44.1c14.1 0 25.4-11.4 25.4-25.5 0-7-2.9-13.4-7.5-18 4.3-4.4 6.8-10.3 6.8-16.8'
R='M260.8 80.4H232V61.7h28.9c5.2 0 9.3 4.2 9.3 9.3 0 5.2-4.2 9.4-9.4 9.4m24.6-9.4c0-13.6-11-24.6-24.6-24.6h-44.1v84.9H232V95.6h28.9c5.6 0 10.2 4.6 10.2 10.2v25.5h15.3v-25.5c0-7-2.9-13.4-7.5-18 4-4.4 6.5-10.3 6.5-16.8'
C='M310 88.9c0-15 12.2-27.2 27.2-27.2h25.5V46.4h-25.5c-23.4 0-42.4 19-42.4 42.4s19 42.4 42.4 42.4h25.5V116h-25.5c-15 0-27.2-12.1-27.2-27.1'
A='M184.9 88.9h-39v-9.3c0-10.8 8.7-19.5 19.5-19.5s19.5 8.7 19.5 19.5v9.3zm-19.5-44.2c-19.2 0-34.8 15.6-34.8 34.8v51.8h15.3v-27.1h39v27.1h15.3V79.5c-.1-19.2-15.6-34.8-34.8-34.8'
EYE='M412.3 117.7c-15.9 0-28.9-12.9-28.9-28.9 0-15.9 12.9-28.9 28.9-28.9 15.9 0 28.9 12.9 28.9 28.9 0 16-13 28.9-28.9 28.9m52.2-37.3c-5 0-9.3-3.1-11.1-7.6-6.4-16.4-22.4-28.1-41.1-28.1s-34.7 11.6-41.1 28.1c-1.7 4.4-6 7.6-11.1 7.6h-13.6v17h13.6c5 0 9.3 3.2 11.1 7.6 6.4 16.4 22.4 28.1 41.1 28.1s34.7-11.7 41.1-28.1c1.7-4.4 6-7.5 11.1-7.5h13.6v-17h-13.6v-.1z'
PUPIL='M412.3 72.6c-9 0-16.3 7.3-16.3 16.3s7.3 16.3 16.3 16.3 16.3-7.3 16.3-16.3-7.3-16.3-16.3-16.3'
CX,CY=412.3,88.9; RO=44.2; RI=28.9
SW=15.3; TOP=46.4; BOT=131.3; MID=88.85

def S_path(x0):
    # Barco-style S built from the C/B geometry: 15.3 stroke, bars + semicircular bowls
    h=SW/2; t=TOP+h; b=BOT-h; r=(MID-t)/2; lc=x0+h+r; rc=x0+68-h-r
    return (f'<path d="M{x0+68} {t}H{lc}A{r} {r} 0 0 0 {lc} {MID}H{rc}A{r} {r} 0 0 1 {rc} {b}H{x0}" '
            f'fill="none" stroke="currentColor" stroke-width="{SW}"/>')

def C_at(x0):  # C spans 294.8..362.7
    return f'<path transform="translate({x0-294.8} 0)" d="{C}"/>'

def eye_left(dx, bar=True):
    # Barco eye with left flare/beam, plain round right side (so letters can follow)
    clipid=f'cl{int(dx*10)}'
    left=f'<clipPath id="{clipid}"><rect x="{300 if bar else 366}" y="0" width="{CX+0.6-(300 if bar else 366)}" height="200"/></clipPath>'
    ring=(f'<path fill-rule="evenodd" d="M{CX} {CY-RO}A{RO} {RO} 0 0 1 {CX} {CY+RO}V{CY+RI}A{RI} {RI} 0 0 0 {CX} {CY-RI}z"/>')
    if not bar:
        ring2=(f'<path fill-rule="evenodd" d="M{CX} {CY-RO}A{RO} {RO} 0 0 0 {CX} {CY+RO}V{CY+RI}A{RI} {RI} 0 0 1 {CX} {CY-RI}z"/>')
        return f'<g transform="translate({dx} 0)">{ring}{ring2}<path d="{PUPIL}"/></g>'
    return (f'<g transform="translate({dx} 0)"><defs>{left}</defs><path clip-path="url(#{clipid})" d="{EYE}"/>'
            f'{ring}<path d="{PUPIL}"/></g>')

def waves(cx,cy,radii,ang=42,w=10):
    out=[]
    for r in radii:
        a=math.radians(ang); x=cx+r*math.cos(a); y1=cy-r*math.sin(a); y2=cy+r*math.sin(a)
        out.append(f'<path d="M{x:.2f} {y1:.2f}A{r} {r} 0 0 1 {x:.2f} {y2:.2f}" fill="none" stroke="currentColor" stroke-width="{w}" stroke-linecap="round"/>')
    return ''.join(out)

def BARC(): return f'<path d="{B}"/><path d="{A}"/><path d="{R}"/><path d="{C}"/>'

def shell(bg, inner, extra_defs=''):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">{bg}</linearGradient>
 <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
 <filter id="sh" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".32"/></filter>
 <clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
 {extra_defs}
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)" filter="url(#sh)"/>
<g clip-path="url(#sq)">{inner}
<rect x="100" y="100" width="824" height="824" fill="url(#sheen)"/></g>
<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="#000" stroke-opacity=".12"/>
</svg>'''

RED='<stop offset="0" stop-color="#FF2A1F"/><stop offset="1" stop-color="#C80000"/>'
DARK='<stop offset="0" stop-color="#34343A"/><stop offset="1" stop-color="#121214"/>'

def stacked(c_main, c_osc, c_eye, c_wave):
    # line1 BARC (x 46.5..362.7), line2 waves + eye + S + C justified to same width
    W=38; e0=W; ex=e0-346.5; lensR=e0+110.2; s0=lensR+16; c0=s0+68+16
    dy=86+28
    l1=f'<g fill="{c_main}">{BARC()}</g>'
    l2=(f'<g transform="translate(46.5 {dy-44.2+46.4-2})">'
        f'<g fill="{c_wave}" color="{c_wave}">{waves(-24, MID, [17,32,47], 44, 10)}</g>'
        f'<g fill="{c_eye}">{eye_left(ex)}</g>'
        f'<g fill="{c_osc}" color="{c_osc}">{S_path(s0)}{C_at(c0)}</g></g>')
    block_w=316.2; block_h=(dy+133.1)-44.7
    s=620/block_w
    tx=512-s*(46.5+block_w/2); ty=512-s*(44.7+block_h/2)
    return f'<g transform="translate({tx:.1f} {ty:.1f}) scale({s:.4f})">{l1}{l2}</g>'

def lens_variant(osc='#fff', word_on=True, s=3.6, cy=430, o_grad=False):
    # big Barco eye as a projector lens, OSC ripples arriving from the left, wordmark below
    tx=512-s*CX; ty=cy-s*CY
    eye=f'<g transform="translate({tx:.1f} {ty:.1f}) scale({s})" fill="#fff"><path d="{EYE}"/><path d="{PUPIL}"/></g>'
    beam=f'<rect x="100" y="{ty+s*80.4:.1f}" width="{tx+s*346.5-100+2:.1f}" height="{s*17:.1f}" fill="#fff"/><rect x="{tx+s*478.1-2:.1f}" y="{ty+s*80.4:.1f}" width="200" height="{s*17:.1f}" fill="#fff"/>'
    rip=''.join(f'<circle cx="512" cy="{cy}" r="{r*s/3.6:.0f}" fill="none" stroke="#fff" stroke-opacity="{o}" stroke-width="10"/>' for r,o in [(232,.30),(282,.18),(332,.09)])
    # wordmark BARC + ring O + S + C
    o0=362.7+16; ocx=o0+42.45; s0=o0+84.9+16; c0=s0+68+16
    word=(f'<g fill="#fff" color="#fff">{BARC()}'
          + (f'</g><linearGradient id="og" gradientUnits="userSpaceOnUse" x1="{ocx-42.45}" y1="0" x2="{ocx+42.45}" y2="0"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="{osc}"/></linearGradient><g fill="{osc}" color="{osc}">' if o_grad else f'</g><g fill="{osc}" color="{osc}">')
          + f'<circle cx="{ocx}" cy="{MID}" r="{42.45-SW/2}" fill="none" stroke="{"url(#og)" if o_grad else osc}" stroke-width="{SW}"/>'
          f'{S_path(s0)}{C_at(c0)}</g>')
    ww=c0+67.9-46.5; ws=640/ww
    word=f'<g transform="translate({512-ws*(46.5+ww/2):.1f} {760-ws*MID:.1f}) scale({ws:.4f})">{word}</g>'
    return rip+beam+eye+(word if word_on else '')


open('barcosc-icon-lens.svg','w').write(shell(RED, lens_variant(osc='#B0B0B0', o_grad=True)))
open('barcosc-icon-lens-dark-osc.svg','w').write(shell(RED, lens_variant(osc='#3A0000')))
open('barcosc-icon-lens-small.svg','w').write(shell(RED, lens_variant(word_on=False, s=4.4, cy=512)))
