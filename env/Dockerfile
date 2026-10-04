# b4-2 장애 재현 실험 이미지
#
# - 제공 바이너리는 이미지에 굽지 않는다. 실행할 때 읽기 전용으로 마운트한다
#   (-v .runtime/agent-leak-app-arm64:/opt/agent/agent-leak-app:ro).
# - 앱은 root로 실행하면 부트 단계에서 실패하므로 일반 사용자 agent(uid 1001)를 만든다.
# - 앱 로그·monitor 로그·호스트 summary의 시각을 같은 시간대(KST)로 맞추기 위해 tzdata를 넣는다.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Seoul

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        procps psmisc sysstat iproute2 ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

ENV AGENT_HOME=/home/agent/agent-app

RUN useradd -m -u 1001 -s /bin/bash agent && \
    mkdir -p "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" /home/agent/run /var/log/agent-app && \
    printf 'agent_api_key_test' > "$AGENT_HOME/api_keys/secret.key" && \
    chmod 600 "$AGENT_HOME/api_keys/secret.key" && \
    chown -R agent:agent /home/agent /var/log/agent-app

COPY monitor.sh /usr/local/bin/monitor.sh
COPY env/launch.sh /usr/local/bin/launch.sh
COPY env/snapshot.sh /usr/local/bin/snapshot.sh
RUN chmod 755 /usr/local/bin/monitor.sh /usr/local/bin/launch.sh /usr/local/bin/snapshot.sh

CMD ["sleep", "infinity"]
