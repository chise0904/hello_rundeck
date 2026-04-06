FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    openssh-server \
    curl wget vim \
    && rm -rf /var/lib/apt/lists/*

# 建立 rundeck 用的 SSH user
RUN useradd -m -s /bin/bash rundeck && \
    echo "rundeck:rundeck123" | chpasswd && \
    mkdir -p /home/rundeck/.ssh && \
    chmod 700 /home/rundeck/.ssh

# 啟動 sshd
RUN mkdir /var/run/sshd
EXPOSE 22

CMD ["/usr/sbin/sshd", "-D"]