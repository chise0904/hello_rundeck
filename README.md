# Rundeck + n8n + Prometheus 監控告警自動化 Lab

## 架構概覽

```
Prometheus ──(告警規則觸發)──► Alertmanager ──(webhook)──► n8n
                                                              │
                                                              └──(HTTP POST)──► Rundeck Webhook ──► Job 執行
```

### 服務清單

| 服務 | 端口 | 帳密 |
|------|------|------|
| Rundeck | http://localhost:4440 | admin / admin123 |
| n8n | http://localhost:5678 | 無需登入 |
| Prometheus | http://localhost:9090 | - |
| Alertmanager | http://localhost:9093 | - |
| Grafana | http://localhost:3000 | admin / admin123 |
| phpLDAPadmin | http://localhost:8080 | - |

### 網路架構

| Docker 網路 | 用途 |
|-------------|------|
| `rundeck-net` | Rundeck 內部服務（LDAP、target node 等） |
| `monitoring-net` | Prometheus / Grafana / Alertmanager 內部 |
| `pipeline-net` | 跨 compose 通訊（Rundeck + n8n + Alertmanager） |

---

## 目錄結構

```
.
├── docker-compose.yml              # Rundeck + OpenLDAP + target nodes
├── docker-compose.n8n.yml          # n8n workflow 自動化
├── docker-compose.monitoring.yml   # Prometheus + Alertmanager + Grafana
├── start-all.sh                    # 一鍵啟動
├── stop-all.sh                     # 一鍵停止
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml          # Prometheus 設定
│   │   └── rules/
│   │       └── example-alerts.yml  # 告警規則
│   ├── alertmanager/
│   │   └── alertmanager.yml        # Alertmanager 設定（webhook → n8n）
│   └── grafana/
│       └── provisioning/
│           ├── datasources/        # 自動掛載 Prometheus datasource
│           └── dashboards/         # Dashboard 設定
├── n8n/
│   └── data/                       # n8n 持久化資料
├── rundeck-config/
│   ├── acl/                        # ACL policy 設定
│   ├── realm.properties            # 本地帳號
│   ├── resources.yaml              # 節點清單
│   └── ldap-bootstrap.ldif         # LDAP 初始化資料
└── target-node/
    └── Dockerfile                  # SSH target node 映像
```

---

## 快速啟動

### 前置需求

- Docker Desktop（已啟動）
- Docker Compose v2

### 步驟一：啟動所有服務

```bash
cd /path/to/rundeck
./start-all.sh
```

腳本會自動：
1. 建立共享網路 `pipeline-net`
2. 依序啟動 Rundeck、n8n、Monitoring stack

等待約 30–60 秒讓所有服務完成初始化。

### 步驟二：確認服務狀態

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## 設定 Rundeck Webhook

### 1. 建立 Job

1. 登入 `http://localhost:4440`（admin / admin123）
2. 進入 **demo** 專案 → **Jobs** → **New Job**
3. 填入以下資訊：
   - Job Name：`alert-remediation`
   - 在 **Workflow** 分頁加入一個 **Command** 步驟，例如：
     ```bash
     echo "Alert received: ${option.alertname} severity=${option.severity}"
     ```
4. （選填）在 **Options** 分頁新增兩個 Option：
   - `alertname`（String，不必填）
   - `severity`（String，不必填）
5. 儲存 Job

### 2. 建立 Webhook

1. 左側選單點選 **Webhooks**
2. 點選 **Add Webhook**
3. 填入設定：
   - Name：`alertmanager-trigger`
   - **Plugin**：選擇 `Run Job`
   - **Job**：選擇剛建立的 `alert-remediation`
4. 儲存後，複製頁面上方的 **Webhook URL**，格式如下：
   ```
   http://localhost:4440/api/45/webhook/<TOKEN>
   ```
5. 將 URL 中的 `localhost` 改為 `rundeck`（容器名稱），供 n8n 內部呼叫：
   ```
   http://rundeck:4440/api/45/webhook/<TOKEN>
   ```

