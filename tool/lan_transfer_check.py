"""Prepare isolated LAN peers and send commands to test/manual/lan_transfer_peer.dart."""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import uuid


def write_json(path, value, *, exclusive=False):
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    with os.fdopen(os.open(path, flags, 0o600), "w", encoding="utf-8") as handle:
        json.dump(value, handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="write two disposable identity configs")
    for name in ("output", "local-root", "remote-root", "local-host", "remote-host"):
        prepare.add_argument("--" + name, required=True)
    prepare.add_argument("--port", type=int, default=10042)
    command = commands.add_parser("command", help="submit one command after the peer is ready")
    command.add_argument("--config", required=True)
    command.add_argument("action", choices=("connect", "create", "send", "text", "disconnect", "retry", "stop"))
    command.add_argument("--path")
    command.add_argument("--mib", type=int)
    command.add_argument("--pattern", type=int, default=7)
    command.add_argument("--transfer-id")
    status = commands.add_parser("status", help="show each transfer's latest state")
    status.add_argument("--config", required=True)
    args = parser.parse_args()

    if args.command == "prepare":
        output = Path(args.output)
        output.mkdir(parents=True, mode=0o700, exist_ok=True)
        if any((output / (name + ".json")).exists() for name in ("local", "remote")):
            parser.error("choose a fresh output directory; existing identities must not be replaced")
        if not 1024 <= args.port <= 65535:
            parser.error("port must be between 1024 and 65535")
        seeds = [base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=") for _ in range(2)]
        identities = ["lan-test-" + str(uuid.uuid4()) for _ in range(2)]
        roots = [args.local_root, args.remote_root]
        hosts = [args.local_host, args.remote_host]
        for index, name in enumerate(("local", "remote")):
            config = dict(root=roots[index], localId=identities[index], peerId=identities[1-index],
                          localHost=hosts[index], peerHost=hosts[1-index], port=args.port,
                          peerPort=args.port, seed=seeds[index], peerSeed=seeds[1-index])
            write_json(output / (name + ".json"), config, exclusive=True)
        print(f"Created {output / 'local.json'} and {output / 'remote.json'}; copy each to its test machine.")
        return

    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    root = Path(config["root"])
    if not (root / "events.jsonl").is_file():
        parser.error("start the matching Flutter test peer and wait for its ready event first")
    if args.command == "command":
        if args.action in ("create", "send") and not args.path:
            parser.error("create/send requires --path relative to the test data directory")
        if args.action == "create" and (args.mib is None or not 0 <= args.mib <= 4096):
            parser.error("create requires --mib between 0 and 4096")
        if args.action == "retry" and not args.transfer_id:
            parser.error("retry requires --transfer-id")
        value = dict(id=str(uuid.uuid4()), action=args.action)
        for key, item in (("path", args.path), ("mib", args.mib), ("pattern", args.pattern), ("transferId", args.transfer_id)):
            if item is not None:
                value[key] = item
        write_json(root / "command.json", value)
        print(json.dumps(value))
        return

    transfers = {}
    latest_command = None
    for line in (root / "events.jsonl").read_text(encoding="utf-8").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event["event"] == "transfer":
            transfers[event["transferId"]] = event
        elif event["event"].startswith("command_"):
            latest_command = event
    print(json.dumps(dict(command=latest_command, transfers=list(transfers.values())), indent=2))


if __name__ == "__main__":
    main()
