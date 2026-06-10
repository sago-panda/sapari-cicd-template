#!/usr/bin/env bash
# Renovate postUpgradeTask — cosign/trivy "버전" 핀이 갱신된 뒤, 같은 브랜치에서
# "sha256" 핀을 해당 버전의 공식 checksums.txt 값으로 동기화한다.
# (Renovate 는 체크섬을 계산할 수 없으므로 이 스크립트가 버전↔체크섬 원자성을 보장)
set -euo pipefail

sync_sha() { # $1=파일 $2=마커(cosign_sha256|trivy_sha256) $3=새 sha
  awk -v sha="$3" -v marker="$2" '
    $0 ~ marker":" { f=1 }
    f && /default:/ { sub(/default:.*/, "default: " sha); f=0 }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

for f in templates/*/template.yml; do
  # cosign: 파일에 cosign_sha256 핀이 있으면 그 파일의 cosign_version 기준으로 동기화
  if grep -q 'cosign_sha256:' "$f"; then
    ver=$(awk '/cosign_version:/{g=1;next} g&&/default:/{print $2;exit}' "$f")
    [ -n "$ver" ] || { echo "cosign_version 없음: $f"; exit 1; }
    sha=$(curl -sSfL "https://github.com/sigstore/cosign/releases/download/${ver}/cosign_checksums.txt" \
          | awk '$2=="cosign-linux-amd64"{print $1}')
    [ -n "$sha" ] || { echo "cosign ${ver} 체크섬 조회 실패"; exit 1; }
    sync_sha "$f" cosign_sha256 "$sha"
    echo "sync: $f cosign ${ver} → ${sha}"
  fi
  # trivy: 동일 (버전 표기는 v 없는 형식, 릴리스 태그는 v 접두)
  if grep -q 'trivy_sha256:' "$f"; then
    ver=$(awk '/trivy_version:/{g=1;next} g&&/default:/{print $2;exit}' "$f")
    [ -n "$ver" ] || { echo "trivy_version 없음: $f"; exit 1; }
    sha=$(curl -sSfL "https://github.com/aquasecurity/trivy/releases/download/v${ver}/trivy_${ver}_checksums.txt" \
          | awk -v t="trivy_${ver}_Linux-64bit.tar.gz" '$2==t{print $1}')
    [ -n "$sha" ] || { echo "trivy ${ver} 체크섬 조회 실패"; exit 1; }
    sync_sha "$f" trivy_sha256 "$sha"
    echo "sync: $f trivy ${ver} → ${sha}"
  fi
done
