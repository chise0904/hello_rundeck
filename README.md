# Rundeck + n8n + Prometheus + Ansible EDA 監控告警自動化 Lab

## 架構概覽

```
Prometheus ──(告警規則觸發)──► Alertmanager ──(webhook)──► n8n ──(HTTP POST)──► Rundeck Job 執行
                                     │
                                     └──(webhook)──► ansible-rulebook ──(Playbook)──► Rundeck API（選填）
```

Alertmanager 同時送出 webhook 給 **n8n**（workflow 自動化）與 **ansible-rulebook**（事件驅動自動化），兩條路徑互相獨立。

---

## 服務清單

| 服務 | 端口 | 帳密 |
|------|------|------|
| Rundeck | http://localhost:4440 | admin / admin123 |
| n8n | http://localhost:5678 | 無需登入 |
| Prometheus | http://localhost:9090 | - |
| Alertmanager | http://localhost:9093 | - |
| Grafana | http://localhost:3000 | admin / admin123 |
| phpLDAPadmin | http://localhost:8080 | - |
| ansible-rulebook | http://localhost:5001 | - |

---

## 網路架構

| Docker 網路 | 用途 |
|-------------|------|
| `rundeck-net` | Rundeck 內部服務（LDAP、target node 等） |
| `monitoring-net` | Prometheus / Grafana / Alertmanager 內部 |
| `eda-net` | ansible-rulebook 內部 |
| `pipeline-net` | 跨 compose 通訊（所有 stack 共用） |

---

## 目錄結構

```
.
├── docker-compose.yml              # Rundeck + OpenLDAP + target nodes
├── docker-compose.n8n.yml          # n8n workflow 自動化
├── docker-compose.monitoring.yml   # Prometheus + Alertmanager + Grafana
├── docker-compose.eda.yml          # Ansible EDA (ansible-rulebook)
├── start-all.sh                    # 一鍵啟動
├── stop-all.sh                     # 一鍵停止
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml          # Prometheus 設定
│   │   └── rules/
│   │       └── example-alerts.yml  # 告警規則
│   ├── alertmanager/
│   │   └── alertmanager.yml        # Alertmanager 設定（webhook → n8n + ansible-rulebook）
│   └── grafana/
│       └── provisioning/
│           ├── datasources/        # 自動掛載 Prometheus datasource
│           └── dashboards/         # Dashboard 設定
├── eda/
│   ├── Dockerfile                  # 基於官方 image 安裝 ansible.eda collection
│   ├── requirements.yml            # ansible.eda + community.general
│   ├── inventory.yml               # localhost connection
│   ├── rulebook.yml                # 事件規則（監聽 Alertmanager webhook）
│   └── playbooks/
│       ├── handle_alert.yml        # firing 告警處理
│       └── handle_resolved_alert.yml  # resolved 告警恢復處理
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

腳本會自動建立共享網路 `pipeline-net` 並依序啟動各 stack。

### 步驟二：啟動 Ansible EDA

```bash
docker compose -f docker-compose.eda.yml up -d --build
```

> 首次啟動需要 build image 並安裝 Ansible Collection，約需 1–2 分鐘。

### 步驟三：確認服務狀態

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

## Ansible EDA 設定說明

### rulebook 運作方式

`eda/rulebook.yml` 使用 `ansible.eda.webhook` source，監聽 port 5000，接收 Alertmanager 送來的 webhook payload，依 `status` 欄位分派對應的 Playbook：

| 條件 | 觸發 Playbook |
|------|---------------|
| `status == "firing"` | `playbooks/handle_alert.yml` |
| `status == "resolved"` | `playbooks/handle_resolved_alert.yml` |

### 選填：自動觸發 Rundeck Job

當 severity 為 `critical` 時，`handle_alert.yml` 可自動呼叫 Rundeck API 觸發 Job。需在 `docker-compose.eda.yml` 設定環境變數：

```yaml
environment:
  - RUNDECK_API_TOKEN=your-token-here   # Rundeck User API Token
  - RUNDECK_JOB_ID=your-job-uuid-here   # Job UUID（Rundeck Job 設定頁面可複製）
```

取得 Rundeck API Token：登入 Rundeck → 右上角個人選單 → **Profile** → **User API Tokens** → **Generate New Token**

### 查看 EDA 執行日誌

```bash
docker logs -f ansible-rulebook
```

---

## 驗證整個 Pipeline

### 方法一：直接呼叫 ansible-rulebook webhook

```bash
curl -X POST http://localhost:5001/ \
  -H "Content-Type: application/json" \
  -d '{
    "receiver": "all-webhooks",
    "status": "firing",
    "commonLabels": {
      "alertname": "TestAlert",
      "severity": "critical"
    },
    "alerts": [
      {
        "status": "firing",
        "labels": {
          "alertname": "TestAlert",
          "severity": "critical",
          "instance": "localhost:9090"
        },
        "annotations": {
          "summary": "Test alert for EDA validation"
        }
      }
    ]
  }'
```

預期結果：`docker logs ansible-rulebook` 顯示 Playbook 執行輸出。

### 方法二：手動呼叫 n8n Webhook

```bash
curl -X POST http://localhost:5678/webhook-test/alert-handler \
  -H "Content-Type: application/json" \
  -d '{
    "receiver": "all-webhooks",
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

### 方法三：透過 Prometheus 觸發真實告警

編輯 [monitoring/prometheus/rules/example-alerts.yml](monitoring/prometheus/rules/example-alerts.yml)，取消 `TestAlert` 的注解：

```yaml
- alert: TestAlert
  expr: vector(1)
  for: 0m
  labels:
    severity: warning
  annotations:
    summary: "Test alert for pipeline validation"
    description: "This is a test alert to verify Alertmanager → n8n + EDA → Rundeck pipeline."
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
docker compose -f docker-compose.eda.yml down
```

若需清除所有資料（volumes）：

```bash
docker compose -f docker-compose.eda.yml down -v
docker compose -f docker-compose.monitoring.yml down -v
docker compose -f docker-compose.n8n.yml down -v
docker compose -f docker-compose.yml down -v
docker network rm pipeline-net
```

---

## 常見問題

### ansible-rulebook 容器無法啟動

確認 `pipeline-net` 網路已存在（需先啟動 n8n 或手動建立）：

```bash
docker network create pipeline-net
docker compose -f docker-compose.eda.yml up -d --build
```

### Alertmanager 無法連到 ansible-rulebook

確認 ansible-rulebook 容器已加入 `pipeline-net`：

```bash
docker network inspect pipeline-net | grep ansible
```

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

### 重新載入 Alertmanager 設定

```bash
docker exec alertmanager wget -q -O- --post-data='' http://localhost:9093/-/reload
```
