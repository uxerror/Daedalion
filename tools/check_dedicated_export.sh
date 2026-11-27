#!/usr/bin/env bash
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
server_pid=
client_pid=
cleanup() {
	for pid in "$client_pid" "$server_pid"; do
		if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
	done
	rm -rf "$tmp"
}
trap cleanup EXIT
if "$root/tools/export_dedicated.sh" "$tmp/daedalion-server"; then
	:
else
	rc=$?
	if [[ $rc == 77 ]]; then echo "SKIP dedicated binary smoke: matching export templates missing"; exit 0; fi
	exit "$rc"
fi
port=$(python3 -c 'import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$tmp/server.cfg" <<CFG
[server]
port=$port
save_dir="$tmp/data"
world="probe"
autosave_seconds=0
CFG
world="$tmp/data/worlds/probe"
await_log() {
	local pattern=$1 log=$2 pid=$3
	for ((i=0; i<300; i++)); do
		if grep -qF "$pattern" "$log"; then return; fi
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.1
	done
	cat "$log" >&2
	exit 1
}
boot() {
	XDG_DATA_HOME="$tmp/server-home" nice -n 19 "$tmp/daedalion-server" --headless > "$tmp/server-$1.log" 2>&1 &
	server_pid=$!
	await_log "NET BOOT dedicated_server=true" "$tmp/server-$1.log" "$server_pid"
	await_log "NET READY port=$port" "$tmp/server-$1.log" "$server_pid"
}
stop_server() {
	touch "$world/stop.request"
	await_log "NET STOP OK" "$tmp/server-$1.log" "$server_pid"
	wait "$server_pid"
	server_pid=
}
boot 1
touch "$world/save.request"
await_log "NET SAVE OK generation=" "$tmp/server-1.log" "$server_pid"
test -s "$world/current/world.v2.json"
stop_server 1
boot 2
XDG_DATA_HOME="$tmp/client-home" nice -n 19 "${GODOT_BIN:-godot}" --headless --path "$root" \
	res://tests/net/process_peer.tscn -- --role export-client --name Probe --port "$port" \
	--stop "$tmp/client.stop" > "$tmp/client.log" 2>&1 &
client_pid=$!
await_log "NET MENU PLAYING" "$tmp/client.log" "$client_pid"
touch "$tmp/client.stop"
await_log "NET CLIENT STOP" "$tmp/client.log" "$client_pid"
wait "$client_pid"
client_pid=
stop_server 2
if grep -E 'SCRIPT ERROR|Parse Error' "$tmp"/*.log; then exit 1; fi
echo "PASS exported dedicated boot, empty save, orderly restart and ENet client"
