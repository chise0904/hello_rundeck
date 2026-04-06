#!/bin/bash

echo "==> 停止所有服務..."
docker compose -f docker-compose.monitoring.yml down
docker compose -f docker-compose.n8n.yml down
docker compose -f docker-compose.yml down

echo ""
echo "==> 移除共享網路 pipeline-net..."
docker network rm pipeline-net 2>/dev/null || echo "    pipeline-net 不存在或已移除"

echo "Done."
