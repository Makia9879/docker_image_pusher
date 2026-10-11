#!/usr/bin/env bash
# Local port of docker_image_pusher's .github/workflows/docker.yaml
# Usage: mirror-images.sh [images.txt] | --status   (default /workspace/.box/mirror/images.txt)
# env: ALIYUN_REGISTRY, ALIYUN_NAME_SPACE, DOCKER (default: "sudo docker --config $HOME/.docker" when socket not accessible)
# Relies on existing `docker login` in ~/.docker/config.json. Logs to /workspace/logs/mirror-images.log
set -uo pipefail
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
ALIYUN_NAME_SPACE="${ALIYUN_NAME_SPACE:-makia_docker}"
STATUS=/workspace/logs/mirror-progress.txt
[[ "${1:-}" == "--status" ]] && { cat "$STATUS" 2>/dev/null || echo "no status yet"; exit 0; }
LIST="${1:-/workspace/.box/mirror/images.txt}"
LOG=/workspace/logs/mirror-images.log; mkdir -p /workspace/logs
exec > >(while IFS= read -r l; do echo "[$(date '+%F %T')] $l"; done | tee -a "$LOG") 2>&1
if [[ -z "${DOCKER:-}" ]]; then docker info >/dev/null 2>&1 && DOCKER=docker || DOCKER="sudo docker --config $HOME/.docker"; fi
declare -A duplicate_images temp_map
while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "${line// }" ]] && continue; echo "$line" | grep -q '^\s*#' && continue
  image=$(echo "$line" | awk '{print $NF}'); image="${image%%@*}"
  image_name_tag=$(echo "$image" | awk -F'/' '{print $NF}')
  name_space=$(echo "$image" | awk -F'/' '{if (NF==3) print $2; else if (NF==2) print $1; else print ""}')_
  image_name=$(echo "$image_name_tag" | awk -F':' '{print $1}')
  if [[ -n "${temp_map[$image_name]:-}" ]]; then
    [[ "${temp_map[$image_name]}" != "$name_space" ]] && duplicate_images[$image_name]=true
  else temp_map[$image_name]=$name_space; fi
done < "$LIST"
fails=0
mapfile -t ENTRIES < <(grep -vE '^\s*(#|$)' "$LIST")
TOTAL=${#ENTRIES[@]}; declare -A ST; DONE=0; NFAIL=0; LAST=""
write_status(){ local cur="$1" n=$((DONE+NFAIL)) pct=0; ((TOTAL)) && pct=$((n*100/TOTAL))
  { echo "[$n/$TOTAL] $pct% $LAST (done $DONE, failed $NFAIL, current: ${cur:-none})"
    for e in "${ENTRIES[@]}"; do echo "${ST[$e]:-PENDING  $e}"; done; } > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
  local f=$((n*10/(TOTAL>0?TOTAL:1))) b=""; for ((k=0;k<10;k++)); do ((k<f)) && b+="#" || b+="-"; done
  echo "PROGRESS [$b] $n/$TOTAL"; }
write_status "${ENTRIES[0]:-}"
while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "${line// }" ]] && continue; echo "$line" | grep -q '^\s*#' && continue
  platform=$(echo "$line" | awk -F'--platform[ =]' '{if (NF>1) print $2}' | awk '{print $1}')
  image=$(echo "$line" | awk '{print $NF}')
  platform_prefix=""; [[ -n "$platform" ]] && platform_prefix="${platform//\//_}_"
  image_name_tag=$(echo "$image" | awk -F'/' '{print $NF}')
  name_space=$(echo "$image" | awk -F'/' '{if (NF==3) print $2; else if (NF==2) print $1; else print ""}')
  image_name=$(echo "$image_name_tag" | awk -F':' '{print $1}')
  name_space_prefix=""; [[ -n "${duplicate_images[$image_name]:-}" && -n "$name_space" ]] && name_space_prefix="${name_space}_"
  image_name_tag="${image_name_tag%%@*}"
  new_image="$ALIYUN_REGISTRY/$ALIYUN_NAME_SPACE/$platform_prefix$name_space_prefix$image_name_tag"
  ok=0
  for i in 1 2 3; do
    echo "docker pull $line (try $i)"
    timeout ${PULL_TIMEOUT:-900} $DOCKER pull $line && $DOCKER tag "$image" "$new_image" && timeout ${PUSH_TIMEOUT:-600} $DOCKER push "$new_image" && ok=1 && break
    sleep $((i*15))
  done
  $DOCKER rmi "$image" "$new_image" >/dev/null 2>&1
  if [[ $ok == 1 ]]; then echo "RESULT OK $new_image <= $line"; DONE=$((DONE+1)); ST[$line]="OK       $new_image"; LAST="OK ${new_image##*/}"
  else echo "RESULT FAIL $new_image <= $line"; fails=1; NFAIL=$((NFAIL+1)); ST[$line]="FAIL     $new_image"; LAST="FAIL ${new_image##*/}"; fi
  n=$((DONE+NFAIL)); write_status "${ENTRIES[$n]:-}"
done < "$LIST"
exit $fails
