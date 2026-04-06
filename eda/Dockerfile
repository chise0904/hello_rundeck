FROM quay.io/ansible/ansible-rulebook:latest

# 安裝必要的 Ansible Collections（以 image 預設使用者執行）
COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml --force
