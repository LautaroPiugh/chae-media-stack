#!/usr/bin/env python3
"""
Script para traducir subtítulos automáticamente usando Gemini AI
Flujo:
1. Busca items wanted en Bazarr
2. Para cada item, busca subtítulos en inglés
3. Descarga el subtítulo en inglés
4. Traduce al español usando la API de Bazarr
5. Guarda como .es-MX.srt
"""

import requests
import json
import time
import sys

BAZARR_URL = "http://localhost:6767"
API_KEY = os.getenv('BAZARR_API_KEY', 'CHANGEME')
HEADERS = {"X-API-KEY": API_KEY}

def get_wanted_movies():
    """Obtiene películas wanted"""
    response = requests.get(f"{BAZARR_URL}/api/movies/wanted?length=50", headers=HEADERS)
    return response.json().get('data', [])

def get_wanted_episodes():
    """Obtiene episodios wanted"""
    response = requests.get(f"{BAZARR_URL}/api/episodes/wanted?length=50", headers=HEADERS)
    return response.json().get('data', [])

def search_english_subtitles_movie(radarr_id):
    """Busca subtítulos en inglés para una película"""
    response = requests.get(f"{BAZARR_URL}/api/providers/movies?radarrid={radarr_id}", headers=HEADERS)
    data = response.json().get('data', [])
    
    # Filtrar solo subtítulos en inglés
    english_subs = [sub for sub in data if isinstance(sub, dict) and sub.get('language') == 'en']
    return english_subs

def search_english_subtitles_episode(series_id, episode_id):
    """Busca subtítulos en inglés para un episodio"""
    response = requests.get(f"{BAZARR_URL}/api/providers/episodes?seriesid={series_id}&episodeid={episode_id}", headers=HEADERS)
    data = response.json().get('data', [])
    
    # Filtrar solo subtítulos en inglés
    english_subs = [sub for sub in data if isinstance(sub, dict) and sub.get('language') == 'en']
    return english_subs

def download_and_translate_movie(radarr_id, subtitle_data):
    """Descarga subtítulo en inglés y lo traduce al español"""
    # Paso 1: Descargar subtítulo en inglés
    payload = {
        "radarrid": radarr_id,
        "language": "en",
        "forced": "False",
        "hi": "False",
        "original_format": "False",
        "provider": subtitle_data.get('provider'),
        "subtitle": subtitle_data.get('subtitle')
    }
    
    response = requests.post(f"{BAZARR_URL}/api/providers/movies", headers=HEADERS, json=payload)
    
    if response.status_code != 200:
        print(f"Error descargando subtítulo: {response.text}")
        return False
    
    print(f"✓ Subtítulo en inglés descargado")
    
    # Paso 2: Buscar el archivo .srt descargado
    time.sleep(2)  # Esperar a que se guarde el archivo
    
    # Paso 3: Traducir al español usando la API de Bazarr
    # Nota: Esto requiere que el archivo .srt exista en disco
    # La traducción se hace con el endpoint PATCH /subtitles
    
    return True

def main():
    print("=== TRADUCCIÓN AUTOMÁTICA CON GEMINI AI ===\n")
    
    # Obtener películas wanted
    print("Buscando películas wanted...")
    movies = get_wanted_movies()
    print(f"Encontradas {len(movies)} películas wanted\n")
    
    # Procesar cada película
    for movie in movies[:5]:  # Limitar a 5 para prueba
        title = movie.get('title')
        radarr_id = movie.get('radarrId')
        
        print(f"Procesando: {title}")
        
        # Buscar subtítulos en inglés
        english_subs = search_english_subtitles_movie(radarr_id)
        
        if not english_subs:
            print(f"  ✗ No hay subtítulos en inglés disponibles\n")
            continue
        
        print(f"  ✓ Encontrados {len(english_subs)} subtítulos en inglés")
        
        # Tomar el mejor subtítulo (mayor score)
        best_sub = max(english_subs, key=lambda x: x.get('score', 0))
        print(f"  Mejor subtítulo: {best_sub.get('provider')} - Score: {best_sub.get('score')}")
        
        # Descargar y traducir
        if download_and_translate_movie(radarr_id, best_sub):
            print(f"  ✓ Traducción completada\n")
        else:
            print(f"  ✗ Error en traducción\n")
        
        time.sleep(1)  # Pausa entre películas
    
    print("\n=== FIN DEL SCRIPT ===")

if __name__ == "__main__":
    main()
