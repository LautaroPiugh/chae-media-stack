#!/usr/bin/env python3
"""Traductor local NLLB-200 para lotes cortos de subtitulos."""

import json
import re
import sys

from langdetect import DetectorFactory, detect
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

DetectorFactory.seed = 0
MODEL = "facebook/nllb-200-distilled-600M"
TARGET = "spa_Latn"
LANGUAGES = {
    "en": "eng_Latn", "es": "spa_Latn", "it": "ita_Latn",
    "ja": "jpn_Jpan", "th": "tha_Thai", "zh-cn": "zho_Hans",
    "zh-tw": "zho_Hant", "ko": "kor_Hang", "fr": "fra_Latn",
    "de": "deu_Latn", "pt": "por_Latn", "ru": "rus_Cyrl",
    "ar": "arb_Arab", "hi": "hin_Deva", "tr": "tur_Latn",
}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def choose_source(texts, requested):
    if requested:
        if requested not in LANGUAGES.values():
            fail(f"codigo de idioma NLLB no soportado: {requested}")
        return requested
    sample = re.sub(r"<[^>]+>", " ", " ".join(texts))[:5000].strip()
    if not sample:
        fail("sin texto para detectar idioma")
    try:
        detected = detect(sample)
    except Exception as exc:
        fail(f"no se pudo detectar el idioma: {exc}")
    source = LANGUAGES.get(detected)
    if not source:
        fail(f"idioma detectado sin mapeo NLLB: {detected}")
    return source


def main():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        fail(f"JSON invalido: {exc}")
    texts = payload.get("texts")
    if not isinstance(texts, list) or not texts or any(not isinstance(item, str) for item in texts):
        fail("texts debe ser una lista no vacia de cadenas")
    source = choose_source(texts, payload.get("source_lang"))
    if source == TARGET:
        print(json.dumps(texts, ensure_ascii=False))
        return

    tokenizer = AutoTokenizer.from_pretrained(MODEL, src_lang=source)
    model = AutoModelForSeq2SeqLM.from_pretrained(MODEL)
    translated = []
    for start in range(0, len(texts), 24):
        batch = texts[start:start + 24]
        encoded = tokenizer(batch, return_tensors="pt", padding=True, truncation=True, max_length=512)
        generated = model.generate(
            **encoded,
            forced_bos_token_id=tokenizer.convert_tokens_to_ids(TARGET),
            max_new_tokens=512,
        )
        translated.extend(tokenizer.batch_decode(generated, skip_special_tokens=True))
    if len(translated) != len(texts) or any(not text.strip() for text in translated):
        fail("NLLB devolvio segmentos vacios o incompletos")
    print(json.dumps(translated, ensure_ascii=False))


if __name__ == "__main__":
    main()