---

## 設定 n8n Workflow

### 1. 建立 Workflow

1. 開啟 `http://localhost:5678`
2. 點選 **New Workflow**

### 2. 新增 Webhook 節點（觸發器）

1. 搜尋並新增 **Webhook** 節點
2. 設定：
   - **HTTP Method**：`POST`
   - **Path**：`alertmanager`
3. 點選 **Listen for Test Event**，取得 Webhook 測試 URL

### 3. 新增 HTTP Request 節點（呼叫 Rundeck）

1. 搜尋並新增 **HTTP Request** 節點
2. 設定：
   - **Method**：`POST`
   - **URL**：填入上一節複製的 Rundeck Webhook URL（容器名稱版本）
     ```
     http://rundeck:4440/api/45/webhook/<TOKEN>
     ```
   - **Authentication**：None（Webhook token 本身即為認證）
   - （選填）**Body Parameters** 傳遞告警資訊：
     - `alertname`：`{{ $json.body.alerts[0].labels.alertname }}`
     - `severity`：`{{ $json.body.alerts[0].labels.severity }}`
3. 連接 Webhook → HTTP Request

### 4. 啟用 Workflow

1. 點選右上角 **Active** 開關，將 Workflow 切換為啟用
2. Webhook 正式路徑為：
   ```
   http://n8n:5678/webhook/alertmanager
   ```

---

## 驗證整個 Pipeline

### 方法一：手動呼叫 n8n Webhook

```bash
curl -X POST http://localhost:5678/webhook-test/alert-handler \
  -H "Content-Type: application/json" \
  -d '{
    "receiver": "n8n-webhook",
    "status": "firing",
    "alerts": [
      {
        "status": "firing",
        "labels": {
          "alertname": "TestAlert",
          "severity": "critical",
          "instance": "localhost:9090"
        },
        "annotations": {
          "summary": "Test alert for pipeline validation"
        }
      }
    ]
  }'
```

預期結果：
- n8n Workflow 執行記錄出現新的 execution
- Rundeck 的 `alert-remediation` Job 被觸發並顯示在 Activity 頁面

### 方法二：透過 Prometheus 觸發真實告警

編輯 [monitoring/prometheus/rules/example-alerts.yml](monitoring/prometheus/rules/example-alerts.yml)，取消 `TestAlert` 的注解：

```yaml
- alert: TestAlert
  expr: vector(1)
  for: 0m
  labels:
    severity: warning
  annotations:
    summary: "Test alert for pipeline validation"
    description: "This is a test alert to verify Alertmanager → n8n → Rundeck pipeline."
```

重新載入 Prometheus 設定（無需重啟）：

```bash
curl -X POST http://localhost:9090/-/reload
```

等待約 10–30 秒後，至 Alertmanager UI 確認告警已發出：
```
http://localhost:9093/#/alerts
```

---

## 停止所有服務

```bash
./stop-all.sh
```

若需清除所有資料（volumes）：

```bash
docker compose -f docker-compose.monitoring.yml down -v
docker compose -f docker-compose.n8n.yml down -v
docker compose -f docker-compose.yml down -v
docker network rm pipeline-net
```

---

## 常見問題

### Alertmanager 無法連到 n8n

確認 n8n 容器與 alertmanager 容器都在 `pipeline-net` 網路：

```bash
docker network inspect pipeline-net
```

### n8n Webhook 沒有收到請求

確認 Workflow 已切換為 **Active**（非 Inactive 狀態）。

### Rundeck Job 沒有被觸發

1. 確認 Webhook Token 正確
2. 確認 n8n HTTP Request 節點中的 URL 使用容器名稱 `rundeck`，而非 `localhost`
3. 至 Rundeck **Webhooks** 頁面確認 Webhook 狀態為 **Enabled**

### Prometheus 規則未載入

```bash
# 確認規則語法正確
docker exec prometheus promtool check rules /etc/prometheus/rules/example-alerts.yml

# 熱重載設定
curl -X POST http://localhost:9090/-/reload
```
