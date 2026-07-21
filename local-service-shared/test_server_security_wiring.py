import asyncio
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import types
import unittest

from fastapi.testclient import TestClient

from local_service_security import (
    AUTH_ENV_NAME,
    AUTH_HEADER_NAME,
    MAX_HTTP_AUDIO_BYTES,
    MAX_JSON_BYTES,
    MissingAuthToken,
)


_ROOT = Path(__file__).resolve().parent.parent
_TOKEN = "wiring-test-token-that-must-never-be-logged"


class _FakeWebSocket:
    def __init__(self, headers):
        self.headers = headers
        self.accepted = False
        self.closed = []

    async def accept(self):
        self.accepted = True

    async def close(self, code=1000, reason=None):
        self.closed.append((code, reason))


def _load_server(relative_path, module_name, stub_sensevoice=False):
    if stub_sensevoice:
        stub = types.ModuleType("sensevoice_model")
        stub.load_model = lambda **_: None
        stub.StreamingSenseVoice = object
        sys.modules["sensevoice_model"] = stub

    spec = importlib.util.spec_from_file_location(module_name, _ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    previous = os.environ.get(AUTH_ENV_NAME)
    os.environ[AUTH_ENV_NAME] = _TOKEN
    try:
        spec.loader.exec_module(module)
    finally:
        if previous is None:
            os.environ.pop(AUTH_ENV_NAME, None)
        else:
            os.environ[AUTH_ENV_NAME] = previous
    return module


class ServerSecurityWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sensevoice = _load_server(
            "sensevoice-server/server.py",
            "muse_test_sensevoice_server",
            stub_sensevoice=True,
        )
        cls.qwen = _load_server(
            "qwen3-asr-server/server.py",
            "muse_test_qwen_server",
        )

    def test_both_health_routes_require_the_process_token(self):
        for module in (self.sensevoice, self.qwen):
            with self.subTest(module=module.__name__), TestClient(
                module.app,
                base_url="http://127.0.0.1",
            ) as client:
                self.assertEqual(client.get("/health").status_code, 401)
                self.assertEqual(
                    client.get(
                        "/health",
                        headers={AUTH_HEADER_NAME: "wrong"},
                    ).status_code,
                    401,
                )
                self.assertEqual(
                    client.get(
                        "/health",
                        headers={AUTH_HEADER_NAME: _TOKEN},
                    ).status_code,
                    200,
                )

    def test_both_websockets_reject_missing_token_before_accept(self):
        for module in (self.sensevoice, self.qwen):
            with self.subTest(module=module.__name__):
                websocket = _FakeWebSocket({"host": "127.0.0.1:8765"})
                asyncio.run(module.websocket_endpoint(websocket))
                self.assertFalse(websocket.accepted)
                self.assertTrue(websocket.closed)

    def test_qwen_transcribe_rejects_odd_and_oversized_pcm(self):
        with TestClient(self.qwen.app, base_url="http://127.0.0.1") as client:
            headers = {
                AUTH_HEADER_NAME: _TOKEN,
                "Content-Type": "application/octet-stream",
            }
            self.assertEqual(
                client.post("/transcribe", headers=headers, content=b"x" * 101).status_code,
                400,
            )
            oversized_headers = {
                **headers,
                "Content-Length": str(MAX_HTTP_AUDIO_BYTES + 2),
            }
            response = client.post(
                "/transcribe",
                headers=oversized_headers,
                content=b"",
            )
            self.assertEqual(response.status_code, 413)

    def test_both_llm_routes_reject_malformed_and_oversized_json(self):
        for module in (self.sensevoice, self.qwen):
            with self.subTest(module=module.__name__), TestClient(
                module.app,
                base_url="http://127.0.0.1",
            ) as client:
                headers = {
                    AUTH_HEADER_NAME: _TOKEN,
                    "Content-Type": "application/json",
                }
                self.assertEqual(
                    client.post(
                        "/v1/chat/completions",
                        headers=headers,
                        content=b"not-json",
                    ).status_code,
                    400,
                )
                oversized_headers = {
                    **headers,
                    "Content-Length": str(MAX_JSON_BYTES + 1),
                }
                self.assertEqual(
                    client.post(
                        "/v1/chat/completions",
                        headers=oversized_headers,
                        content=b"",
                    ).status_code,
                    413,
                )

    def test_startup_gate_and_auth_failures_do_not_log_token(self):
        for module in (self.sensevoice, self.qwen):
            with self.subTest(module=module.__name__):
                with self.assertRaises(MissingAuthToken):
                    module.configure_auth_token({})

                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    with TestClient(
                        module.app,
                        base_url="http://127.0.0.1",
                    ) as client:
                        response = client.get(
                            "/health",
                            headers={AUTH_HEADER_NAME: "wrong"},
                        )
                self.assertEqual(response.status_code, 401)
                self.assertNotIn(_TOKEN, output.getvalue())


if __name__ == "__main__":
    unittest.main()
