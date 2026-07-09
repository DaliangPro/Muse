#!/usr/bin/env python3
"""SenseVoice streaming ASR WebSocket server for Muse."""

import argparse
import asyncio
import json
import struct
import sys
import socket
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from sensevoice_model import load_model, StreamingSenseVoice

app = FastAPI()


@app.middleware("http")
async def _reject_non_local(request: Request, call_next):
    # REPAIR_PLAN J6：本服务仅供本机 Muse 进程调用（URLSession 不带 Origin 头）。
    # 浏览器跨站请求必带 Origin、DNS-rebinding 的 Host 非回环域——两类一律 403，
    # 防恶意网页/本机第三方经 localhost 白嫖本地推理。
    if request.headers.get("origin") is not None:
        return JSONResponse({"error": "cross-origin request rejected"}, status_code=403)
    host = (request.headers.get("host") or "").split(":")[0]
    if host not in ("127.0.0.1", "localhost"):
        return JSONResponse({"error": "invalid host"}, status_code=403)
    return await call_next(request)


# Global model (loaded once at startup)
_model: StreamingSenseVoice | None = None

# REPAIR_PLAN B3: 全局单模型不支持并发会话——同一时刻只服务一个 WebSocket，
# 否则新连接的 model.reset() 会清掉进行中会话的流式状态
_session_busy = False


def get_model():
    assert _model is not None, "Model not loaded"
    return _model


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    # REPAIR_PLAN J6：浏览器发起的 WebSocket 必带 Origin——accept 前拒绝（403 握手失败），
    # 仅服务本机进程（HTTP middleware 不覆盖 WS，需单独设防）
    if ws.headers.get("origin") is not None:
        await ws.close(code=4003, reason="cross-origin rejected")
        return
    global _session_busy
    await ws.accept()
    if _session_busy:
        # REPAIR_PLAN B3: 已有活跃会话，明确拒绝而不是互相破坏状态
        await ws.close(code=4001, reason="another session is active")
        return
    _session_busy = True
    try:
        model = get_model()
        # Reset model state for new session
        model.reset()
    except Exception as e:
        # 初始化失败必须释放占用位，否则后续连接全被误拒
        _session_busy = False
        print(f"[sensevoice] session init error: {e}", flush=True)
        await ws.close(code=1011, reason="model not ready")
        return

    # Accumulate all audio for final full inference
    all_samples: list[int] = []
    # REPAIR_PLAN J10：final 缓冲 30 分钟封顶（对齐 Swift 侧 B8/J10）。超限即清空并
    # 停止累积——流式结果已实时下发，final 走下方流式兜尾分支，不做半截全量推理
    # （半截 final 会覆盖完整的流式文本，比不做更糟）。
    max_total_samples = 30 * 60 * 16000
    total_overflowed = False

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # Empty frame = end of audio signal
                # Full inference on complete audio for best accuracy
                if all_samples:
                    final_text = model.full_inference(all_samples)
                    if final_text:
                        await ws.send_json({
                            "type": "transcript",
                            "text": final_text,
                            "is_final": True,
                        })
                else:
                    for result in model.streaming_inference([], is_last=True):
                        await ws.send_json({
                            "type": "transcript",
                            "text": result.get("text", ""),
                            "is_final": True,
                        })
                await ws.send_json({"type": "completed"})
                break

            # Convert PCM16 little-endian bytes to int16-range float list
            sample_count = len(data) // 2
            samples = list(struct.unpack(f"<{sample_count}h", data))
            # REPAIR_PLAN J10：超上限清空并停止累积，final 走流式兜尾
            if not total_overflowed:
                if len(all_samples) + sample_count > max_total_samples:
                    total_overflowed = True
                    all_samples.clear()
                    print("[sensevoice] audio buffer over limit; "
                          "final full inference disabled for this session", flush=True)
                else:
                    all_samples.extend(samples)

            # Run streaming inference (fast partial results)
            for result in model.streaming_inference(samples, is_last=False):
                text = result.get("text", "")
                if text:
                    await ws.send_json({
                        "type": "transcript",
                        "text": text,
                        "is_final": False,
                    })

    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"[sensevoice] session error: {e}", flush=True)
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        _session_busy = False


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model is not None, "llm_loaded": _llm is not None}


# --- LLM (Qwen3 via llama.cpp) ---

_llm = None
_llm_lock = asyncio.Lock()


