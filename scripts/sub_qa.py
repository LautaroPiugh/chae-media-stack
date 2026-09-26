#!/usr/bin/env python3
"""Validacion de calidad de subtitulos ES antes de guardarlos."""

import os
import re
import json
import subprocess

FFPROBE_CONTAINER = 'chae-bazarr'
HOST_TO_CONTAINER = ('/mnt/media/', '/media/')

ES_WORDS = set("""
de la que el en y a los se del las un por con no una su para es al lo como mas o
pero sus le ya este si porque esta entre cuando muy sin sobre tambien me hasta hay
donde quien desde todo nos durante todos uno les ni contra otros ese eso ante ellos
e esto mi antes algunos que unos yo otro otras otra el tanto esa estos mucho quienes
nada muchos cual poco ella estar estas algunas algo nosotros mi mis tu tus su sus
nuestro nuestra nuestros nuestras vuestro vuestra vos usted ustedes lo las le les
nos os ya aun ademas sino aunque porque pues estaba es son era fui fue ser estar
tener tiene tengo tuve had hacer hace hago hice ir voy va vamos veo saber conozco
puedo puede deber quiero decir digo creer creo parecer parece llegar llegue hay
habia hubo esto aqui ahi alli ahora hoy ayer manana siempre nunca jamas demasiado
mucho poco tanto bastante algo alguien nadie cada cual donde cuando como cuanto
por que para que hasta desde entre sobre bajo ante tras durante segun conforme
hola adios gracias por favor bien mal senor senora senorita madre padre hijo hija
hermano hermana amigo amiga casa trabajo agua fuego tierra aire noche dia tarde
vida muerte amor hombre mujer nino nina gente pueblo ciudad calle camino grande
pequeno bueno malo nuevo viejo joven uno dos tres cuatro cinco seis siete ocho
nueve diez primero segundo ultimo mismo otro tal cosa cosas vez veces parte partes
manera modo tiempo ano mes semana hora minuto segundo nombre palabra voz mano
cabeza ojos boca cara jugar comer beber dormir vivir morir hablar escuchar mirar
sentir pensar entrar salir subir bajar abrir cerrar dar poner quitar buscar
encontrar perder ganar pagar costar valer quedar volver regresar empezar comenzar
terminar acabar seguir parar cambiar mover llevar traer dejar permitir ayudar
necesitar importar interesar preocupar sonar gustar doler""".split())

EN_WORDS = set("""
the be to of and a in that have i it for not on with he as you do at this but his
by from they we say her she or an will my one all would there their what so up out
if about who get which go me when make can like time no just him know take people
into year your good some could them see other than then now look only come its over
think also back after use two how our work first well way even new want because any
these give day most us is are was were been being has had did does doing done got
goes went gone said says telling told hello goodbye please yes well mister miss
mother father son daughter brother sister friend home work water fire earth air
night day morning life death love man woman boy girl people town city street road
big small good bad new old young one two three four five six seven eight nine ten
first second last same other thing things time times part parts way ways name word
voice hand head eyes mouth face work play eat drink sleep live die talk listen look
feel think know go come enter leave up down open close give put take find lose win
pay cost worth stay return start begin end finish stop change move bring carry leave
allow help need matter care worry sound like hurt seem""".split())

MIN_ES_RATIO = 0.30
MAX_EMPTY_RATIO = 0.02
MIN_CUES_PER_MIN = 2.5
# Aperturas/créditos largos no son un sub roto: con 120s/10% se marcaban como
# "empieza muy tarde" o "sub corto" subs correctos (Nymphomaniac, Zootopia...).
LEAD_IN_OK = 480.0
TAIL_OK = 20.0
TAIL_CREDITS_MIN = 300.0
TAIL_CREDITS_RATIO = 0.15
MIN_COVER_RATIO = 0.70
# Por debajo de esta cobertura al sub le falta contenido real (p.ej. Michael,
# -36 min) y hay que reemplazarlo. Por encima, lo que falta son créditos: se
# conserva el sub (no pisarlo con otro descargado ni con whisper).
KEEP_COVER_OK = 0.85

TIME_RE = re.compile(r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})')
ARROW = '-->'


def to_container_path(path):
    src, dst = HOST_TO_CONTAINER
    if path.startswith(src):
        return dst + path[len(src):]
    return path


