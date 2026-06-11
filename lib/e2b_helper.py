#!/usr/bin/env python3
"""E2B transport helper for Ralph (Issue #75).

Thin CLI over the official E2B Python SDK so lib/sandbox_e2b.sh can drive
cloud sandboxes from bash. Every subcommand prints a single JSON object on
stdout (machine-parseable with jq), except:

  exec      streams the remote command's stdout/stderr to the local
            stdout/stderr and exits with the remote exit code
  download  writes a gzipped tar of files changed since the last sync
            marker to stdout (possibly an empty archive)

Secrets never travel via argv: E2B_API_KEY and ANTHROPIC_API_KEY are read
from the environment, and file content (credential seeding, project upload)
arrives via stdin.

Exit codes: 0 ok, 1 operation failed, 2 usage error (argparse),
3 SDK not installed, 4 E2B_API_KEY missing.
"""

import argparse
import json
import os
import shlex
import sys

try:
    from e2b import CommandExitException, Sandbox
    _SDK_IMPORT_ERROR = None
except ImportError as exc:  # pragma: no cover - depends on environment
    Sandbox = None
    CommandExitException = ()
    _SDK_IMPORT_ERROR = str(exc)

UPLOAD_STAGING = "/tmp/ralph_upload.tgz"
DOWNLOAD_STAGING = "/tmp/ralph_download.tgz"
CHANGED_LIST = "/tmp/ralph_changed.list"
# Archive member carrying the sandbox's CURRENT file list, so the host can
# propagate sandbox-side deletions/renames (stale-file divergence otherwise)
MANIFEST_NAME = ".ralph_e2b_manifest"


def _emit(obj):
    print(json.dumps(obj))


def _die(message, code=1):
    _emit({"ok": False, "error": message})
    sys.exit(code)


def _require_sdk():
    if Sandbox is None:
        _die("E2B SDK not installed (pip install e2b): %s" % _SDK_IMPORT_ERROR, 3)
    if not os.environ.get("E2B_API_KEY"):
        _die("E2B_API_KEY is not set in the environment", 4)


def _connect(sandbox_id):
    try:
        return Sandbox.connect(sandbox_id)
    except Exception as exc:
        _die("failed to connect to sandbox %s: %s" % (sandbox_id, exc))


def _sync_marker(workdir):
    # The marker lives NEXT TO the workspace (not inside it) so it is never
    # swept into uploads/downloads of workspace content.
    return os.path.join(os.path.dirname(workdir.rstrip("/")), ".ralph_sync_marker")


def cmd_check(_args):
    if Sandbox is None:
        _emit({"ok": False, "error": "E2B SDK not installed (pip install e2b): %s" % _SDK_IMPORT_ERROR})
        sys.exit(3)
    version = "unknown"
    try:
        from importlib.metadata import version as _pkg_version
        version = _pkg_version("e2b")
    except Exception:
        pass
    _emit({"ok": True, "sdk_version": version})


def cmd_create(args):
    _require_sdk()
    kwargs = {"timeout": args.timeout}
    # Claude auth travels as a sandbox env var, never on a command line
    if os.environ.get("ANTHROPIC_API_KEY"):
        kwargs["envs"] = {"ANTHROPIC_API_KEY": os.environ["ANTHROPIC_API_KEY"]}
    try:
        if args.template:
            sandbox = Sandbox.create(args.template, **kwargs)
        else:
            sandbox = Sandbox.create(**kwargs)
    except Exception as exc:
        _die("failed to create sandbox (template: %s): %s" % (args.template or "default", exc))
    _emit({"ok": True, "sandbox_id": sandbox.sandbox_id})


def cmd_connect(args):
    _require_sdk()
    sandbox = _connect(args.sandbox_id)
    _emit({"ok": True, "sandbox_id": sandbox.sandbox_id})


def cmd_info(args):
    _require_sdk()
    sandbox = _connect(args.sandbox_id)
    try:
        info = sandbox.get_info()
        state = str(getattr(info, "state", "running")).rsplit(".", 1)[-1].lower()
    except Exception as exc:
        # connect() above succeeded, so the sandbox is reachable — degrade to
        # "running" rather than failing: a hard failure here would make the
        # caller recreate + re-upload a perfectly live sandbox every iteration.
        print("e2b info: get_info failed, assuming running: %s" % exc, file=sys.stderr)
        state = "running"
    _emit({"ok": True, "sandbox_id": args.sandbox_id, "state": state})


def cmd_exec(args):
    _require_sdk()
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        _die("exec: no command given (use: exec --sandbox-id ID -- cmd args...)", 2)
    sandbox = _connect(args.sandbox_id)

    def _out(data):
        sys.stdout.write(data)
        sys.stdout.flush()

    def _err(data):
        sys.stderr.write(data)
        sys.stderr.flush()

    try:
        # timeout=0 disables the SDK-side limit; Ralph's host-side
        # portable_timeout governs the iteration budget (exit 124).
        result = sandbox.commands.run(
            shlex.join(command),
            cwd=args.cwd,
            timeout=0,
            on_stdout=_out,
            on_stderr=_err,
        )
    except CommandExitException as exc:
        sys.exit(getattr(exc, "exit_code", 1) or 1)
    except Exception as exc:
        # NOT _die(): exec's stdout carries the streamed remote output (it
        # becomes Ralph's claude output file), so errors must stay on stderr.
        print("e2b exec failed: %s" % exc, file=sys.stderr)
        sys.exit(1)
    sys.exit(getattr(result, "exit_code", 0) or 0)


