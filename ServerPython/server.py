# server.py
import os
import csv
import re
import json
import time
import uuid
import pathlib
import asyncio
from datetime import datetime, timezone
from typing import Optional, Dict, Set, List

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv

load_dotenv()

# -------------------- Config --------------------
BASE_DIR = pathlib.Path(__file__).resolve().parent
PORT = int(os.getenv("PORT", "4000"))
HOST = os.getenv("HOST", "0.0.0.0")

UPLOAD_DIR = pathlib.Path(os.getenv("UPLOAD_DIR", BASE_DIR / "audios"))
CSV_PATH = pathlib.Path(os.getenv("CSV_PATH", BASE_DIR / "registros.csv"))
MAX_BYTES = int(os.getenv("MAX_BYTES", str(50 * 1024 * 1024)))  # 50 MB

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

CSV_HEADERS = [
    "timestamp",
    "deviceName",
    "latitude",
    "longitude",
    "originalname",
    "filename",
    "size",
    "mimetype",
    "path",
    "client_ip",
]

def ensure_csv():
    if not CSV_PATH.exists():
        with open(CSV_PATH, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADERS)
            writer.writeheader()

ensure_csv()

def slugify(name: str) -> str:
    base = pathlib.Path(name).stem
    base = base.strip().lower()
    base = re.sub(r"\s+", "_", base)
    base = re.sub(r"[^a-z0-9_\-]+", "", base)
    return base or "audio"

def iso_now() -> str:
    return datetime.now(tz=timezone.utc).isoformat()

def norm_device(name: str) -> str:
    return (name or "").strip().lower()

# -------------------- App --------------------
app = FastAPI(title="Audio Uploader (FastAPI)", version="2.0.0")

# CORS abierto para pruebas (ajusta en producción)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Servir los audios subidos:  GET http://<host>:<port>/audios/<filename>
app.mount("/audios", StaticFiles(directory=str(UPLOAD_DIR)), name="audios")

@app.get("/health")
def health():
    return {"status": "ok", "time": iso_now()}

# -------------------- Estado en memoria (WS) --------------------
class Client:
    def __init__(self, user_id: str, ws: WebSocket):
        self.user_id = user_id
        self.ws = ws
        self.subs: Set[str] = set()  # deviceName normalizados
        self.last_seen: float = time.time()

clients: Dict[str, Client] = {}
device_subs: Dict[str, Set[str]] = {}  # device -> set(user_id)
CLIENT_TIMEOUT_SEC = 30

def _add_sub(user_id: str, device: str):
    s = device_subs.get(device)
    if not s:
        s = set()
        device_subs[device] = s
    s.add(user_id)

def _remove_sub(user_id: str, device: str):
    s = device_subs.get(device)
    if s:
        s.discard(user_id)
        if not s:
            device_subs.pop(device, None)

async def _safe_send_json(ws: WebSocket, payload: dict):
    try:
        await ws.send_json(payload)
        return True
    except Exception:
        return False

async def _broadcast_new_audio(row: dict):
    """Notifica a los clientes suscritos a row['deviceName']."""
    device = norm_device(row.get("deviceName", ""))
    if not device:
        return
    user_ids = list(device_subs.get(device, set()))
    if not user_ids:
        return

    event = {
        "type": "new_audio",
        "deviceName": row["deviceName"],
        "timestamp": row["timestamp"],
        "filename": row["filename"],
        "size": row["size"],
        "urlPath": f"/audios/{row['filename']}",
        # NUEVO:
        "latitude": row.get("latitude", ""),
        "longitude": row.get("longitude", ""),
    }

    drops: List[str] = []
    for uid in user_ids:
        c = clients.get(uid)
        if not c:
            drops.append(uid)
            continue
        ok = await _safe_send_json(c.ws, event)
        if not ok:
            drops.append(uid)

    # Limpia subs de clientes que fallaron al enviar
    for uid in drops:
        for dev in list(device_subs.keys()):
            _remove_sub(uid, dev)
        clients.pop(uid, None)

async def _gc_loop():
    """Cierra y limpia clientes inactivos (>30s sin ping)."""
    while True:
        await asyncio.sleep(5)
        now = time.time()
        to_close: List[str] = []
        for uid, c in list(clients.items()):
            if (now - c.last_seen) > CLIENT_TIMEOUT_SEC:
                to_close.append(uid)
        for uid in to_close:
            c = clients.pop(uid, None)
            if c:
                try:
                    await c.ws.close()
                except Exception:
                    pass
            # borra suscripciones
            for dev in list(device_subs.keys()):
                _remove_sub(uid, dev)

@app.on_event("startup")
async def _on_startup():
    asyncio.create_task(_gc_loop())

