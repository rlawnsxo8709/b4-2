#!/usr/bin/env bash
# 실험 이미지 b4-2-lab:latest 를 빌드한다.
# 빌드 컨텍스트는 저장소 루트지만 .dockerignore 로 monitor.sh, env/launch.sh, env/snapshot.sh 만 들어간다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker build -t b4-2-lab:latest -f "$ROOT/env/Dockerfile" "$ROOT"
