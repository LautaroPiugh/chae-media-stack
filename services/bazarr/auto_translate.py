#!/usr/bin/env python3
"""
Script para traducir automáticamente subtítulos en inglés al español usando Gemini AI
Monitorea las descargas de Bazarr y traduce automáticamente cuando detecta subtítulos en inglés
"""

import requests
import json
import time
import os
import sys
from datetime import datetime, timedelta

BAZARR_URL = "http://localhost:6767"
API_KEY = os.getenv('BAZARR_API_KEY', 'CHANGEME')
HEADERS = {"X-API-KEY": API_KEY}

def get_recent_downloads(minutes=5):
    """Obtiene descargas recientes de episodios y películas"""
    cutoff_time = datetime.now() - timedelta(minutes=minutes)
    
    # Obtener historial de episodios
    response = requests.get(f"{BAZARR_URL}/api/episodes/history?length=50", headers=HEADERS)
    episodes = response.json().get('data', [])
    
    # Obtener historial de películas
    response = requests.get(f"{BAZARR_URL}/api/movies/history?length=50", headers=HEADERS)
    movies = response.json().get('data', [])
    
    # Filtrar solo descargas recientes en inglés
    english_downloads = []
    
    for ep in episodes:
        if ep.get('action') == 1 and ep.get('language', {}).get('code2') == 'en':
            english_downloads.append({
                'type': 'episode',
                'title': f"{ep.get('seriesTitle')} {ep.get('episode_number')}",
                'id': ep.get('sonarrEpisodeId'),
                'language': 'en',
                'path': ep.get('subtitles_path'),
                'timestamp': ep.get('timestamp')
            })
    
    for movie in movies:
        if movie.get('action') == 1 and movie.get('language', {}).get('code2') == 'en':
            english_downloads.append({
                'type': 'movie',
                'title': movie.get('title'),
                'id': movie.get('radarrId'),
                'language': 'en',
                'path': movie.get('subtitles_path'),
                'timestamp': movie.get('timestamp')
            })
    
    return english_downloads

def translate_subtitle(subtitle_info):
    """Traduce un subtítulo del inglés al español usando la API de Bazarr"""
    subtitle_path = subtitle_info.get('path')
    
    if not subtitle_path or not os.path.exists(subtitle_path):
        print(f"  ✗ Archivo no encontrado: {subtitle_path}")
        return False
    
    print(f"  Traduciendo: {subtitle_path}")
    
    # Usar la API de Bazarr para traducir
    payload = {
        'action': 'translate',
        'language': 'es-MX',
        'path': subtitle_path,
        'type': subtitle_info.get('type'),
        'id': subtitle_info.get('id'),
        'forced': 'False',
        'hi': 'False'
    }
    
    endpoint = f"{BAZARR_URL}/api/subtitles" if subtitle_info.get('type') == 'episode' else f"{BAZARR_URL}/api/subtitles"
    
    response = requests.patch(endpoint, headers=HEADERS, json=payload)
    
    if response.status_code == 204:
        print(f"  ✓ Traducción completada")
        return True
    else:
        print(f"  ✗ Error en traducción: {response.status_code} - {response.text}")
        return False

def main():
    print("=== TRADUCCIÓN AUTOMÁTICA CON GEMINI AI ===")
    print(f"Iniciado: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    
    # Obtener descargas recientes en inglés
    print("Buscando subtítulos en inglés descargados recientemente...")
    english_downloads = get_recent_downloads(minutes=10)
    
    if not english_downloads:
        print("No se encontraron subtítulos en inglés para traducir\n")
        return
    
    print(f"Encontrados {len(english_downloads)} subtítulos en inglés\n")
    
    # Traducir cada subtítulo
    for download in english_downloads:
        print(f"Procesando: {download.get('title')}")
        print(f"  Tipo: {download.get('type')}")
        print(f"  Idioma: {download.get('language')}")
        print(f"  Timestamp: {download.get('timestamp')}")
        
        if translate_subtitle(download):
            print(f"  ✓ Completado\n")
        else:
            print(f"  ✗ Falló\n")
        
        time.sleep(2)  # Pausa entre traducciones
    
    print(f"=== FIN DEL SCRIPT ===")
    print(f"Finalizado: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

if __name__ == "__main__":
    main()
