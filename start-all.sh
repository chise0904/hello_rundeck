#!/bin/bash
set -e

echo "==> 建立共享網路 pipeline-net..."
docker network create pipeline-net 2>/dev/null || echo "    pipeline-net 已存在，跳過"

echo ""
echo "==> 啟動 Rundeck 環境..."
docker compose -f docker-compose.yml up -d

echo ""
echo "==> 啟動 n8n..."
docker compose -f docker-compose.n8n.yml up -d

echo ""
echo "==> 啟動 Prometheus / Alertmanager / Grafana..."
docker compose -f docker-compose.monitoring.yml up -d

echo ""
echo "========================================="
echo "All services started!"
echo ""
echo "  Rundeck      http://localhost:4440"
echo "  n8n          http://localhost:5678"
echo "  Prometheus   http://localhost:9090"
echo "  Alertmanager http://localhost:9093"
echo "  Grafana      http://localhost:3000  (admin / admin123)"
echo "  phpLDAPadmin http://localhost:8080"
echo "========================================="