# -------------------- WebSocket --------------------
@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    user_id = str(uuid.uuid4())
    client = Client(user_id, ws)
    clients[user_id] = client
    await _safe_send_json(ws, {"type": "welcome", "userId": user_id, "ts": iso_now()})

    try:
        while True:
            msg = await ws.receive_text()
            client.last_seen = time.time()
            try:
                data = json.loads(msg)
            except Exception:
                await _safe_send_json(ws, {"type": "error", "message": "JSON inválido"})
                continue

            action = (data.get("action") or "").lower()

            if action == "subscribe":
                names = data.get("deviceNames") or []
                names = [norm_device(n) for n in names if n and n.strip()]
                # quita las que ya no están
                for dev in list(client.subs):
                    if dev not in names:
                        _remove_sub(user_id, dev)
                        client.subs.discard(dev)
                # añade nuevas
                for dev in names:
                    if dev not in client.subs:
                        _add_sub(user_id, dev)
                        client.subs.add(dev)
                await _safe_send_json(ws, {"type": "subscribed", "deviceNames": sorted(list(client.subs))})

            elif action == "ping":
                await _safe_send_json(ws, {"type": "pong", "ts": iso_now()})

            elif action == "unsubscribe":
                names = data.get("deviceNames") or []
                names = [norm_device(n) for n in names if n and n.strip()]
                for dev in names:
                    _remove_sub(user_id, dev)
                    client.subs.discard(dev)
                await _safe_send_json(ws, {"type": "subscribed", "deviceNames": sorted(list(client.subs))})

            else:
                await _safe_send_json(ws, {"type": "error", "message": f"Acción no soportada: {action}"})

    except WebSocketDisconnect:
        pass
    finally:
        # limpieza
        for dev in list(client.subs):
            _remove_sub(user_id, dev)
        clients.pop(user_id, None)

# -------------------- HTTP: listar históricos --------------------
@app.get("/api/audios")
def list_audios(deviceName: str, limit: int = 50):
    """Devuelve historial (más recientes primero) para un deviceName."""
    d = norm_device(deviceName)
    if not d:
        raise HTTPException(status_code=400, detail="deviceName requerido")

    rows: List[dict] = []
    try:
        with open(CSV_PATH, "r", newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                if norm_device(row.get("deviceName", "")) == d:
                    rows.append(row)
    except FileNotFoundError:
        rows = []

    # ordena por timestamp desc
    rows.sort(key=lambda r: r.get("timestamp", ""), reverse=True)
    rows = rows[: max(1, min(limit, 500))]

    # mapea respuesta (ligera)
    return [
        {
            "timestamp": r["timestamp"],
            "deviceName": r["deviceName"],
            "filename": r["filename"],
            "size": int(r.get("size", "0") or 0),
            "urlPath": f"/audios/{r['filename']}",
            # NUEVO:
            "latitude": r.get("latitude", ""),
            "longitude": r.get("longitude", ""),
        }
        for r in rows
    ]


# -------------------- Upload de audio (ya lo tenías) --------------------
@app.post("/api/audio")
async def upload_audio(
    request: Request,
    audio: UploadFile = File(..., description="Archivo WAV (campo: audio)"),
    deviceName: str = Form(...),
    latitude: Optional[str] = Form(None),
    longitude: Optional[str] = Form(None),
):
    originalname = audio.filename or "audio.wav"
    ext = pathlib.Path(originalname).suffix.lower()
    if ext != ".wav":
        raise HTTPException(status_code=400, detail="Only .wav files are allowed")

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"{slugify(originalname)}_{ts}.wav"
    dest_path = UPLOAD_DIR / filename

    total = 0
    CHUNK = 1024 * 1024
    try:
        with open(dest_path, "wb") as out:
            while True:
                chunk = await audio.read(CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    out.close()
                    dest_path.unlink(missing_ok=True)
                    raise HTTPException(status_code=413, detail=f"File too large (> {MAX_BYTES} bytes)")
                out.write(chunk)
    except HTTPException:
        raise
    except Exception as e:
        dest_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"Error saving file: {e}")

    client_ip = request.client.host if request.client else ""
    row = {
        "timestamp": iso_now(),
        "deviceName": deviceName,
        "latitude": latitude or "",
        "longitude": longitude or "",
        "originalname": originalname,
        "filename": filename,
        "size": str(total),
        "mimetype": audio.content_type or "",
        "path": str(dest_path),
        "client_ip": client_ip,
    }

    # Append al CSV
    try:
        with open(CSV_PATH, "a", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=CSV_HEADERS)
            writer.writerow(row)
    except Exception as e:
        # seguimos, pero avisamos
        res = {
            "ok": True,
            "warning": f"No se pudo escribir en el CSV: {e}",
            "filename": filename,
            "size": total,
            "path": str(dest_path),
        }
        # Notifica igualmente
        asyncio.create_task(_broadcast_new_audio(row))
        return JSONResponse(status_code=201, content=res)

    # Notifica a suscriptores de ese device
    asyncio.create_task(_broadcast_new_audio(row))

    return {
        "ok": True,
        "filename": filename,
        "size": total,
        "path": str(dest_path),
    }

# -------------------- Arranque por comando --------------------
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host=HOST, port=PORT, reload=True)
