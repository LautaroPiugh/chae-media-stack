<?php
declare(strict_types=1);

$cacheFile = '/home/chae/.cache/stack-dashboard/stack-data.json';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');

if (!is_file($cacheFile)) {
    http_response_code(503);
    echo json_encode([
        'error' => 'dashboard_cache_missing',
        'message' => 'No existe el cache del dashboard. Ejecuta /home/chae/scripts/generate-stack-dashboard-data.sh.',
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}

$contents = file_get_contents($cacheFile);
if ($contents === false) {
    http_response_code(500);
    echo json_encode([
        'error' => 'dashboard_cache_unreadable',
        'message' => 'No se pudo leer el cache del dashboard.',
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}

echo $contents;
