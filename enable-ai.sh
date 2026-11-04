#!/usr/bin/env bash
# Turns the paid smart questions (Claude Haiku 5.5) ON or OFF for the live "lessonplay-web" container.
#   bash enable-ai.sh        asks for the API key (hidden typing, never printed or saved in a file) and recreates the container with it
#   bash enable-ai.sh off    recreates the container without the key (back to the free generator only)
# The container gets exactly the settings of the running one plus AI_PROVIDER and ANTHROPIC_API_KEY. The old container is kept, stopped.
# Even with the key, nothing is spent until "السماح بالذكاء المدفوع" is ticked in /admin/ai, and spending stops at the monthly cap.
set -u -o pipefail
NAME=lessonplay-web
SITE=https://lessonplay.duckdns.org/
say()  { echo "== $*"; }
fail() { echo "!! $*" >&2; exit 1; }
command -v docker >/dev/null || fail "docker not found (nothing changed)"
docker inspect "$NAME" >/dev/null 2>&1 || fail "container $NAME not found (nothing changed)"
MODE=on; [ "${1:-}" = "off" ] && MODE=off
umask 077
TMP=$(mktemp -d) || fail "no temporary folder"
trap 'rm -rf "$TMP"' EXIT
if docker inspect "$NAME-old" >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME-old")" = "false" ] || fail "$NAME-old is running: stop it first (nothing changed)"
    docker rm "$NAME-old" >/dev/null || fail "could not remove the previous leftover $NAME-old"
fi
if [ "$MODE" = on ]; then
    echo "Paste the API key (nothing is shown while typing), then press Enter:"
    read -rs ANTHROPIC_API_KEY; echo
    case "$ANTHROPIC_API_KEY" in sk-ant-*) ;; *) fail "that does not look like an Anthropic key (sk-ant-...). Nothing changed." ;; esac
    export ANTHROPIC_API_KEY
fi
say "1 reading the settings of the running container"
OLD_IMAGE=$(docker inspect -f '{{.Image}}' "$NAME") || fail "cannot read the image of $NAME"
python3 - "$NAME" "$OLD_IMAGE" > "$TMP/args" <<'PY' || fail "the running container has a setting this script does not carry over (nothing changed)"
import json
import subprocess
import sys

name, image = sys.argv[1], sys.argv[2]


def inspect(*a):
    return json.loads(subprocess.check_output(["docker", *a]))[0]


c = inspect("inspect", name)
im = inspect("image", "inspect", image)
cfg, hc, icfg = c["Config"], c["HostConfig"], im["Config"]
odd = []

# things this script does not carry over: stop before touching anything
for k in ("Privileged", "ReadonlyRootfs", "PublishAllPorts"):
    if hc.get(k):
        odd.append(k)
for k in ("CapAdd", "CapDrop", "SecurityOpt", "Devices", "Dns", "DnsSearch", "DnsOptions", "ExtraHosts", "Tmpfs", "Sysctls", "Ulimits",
          "VolumesFrom", "Links", "GroupAdd", "DeviceRequests"):
    if hc.get(k):
        odd.append(k)
for k in ("CpuShares", "CpuQuota", "CpuPeriod", "CpusetCpus", "CpusetMems", "PidsLimit", "MemoryReservation", "BlkioWeight"):
    if hc.get(k) and hc.get(k) not in (0, -1):
        odd.append(k)
if hc.get("MemorySwap") not in (None, 0, -1) and hc.get("MemorySwap") != 2 * (hc.get("Memory") or 0):
    odd.append("MemorySwap")
for k in ("Cmd", "Entrypoint", "WorkingDir", "User"):
    if (cfg.get(k) or None) != (icfg.get(k) or None):
        odd.append("Config." + k)
nets = list((c.get("NetworkSettings") or {}).get("Networks") or {})
mode = hc.get("NetworkMode") or "default"
if len(nets) > 1 or mode == "host" or mode.startswith("container:"):
    odd.append("networks " + ",".join(nets))
for m in c.get("Mounts") or []:
    if m.get("Type") not in ("volume", "bind"):
        odd.append("mount " + str(m.get("Type")))
if odd:
    print("not carried over: " + ", ".join(odd), file=sys.stderr)
    sys.exit(2)