def parse_srt(content):
    if not content:
        return []
    text = content.replace('\r\n', '\n').replace('\r', '\n')
    lines = text.split('\n')
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        idx = None
        if line.isdigit() and i + 1 < n and ARROW in lines[i + 1]:
            idx = line
            i += 1
            line = lines[i].strip()
        if ARROW not in line:
            i += 1
            continue
        ts = line
        i += 1
        body = []
        while i < n:
            cur = lines[i]
            s = cur.strip()
            if ARROW in s:
                break
            if s.isdigit() and i + 1 < n and ARROW in lines[i + 1]:
                break
            if not s:
                j = i
                while j < n and not lines[j].strip():
                    j += 1
                if j >= n or ARROW in lines[j].strip() or (
                        lines[j].strip().isdigit() and j + 1 < n and ARROW in lines[j + 1]):
                    i = j
                    break
            body.append(cur)
            i += 1
        while body and not body[-1].strip():
            body.pop()
        out.append((idx or str(len(out) + 1), ts, body))
    return out


def render_srt(blocks):
    parts = []
    for i, (idx, ts, body) in enumerate(blocks, start=1):
        text = '\n'.join(body).strip('\n')
        parts.append(f"{i}\n{ts}\n{text}")
    return '\n\n'.join(parts) + '\n'


def ts_to_sec(ts_line):
    m = TIME_RE.search(ts_line or '')
    if not m:
        return None
    h, mi, s, ms = m.groups()
    ms = (ms + '000')[:3]
    return int(h) * 3600 + int(mi) * 60 + int(s) + int(ms) / 1000.0


def srt_span(content):
    blocks = parse_srt(content)
    secs = []
    for _, ts, _ in blocks:
        v = ts_to_sec(ts)
        if v is not None:
            secs.append(v)
    if not secs:
        return None, None
    return min(secs), max(secs)


def get_video_duration(video_path):
    return video_duration(video_path)


def video_duration(video_path):
    if not video_path or not os.path.isfile(video_path):
        return None
    cpath = to_container_path(video_path)
    try:
        p = subprocess.run(
            ['docker', 'exec', FFPROBE_CONTAINER, 'ffprobe', '-v', 'quiet',
             '-show_entries', 'format=duration', '-of', 'json', cpath],
            capture_output=True, text=True, timeout=90)
        if p.returncode != 0:
            return None
        return float(json.loads(p.stdout)['format']['duration'])
    except Exception:
        return None


def word_ratios(content):
    blocks = parse_srt(content)
    txt = '\n'.join('\n'.join(body) for _, _, body in blocks)
    words = re.findall(r"[A-Za-zÀ-ÿ]+", txt.lower())
    if not words:
        return 0.0, 0.0, 0
    es = sum(1 for w in words if w in ES_WORDS)
    en = sum(1 for w in words if w in EN_WORDS)
    return es, en, len(words)


def empty_cue_ratio(content):
    blocks = parse_srt(content)
    if not blocks:
        return 1.0, 0, 0
    empty = 0
    for _, _, body in blocks:
        if not any(l.strip() for l in body):
            empty += 1
        else:
            joined = ' '.join(l.strip() for l in body)
            cleaned = re.sub(r'[\[\(][^\]\)]*[\]\)]', '', joined)
            cleaned = re.sub(r'[♪#\-–—.…"\'\s]+', '', cleaned)
            if not cleaned:
                empty += 1
    return empty / len(blocks), empty, len(blocks)


def qa_subtitle(content, video_path=None, duration=None, tail_ok=None):
    if not content or not content.strip():
        return {'ok': False, 'motivo': 'contenido vacio'}

    blocks = parse_srt(content)
    if len(blocks) < 3:
        return {'ok': False, 'motivo': f'muy pocos cues ({len(blocks)})'}

    first, last = srt_span(content)
    if first is None:
        return {'ok': False, 'motivo': 'sin timestamps validos'}

    if duration is None and video_path:
        duration = video_duration(video_path)

    er, empty_n, total = empty_cue_ratio(content)
    es, en, nwords = word_ratios(content)
    es_ratio = es / max(es + en, 1)
    cues_min = len(blocks) / max((duration / 60.0), 0.1) if duration else None

    result = {
        'ok': True,
        'motivo': '',
        'cues': len(blocks),
        'first': round(first, 1),
        'last': round(last, 1),
        'duration': round(duration, 1) if duration else None,
        'empty_ratio': round(er, 4),
        'empty_n': empty_n,
        'es_ratio': round(es_ratio, 3),
        'en': en,
        'es': es,
        'words': nwords,
        'cues_per_min': round(cues_min, 1) if cues_min else None,
    }

    if er > MAX_EMPTY_RATIO:
        result['ok'] = False
        result['motivo'] = f"cues vacios {er:.1%} ({empty_n}/{total})"
        return result

    if nwords >= 40 and es_ratio < MIN_ES_RATIO:
        result['ok'] = False
        result['motivo'] = f"parece no estar en espanol (ratio ES {es_ratio:.0%})"
        return result

    if first > LEAD_IN_OK:
        result['ok'] = False
        result['motivo'] = f"empieza muy tarde ({first:.0f}s)"
        return result

    if duration:
        cover = last / duration
        result['cover'] = round(cover, 3)
        tail_credits_ok = max(TAIL_CREDITS_MIN, duration * TAIL_CREDITS_RATIO)
        over = TAIL_OK if tail_ok is None else tail_ok
        if last > duration + over:
            result['ok'] = False
            result['motivo'] = f"sub mas largo que el video ({last - duration:+.0f}s)"
            return result
        if last < duration - tail_credits_ok:
            result['ok'] = False
            result['motivo'] = f"sub corto frente al video ({last - duration:+.0f}s)"
            return result
        if cover < MIN_COVER_RATIO:
            result['ok'] = False
            result['motivo'] = f"cobertura baja ({cover:.0%})"
            return result
        if cues_min is not None and cues_min < MIN_CUES_PER_MIN:
            result['ok'] = False
            result['motivo'] = f"pocos cues/min ({cues_min:.1f})"
            return result

    return result