def cmd_upload(args):
    _require_sdk()
    data = sys.stdin.buffer.read()
    if not data:
        _die("upload: no tar data on stdin")
    sandbox = _connect(args.sandbox_id)
    marker = _sync_marker(args.dest)
    try:
        sandbox.files.write(UPLOAD_STAGING, data)
        sandbox.commands.run(
            "mkdir -p {dest} && tar -xzf {staging} -C {dest} && rm -f {staging} && touch {marker}".format(
                dest=shlex.quote(args.dest),
                staging=shlex.quote(UPLOAD_STAGING),
                marker=shlex.quote(marker),
            )
        )
    except Exception as exc:
        _die("upload failed: %s" % exc)
    _emit({"ok": True, "bytes": len(data)})


def cmd_download(args):
    _require_sdk()
    sandbox = _connect(args.sandbox_id)
    marker = _sync_marker(args.src)
    # Besides the changed files, every download carries a manifest of ALL
    # current workspace files (minus .git) so the host can delete files that
    # disappeared in the sandbox. The sandbox is always Linux/GNU.
    # The sync marker is NOT advanced here: the host calls ack-download after
    # it has successfully extracted the archive, so a failure anywhere in
    # between leaves the changes re-downloadable (at-least-once delivery;
    # re-extraction is an idempotent overwrite).
    script = (
        "cd {src} && "
        "if [ -f {marker} ]; then find . -type f -newer {marker} -print0; else : ; fi > {changed} && "
        "find . -type f ! -path './.git/*' > /tmp/{manifest} && "
        "tar -czf {staging} --null -T {changed} -C /tmp {manifest}"
    ).format(
        src=shlex.quote(args.src),
        marker=shlex.quote(marker),
        changed=shlex.quote(CHANGED_LIST),
        staging=shlex.quote(DOWNLOAD_STAGING),
        manifest=shlex.quote(MANIFEST_NAME),
    )
    try:
        sandbox.commands.run(script)
        data = sandbox.files.read(DOWNLOAD_STAGING, format="bytes")
    except Exception as exc:
        # NOT _die(): download's stdout carries raw tar bytes; JSON on stdout
        # would corrupt the archive. Errors must stay on stderr.
        print("e2b download failed: %s" % exc, file=sys.stderr)
        sys.exit(1)
    sys.stdout.buffer.write(bytes(data))
    sys.stdout.buffer.flush()


def cmd_ack_download(args):
    _require_sdk()
    sandbox = _connect(args.sandbox_id)
    marker = _sync_marker(args.src)
    try:
        sandbox.commands.run("touch %s && rm -f %s %s /tmp/%s" % (
            shlex.quote(marker), shlex.quote(DOWNLOAD_STAGING),
            shlex.quote(CHANGED_LIST), shlex.quote(MANIFEST_NAME)))
    except Exception as exc:
        _die("ack-download failed: %s" % exc)
    _emit({"ok": True})


def cmd_write_file(args):
    _require_sdk()
    data = sys.stdin.buffer.read()
    sandbox = _connect(args.sandbox_id)
    try:
        parent = os.path.dirname(args.path)
        if parent:
            sandbox.commands.run("mkdir -p %s" % shlex.quote(parent))
        sandbox.files.write(args.path, data)
        if args.mode:
            sandbox.commands.run("chmod %s %s" % (shlex.quote(args.mode), shlex.quote(args.path)))
    except Exception as exc:
        _die("write-file failed for %s: %s" % (args.path, exc))
    _emit({"ok": True, "path": args.path})


def cmd_kill(args):
    _require_sdk()
    try:
        sandbox = Sandbox.connect(args.sandbox_id)
        sandbox.kill()
    except Exception:
        # Already dead/expired sandboxes count as killed — kill is idempotent
        pass
    _emit({"ok": True})


def build_parser():
    parser = argparse.ArgumentParser(prog="e2b_helper", description=__doc__)
    sub = parser.add_subparsers(dest="subcommand", required=True)

    sub.add_parser("check").set_defaults(func=cmd_check)

    p = sub.add_parser("create")
    p.add_argument("--template", default="")
    p.add_argument("--timeout", type=int, default=3600)
    p.set_defaults(func=cmd_create)

    p = sub.add_parser("connect")
    p.add_argument("--sandbox-id", required=True)
    p.set_defaults(func=cmd_connect)

    p = sub.add_parser("info")
    p.add_argument("--sandbox-id", required=True)
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("exec")
    p.add_argument("--sandbox-id", required=True)
    p.add_argument("--cwd", default=None)
    p.add_argument("command", nargs=argparse.REMAINDER)
    p.set_defaults(func=cmd_exec)

    p = sub.add_parser("upload")
    p.add_argument("--sandbox-id", required=True)
    p.add_argument("--dest", required=True)
    p.set_defaults(func=cmd_upload)

    p = sub.add_parser("download")
    p.add_argument("--sandbox-id", required=True)
    p.add_argument("--src", required=True)
    p.set_defaults(func=cmd_download)

    p = sub.add_parser("ack-download")
    p.add_argument("--sandbox-id", required=True)
    p.add_argument("--src", required=True)
    p.set_defaults(func=cmd_ack_download)

    p = sub.add_parser("write-file")
    p.add_argument("--sandbox-id", required=True)
    p.add_argument("--path", required=True)
    p.add_argument("--mode", default="")
    p.set_defaults(func=cmd_write_file)

    p = sub.add_parser("kill")
    p.add_argument("--sandbox-id", required=True)
    p.set_defaults(func=cmd_kill)

    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