args = ["--name", name]
rp = hc.get("RestartPolicy") or {}
if rp.get("Name"):
    args += ["--restart", rp["Name"] + (":%d" % rp["MaximumRetryCount"] if rp["Name"] == "on-failure" and rp.get("MaximumRetryCount") else "")]
if mode not in ("default", "bridge"):
    args += ["--network", mode]
for m in c.get("Mounts") or []:
    src = m["Name"] if m["Type"] == "volume" else m["Source"]
    args += ["-v", "%s:%s%s" % (src, m["Destination"], "" if m.get("RW", True) else ":ro")]
for port, binds in sorted((hc.get("PortBindings") or {}).items()):
    for b in binds or []:
        ip, hp = b.get("HostIp") or "", b.get("HostPort") or ""
        args += ["-p", (ip + ":" if ip else "") + hp + ":" + port if hp or ip else port]
image_env = set(icfg.get("Env") or [])
env_names = []
for e in cfg.get("Env") or []:
    if e not in image_env:
        args += ["-e", e]
        env_names.append(e.split("=", 1)[0])
if hc.get("Memory"):
    args += ["--memory", str(hc["Memory"])]
if hc.get("NanoCpus"):
    args += ["--cpus", "%g" % (hc["NanoCpus"] / 1e9)]
log = hc.get("LogConfig") or {}
if log.get("Type") and log["Type"] != "json-file":
    args += ["--log-driver", log["Type"]]
for k, v in sorted((log.get("Config") or {}).items()):
    args += ["--log-opt", "%s=%s" % (k, v)]

print("   restart=%s network=%s mounts=%s ports=%s env=%s" % (
    rp.get("Name") or "no", mode, [m["Destination"] for m in c.get("Mounts") or []],
    sorted((hc.get("PortBindings") or {})) or "none (reached through the network)", env_names or "none"), file=sys.stderr)
sys.stdout.write("".join(a + "\0" for a in args))
PY
mapfile -d '' -t RUN_ARGS < "$TMP/args"
[ "${#RUN_ARGS[@]}" -ge 2 ] || fail "could not read the settings (nothing changed)"
# drop any AI variables the old container had, then add ours
CLEAN=(); skip=0
for a in "${RUN_ARGS[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; case "$a" in AI_PROVIDER=*|ANTHROPIC_API_KEY=*) continue ;; *) CLEAN+=("-e" "$a"); continue ;; esac; fi
    if [ "$a" = "-e" ]; then skip=1; continue; fi
    CLEAN+=("$a")
done
if [ "$MODE" = on ]; then CLEAN+=("-e" "AI_PROVIDER=claude" "-e" "ANTHROPIC_API_KEY"); else CLEAN+=("-e" "AI_PROVIDER=offline"); fi
IMAGE=$(docker inspect -f '{{.Config.Image}}' "$NAME")
say "2 replacing the container ($IMAGE), AI $MODE"
docker stop "$NAME" >/dev/null || fail "could not stop the old container (nothing changed)"
docker rename "$NAME" "$NAME-old" || { docker start "$NAME" >/dev/null; fail "could not rename; started again (nothing changed)"; }
ok=0
if docker run -d "${CLEAN[@]}" "$IMAGE" >/dev/null; then
    for _ in $(seq 1 30); do
        sleep 2
        [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ] || break
        docker exec "$NAME" python -c "import sys, urllib.request as u; sys.exit(0 if u.urlopen('http://127.0.0.1:8100/', timeout=5).status == 200 else 1)" >/dev/null 2>&1 && { ok=1; break; }
    done
fi
if [ "$ok" != 1 ]; then
    echo "!! the new container did not answer; putting the old one back" >&2
    docker rm -f "$NAME" >/dev/null 2>&1
    docker rename "$NAME-old" "$NAME" && docker start "$NAME" >/dev/null && echo "== the old container is running again" >&2
    exit 1
fi
code=$(curl -s -o /dev/null -w '%{http_code}' "$SITE" || true)
say "3 public site: HTTP $code"
docker exec "$NAME" python -c "import os; print('   AI_PROVIDER =', os.environ.get('AI_PROVIDER'), '| key present:', bool(os.environ.get('ANTHROPIC_API_KEY')))"
echo "   nothing is spent until the box is ticked in /admin/ai. To go back: bash enable-ai.sh off"
