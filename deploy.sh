#!/bin/bash
set -e

echo "==> Smart Sensor Gateway - Automatische deploy"
echo ""

echo "[1/4] Bestaande containers stoppen..."
docker compose down

echo ""
echo "[2/4] Images (opnieuw) bouwen/ophalen..."
docker compose pull

echo ""
echo "[3/4] Stack opnieuw opstarten..."
docker compose up -d

echo ""
echo "[4/4] Status van de containers:"
docker compose ps

echo ""
echo "==> Klaar. Node-RED: http://localhost:1880 | InfluxDB: http://localhost:8086 | Portainer: http://localhost:9000"