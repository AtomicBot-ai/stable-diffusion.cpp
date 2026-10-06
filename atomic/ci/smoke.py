#!/usr/bin/env python3
"""Smoke-test one unpacked stable-diffusion.cpp archive the way Atomic Chat drives it.

Stdlib only, so it runs on the bare arm64 runners (ubuntu-24.04-arm, windows-11-arm) and on a
user's machine. Steps, each fatal on failure:

  1. `sd-cli --help` prints the marker the app's install probe looks for (`--cfg-scale`).
  2. `sd-cli --list-devices` lists a CPU device (and, with --expect-device, that one too).
  3. `sd-server -m <model>` comes up, answers `GET /v1/models` and `GET /sdcpp/v1/capabilities`.
  4. `POST /sdcpp/v1/img_gen`, poll `GET /sdcpp/v1/jobs/<id>` to `completed`, decode the PNG and
     check it is not a blank frame.

This mirrors atomic-chat-core's src/diffusion/{server-process,jobs,image-job}.ts.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

PROBE_MARKERS = ("stable-diffusion.cpp", "--cfg-scale")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# A 256x256 frame of one colour compresses to well under 2 KB; a real SD-Turbo image is 50-120 KB.
MIN_REAL_PNG_BYTES = 20_000


def log(msg: str) -> None:
    print(f"[smoke] {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"::error::{msg}" if os.environ.get("GITHUB_ACTIONS") else f"[smoke] FAIL: {msg}", flush=True)
    sys.exit(1)


def exe(directory: Path, name: str) -> Path:
    path = directory / (name + ".exe" if os.name == "nt" else name)
    if not path.is_file():
        fail(f"{path} is missing from the archive")
    return path


def child_env(directory: Path, extra_lib_dirs: list[str]) -> dict[str, str]:
    """The environment atomic-chat-core's buildProcessEnv gives sd-server."""
    env = dict(os.environ)
    dirs = [str(directory), *extra_lib_dirs]
    if os.name == "nt":
        env["PATH"] = os.pathsep.join([*dirs, env.get("PATH", "")])
    else:
        env["LD_LIBRARY_PATH"] = os.pathsep.join([*dirs, env.get("LD_LIBRARY_PATH", "")]).rstrip(os.pathsep)
    return env


def run(cmd: list[str], env: dict[str, str], cwd: Path, timeout: int = 300) -> str:
    log("$ " + " ".join(cmd))
    proc = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    out = (proc.stdout or "") + (proc.stderr or "")
    print(out[-4000:], flush=True)
    if proc.returncode != 0:
        fail(f"{Path(cmd[0]).name} exited with {proc.returncode}")
    return out