SYNC_MOTIVO_RE = re.compile(
    r'sub corto|sub mas largo|cobertura|empieza muy tarde', re.I)


def is_sync_shaped(motivo):
    """True si el rechazo del QA parece problema de sincronía (offset/drift) y
    no de contenido (vacío, idioma, casi sin cues)."""
    return bool(SYNC_MOTIVO_RE.search(motivo or ''))


def qa_subtitle_file(srt_path, video_path=None):
    if not os.path.isfile(srt_path):
        return {'ok': False, 'motivo': 'archivo no encontrado'}
    if video_path is None:
        base = re.sub(r'\.(es\.)?(hi\.)?srt$', '', srt_path, flags=re.I)
        for ext in ('.mkv', '.mp4', '.avi', '.m4v'):
            cand = base + ext
            if os.path.isfile(cand):
                video_path = cand
                break
    try:
        with open(srt_path, encoding='utf-8', errors='replace') as f:
            content = f.read()
    except Exception as e:
        return {'ok': False, 'motivo': f'error leyendo: {e}'}
    out = qa_subtitle(content, video_path=video_path)
    out['srt'] = srt_path
    out['video'] = video_path
    return out


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 2:
        print("uso: sub_qa.py <archivo.srt> [video]")
        sys.exit(2)
    r = qa_subtitle_file(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    print(json.dumps(r, ensure_ascii=False, indent=2))
    sys.exit(0 if r.get('ok') else 1)


# ── detección de SDH por CONTENIDO ──────────────────────────────────────────
# El flag hearing_impaired de los providers viene vacío o "False" aunque el sub
# sea para sordos, y el nombre del archivo tampoco sirve (Bazarr pone el sufijo
# .hi. a veces sin que lo sea). Lo único confiable es mirar los cues: los subs
# SDH meten sonidos no hablados entre corchetes, notas musicales o líneas que
# son solo efectos.
SDH_MARKER_RE = re.compile(
    r'[\[\(][^\]\)]*[\]\)]'                       # [la puerta se cierra] / (suspiro)
    r'|[♪♫#]'                                     # marcas de música / efectos
    r'|^\s*(música|musica|music|sonido|sound|ruido|noise|door|puerta|applause'
    r'|aplauso|silbido|whistle|grito|scream|llanto|crying|risa|laugh)\b',
    re.I,
)


def sdh_ratio(content):
    """Fracción de cues que contienen marcadores SDH (0.0 a 1.0)."""
    blocks = parse_srt(content)
    if not blocks:
        return 0.0
    n = 0
    for _, _, body in blocks:
        joined = ' '.join(l for l in body if l.strip())
        if SDH_MARKER_RE.search(joined):
            n += 1
    return n / len(blocks)


def classify_srt(content):
    """'normal' | 'sdh' | 'basura' — por contenido, no por nombre ni flag.

    normal : diálogo limpio, usable tal cual
    sdh    : tiene suficientes marcadores de sonido como para querer limpiarlo
    basura : casi sin diálogo, o ni siquiera parece español
    """
    blocks = parse_srt(content)
    if len(blocks) < 3:
        return 'basura'
    es, en, nwords = word_ratios(content)
    if es + en == 0:
        return 'basura'
    if es / (es + en) < 0.15:
        return 'basura'
    return 'sdh' if sdh_ratio(content) > 0.15 else 'normal'
