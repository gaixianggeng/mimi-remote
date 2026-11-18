#!/usr/bin/env bash
set -euo pipefail

if [[ ${GITHUB_ACTIONS:-} != true || ${RUNNER_ENVIRONMENT:-} != github-hosted ||
      ${GITHUB_REPOSITORY:-} != gaixianggeng/mimi-remote ||
      ${GITHUB_REF:-} != refs/heads/codex/gh-979-relogin-acceptance ]]; then
  echo 'Desktop acceptance requires the dedicated GitHub-hosted test branch.' >&2
  exit 1
fi
[[ $EXPECTED_WIN_BUILD =~ ^(19045|26300)$ ]]
[[ $ISO_SHA256 =~ ^[0-9a-f]{64}$ ]]
[[ $ISO_URL == https://software-static.download.prss.microsoft.com/dbazure/* ]]
[[ -c /dev/kvm ]]

image=ghcr.io/dockur/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc
job_dir=$(mktemp -d "$RUNNER_TEMP/mimi-desktop-relogin.XXXXXXXX")
container="mimi-desktop-relogin-$EXPECTED_WIN_BUILD"
serial="$job_dir/storage/relogin.serial"
installer_name=Mimi-Remote-Setup-1.1.15-acceptance-unsigned.exe
mkdir -p "$job_dir/oem" "$job_dir/storage"

(
  cd "$RUNNER_TEMP/desktop-relogin"
  sha256sum --check "$installer_name.sha256"
  cp -- "$installer_name" "$job_dir/oem/Mimi-Remote-Setup.exe"
)
cp -- scripts/test-windows-desktop-relogin.ps1 "$job_dir/oem/WinUiLogonProbe.ps1"
printf '%s\r\n' \
  '@echo off' \
  'set MIMI_WIN_LOGON_ACCEPTANCE=gh979-desktop-oem-v1' \
  "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\OEM\\WinUiLogonProbe.ps1 -InstallerPath C:\\OEM\\Mimi-Remote-Setup.exe -ResultPath C:\\OEM\\result.json -ResultPort COM1 -ExpectedBuild $EXPECTED_WIN_BUILD" \
  > "$job_dir/oem/install.bat"

curl --fail --silent --show-error --location --retry 2 --max-time 900 \
  --output "$job_dir/custom.iso" "$ISO_URL"
printf '%s  %s\n' "$ISO_SHA256" "$job_dir/custom.iso" | sha256sum --check --status
echo "Microsoft evaluation ISO digest matched for build $EXPECTED_WIN_BUILD."

docker pull "$image"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --name "$container" --network none --device /dev/kvm \
  --env NETWORK=N --env SAMBA=N --env WEB=N --env DISPLAY=disabled \
  --env BOOT_MODE=windows_secure --env AUTOLOGIN=Y \
  --env USERNAME=MimiFixture --env "PASSWORD=$(openssl rand -hex 14)" \
  --env CPU_CORES=3 --env RAM_SIZE=8G --env DISK_SIZE=64G \
  --env SERIAL=file:/storage/relogin.serial --env 'ARGUMENTS=-nic none' \
  --volume "$job_dir/custom.iso:/custom.iso:ro" --volume "$job_dir/oem:/oem:ro" \
  --volume "$job_dir/storage:/storage" "$image"

deadline=$((SECONDS+2700))
while (( SECONDS < deadline )); do
  if [[ -s $serial ]]; then
    records=$(tr -d '\r' < "$serial" | sed -n 's/^MIMI_RELOGIN_RESULT=//p')
    if [[ -n $records ]]; then
      last=$(printf '%s\n' "$records" | tail -n 1)
      if jq -e '.status == "passed"' <<< "$last" >/dev/null; then
        printf '%s\n' "$records"
        jq -e --argjson build "$EXPECTED_WIN_BUILD" '
          .build == $build and .transition == "logoff" and .newLogon and
          .trayBackground and .oneNativeProcess and .sameInstanceVisible and
          .nativeBackend and .localAccessAndIdentityPreserved
        ' <<< "$last" >/dev/null
        exit 0
      fi
      if jq -e '.status == "failed"' <<< "$last" >/dev/null; then
        printf '%s\n' "$records" >&2
        exit 1
      fi
    fi
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    docker logs --tail 40 "$container" >&2
    exit 1
  fi
  sleep 15
done
docker logs --tail 40 "$container" >&2
[[ ! -s $serial ]] || tr -d '\r' < "$serial" | grep '^MIMI_RELOGIN_RESULT=' >&2
echo 'Timed out waiting for the real desktop to sign out, sign in, and report tray state.' >&2
exit 1