def ensure_model(path: Path, url: str | None, sha256: str | None) -> Path:
    if path.is_file() and (not sha256 or file_sha256(path) == sha256):
        log(f"model {path} present")
        return path
    if not url:
        fail(f"model {path} is missing and no --model-url was given")
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".part")
    log(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=60) as response, open(partial, "wb") as out:
        shutil.copyfileobj(response, out, length=8 << 20)
    if sha256 and file_sha256(partial) != sha256:
        partial.unlink(missing_ok=True)
        fail(f"model sha256 mismatch for {url}")
    partial.replace(path)
    return path


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def http(method: str, url: str, body: dict | None = None, timeout: float = 10) -> tuple[int, str]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", required=True, type=Path, help="unpacked archive")
    parser.add_argument("--model", required=True, type=Path, help="single-file checkpoint (-m)")
    parser.add_argument("--model-url")
    parser.add_argument("--model-sha256")
    parser.add_argument("--lib-dir", action="append", default=[], help="extra loader dir (e.g. a libcuda stub)")
    parser.add_argument("--expect-device", help="a device name prefix --list-devices must show, e.g. CUDA0")
    parser.add_argument("--backend", help="--backend for sd-server, e.g. CUDA0 or cpu")
    parser.add_argument("--size", type=int, default=256)
    parser.add_argument("--steps", type=int, default=1)
    parser.add_argument("--out", type=Path, help="where to keep the generated PNG")
    parser.add_argument("--load-timeout", type=int, default=900)
    parser.add_argument("--job-timeout", type=int, default=1800)
    args = parser.parse_args()

    directory = args.dir.resolve()
    env = child_env(directory, args.lib_dir)
    cli = exe(directory, "sd-cli")
    server = exe(directory, "sd-server")

    help_text = run([str(cli), "--help"], env, directory).lower()
    if not any(marker in help_text for marker in PROBE_MARKERS):
        fail("sd-cli --help does not look like stable-diffusion.cpp")
    log("PASS --help")

    devices = run([str(cli), "--list-devices"], env, directory)
    names = [line.split("\t", 1)[0].strip() for line in devices.splitlines() if "\t" in line]
    log(f"devices: {names}")
    if not any(name.upper().startswith("CPU") for name in names):
        fail("--list-devices shows no CPU device")
    if args.expect_device and not any(name.lower().startswith(args.expect_device.lower()) for name in names):
        fail(f"--list-devices shows no {args.expect_device} device")
    log("PASS --list-devices")

    # sd-server runs with the archive as its cwd, like the core starts it, so the path must be absolute.
    model = ensure_model(args.model.expanduser().resolve(), args.model_url, args.model_sha256)
    port = free_port()
    cmd = [str(server), "-m", str(model), "--listen-ip", "127.0.0.1", "--listen-port", str(port), "-v"]
    if args.backend:
        cmd += ["--backend", args.backend]
    log("$ " + " ".join(cmd))
    proc = subprocess.Popen(
        cmd, env=env, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
    )
    tail: list[str] = []

    def pump() -> None:
        assert proc.stdout is not None
        for line in proc.stdout:
            tail.append(line.rstrip())
            del tail[:-400]
            print(f"  | {line.rstrip()}", flush=True)

    threading.Thread(target=pump, daemon=True).start()
    base = f"http://127.0.0.1:{port}"
    try:
        deadline = time.time() + args.load_timeout
        while True:
            if proc.poll() is not None:
                fail(f"sd-server exited with {proc.returncode} before it listened")
            try:
                status, _ = http("GET", f"{base}/v1/models", timeout=5)
                if status == 200:
                    break
            except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
                pass
            if time.time() > deadline:
                fail("sd-server did not load the model in time")
            time.sleep(1)
        status, caps = http("GET", f"{base}/sdcpp/v1/capabilities")
        if status != 200:
            fail(f"/sdcpp/v1/capabilities answered {status}")
        log(f"PASS server up; capabilities: {caps[:300]}")

        body = {
            "prompt": "a red apple on a wooden table, studio photo",
            "negative_prompt": "",
            "width": args.size,
            "height": args.size,
            "batch_count": 1,
            "output_format": "png",
            "seed": 42,
            "sample_params": {"sample_steps": args.steps, "guidance": {"txt_cfg": 1}},
        }
        started = time.time()
        status, text = http("POST", f"{base}/sdcpp/v1/img_gen", body)
        if status not in (200, 202):
            fail(f"img_gen answered {status}: {text[:500]}")
        job_id = json.loads(text).get("id")
        if not isinstance(job_id, str):
            fail(f"img_gen returned no job id: {text[:500]}")
        deadline = time.time() + args.job_timeout
        job: dict = {}
        while True:
            status, text = http("GET", f"{base}/sdcpp/v1/jobs/{job_id}")
            if status == 200:
                job = json.loads(text)
                if job.get("status") == "completed":
                    break
                if job.get("status") in ("failed", "cancelled"):
                    fail(f"job {job.get('status')}: {json.dumps(job.get('error'))}")
            if proc.poll() is not None:
                fail(f"sd-server exited with {proc.returncode} during the job")
            if time.time() > deadline:
                fail("the job did not finish in time")
            time.sleep(1)
        elapsed = time.time() - started
        images = (job.get("result") or {}).get("images") or []
        if not images or not isinstance(images[0].get("b64_json"), str):
            fail("completed job carries no image")
        png = base64.b64decode(images[0]["b64_json"])
        if not png.startswith(PNG_SIGNATURE):
            fail("result is not a PNG")
        if len(png) < MIN_REAL_PNG_BYTES:
            fail(f"result PNG is only {len(png)} bytes: a blank or NaN frame")
        out = args.out or Path(tempfile.gettempdir()) / "sd-smoke.png"
        out.write_bytes(png)
        log(f"PASS img_gen {args.size}x{args.size} in {elapsed:.1f}s -> {out} ({len(png)} bytes)")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