def _load_llm(model_path: str):
    """Load LLM model lazily on first request."""
    global _llm
    if _llm is not None:
        return _llm
    from llama_cpp import Llama
    print(f"Loading LLM from {model_path}...", flush=True)
    _llm = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=-1,  # Use Metal (all layers on GPU)
        verbose=False,
    )
    print("LLM loaded.", flush=True)
    return _llm


@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions endpoint."""
    if _llm is None and not _llm_model_path:
        return JSONResponse({"error": "LLM not configured"}, status_code=503)

    messages = request.get("messages", [])
    temperature = request.get("temperature", 0.7)
    max_tokens = request.get("max_tokens", 1024)

    # Lazy load LLM on first request
    async with _llm_lock:
        llm = await asyncio.get_event_loop().run_in_executor(
            None, _load_llm, _llm_model_path
        )

    # Disable Qwen3 thinking mode for faster direct responses
    if messages and messages[-1].get("role") == "user":
        content = messages[-1]["content"]
        if not content.startswith("/no_think"):
            messages = messages.copy()
            messages[-1] = {**messages[-1], "content": f"/no_think\n{content}"}

    # Run inference in thread pool to not block event loop
    def _generate():
        result = llm.create_chat_completion(
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        # Strip any remaining <think>...</think> tags from response
        if result.get("choices"):
            text = result["choices"][0]["message"]["content"]
            import re
            text = re.sub(r'<think>.*?</think>\s*', '', text, flags=re.DOTALL).strip()
            result["choices"][0]["message"]["content"] = text
        return result

    result = await asyncio.get_event_loop().run_in_executor(None, _generate)
    return result


_llm_model_path = ""


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description="SenseVoice ASR Server")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--hotwords-file", default="")
    parser.add_argument("--beam-size", type=int, default=3)
    parser.add_argument("--context-score", type=float, default=6.0)
    parser.add_argument("--device", default="auto", help="auto, cpu, or mps")
    parser.add_argument("--language", default="auto", help="auto, zh, en, ja, ko, yue")
    parser.add_argument("--textnorm", action="store_true", default=True, help="Enable ITN (punctuation + number formatting)")
    parser.add_argument("--no-textnorm", dest="textnorm", action="store_false")
    parser.add_argument("--padding", type=int, default=8, help="Encoder context padding frames (higher = more accurate, slower)")
    parser.add_argument("--chunk-size", type=int, default=10, help="Encoder chunk size in LFR frames (~60ms each)")
    parser.add_argument("--llm-model", default="", help="Path to GGUF LLM model for local chat completions")
    args = parser.parse_args()

    global _model

    # Load hotwords from file
    # Each line is a hotword phrase. Multi-word English phrases are split into
    # individual words to avoid BPE space-prefix issues (e.g. "▁coding" not in vocab).
    # Chinese phrases are kept as-is since each character is already a token.
    hotwords = None
    if args.hotwords_file and Path(args.hotwords_file).exists():
        raw_lines = Path(args.hotwords_file).read_text().strip().splitlines()
        hotwords = []
        for line in raw_lines:
            line = line.strip()
            if not line:
                continue
            # Split on spaces: "Vibe coding" → ["Vibe", "coding"]
            # Chinese "语音识别" has no spaces, stays as one entry
            words = line.split()
            hotwords.extend(words)
        # Deduplicate while preserving order
        seen = set()
        hotwords = [w for w in hotwords if w not in seen and not seen.add(w)]
        if hotwords:
            print(f"Loaded {len(hotwords)} hotwords", flush=True)

    # Load model
    print(f"Loading model from {args.model_dir}...", flush=True)
    _model = load_model(
        model_dir=args.model_dir,
        contexts=hotwords,
        beam_size=args.beam_size,
        context_score=args.context_score,
        device=args.device,
        language=args.language,
        textnorm=args.textnorm,
        padding=args.padding,
        chunk_size=args.chunk_size,
    )
    print("Model loaded.", flush=True)

    # Configure LLM (lazy-loaded on first request)
    global _llm_model_path
    if args.llm_model and Path(args.llm_model).exists():
        _llm_model_path = args.llm_model
        print(f"LLM configured: {args.llm_model} (lazy load on first request)", flush=True)

    # Find port
    port = args.port if args.port != 0 else find_free_port()

    # Print PORT line so Swift process can discover it
    print(f"PORT:{port}", flush=True)

    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
