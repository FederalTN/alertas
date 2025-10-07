import os
import csv
import re
import pathlib
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
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
    # quita extensión y normaliza
    base = pathlib.Path(name).stem
    base = base.strip().lower()
    base = re.sub(r"\s+", "_", base)
    base = re.sub(r"[^a-z0-9_\-]+", "", base)
    return base or "audio"

def iso_now() -> str:
    return datetime.now(tz=timezone.utc).isoformat()

# -------------------- App --------------------
app = FastAPI(title="Audio Uploader (FastAPI)", version="1.0.0")

# Abre CORS si lo necesitas (útil para pruebas desde emuladores/dispositivos)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # ajusta en producción
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/api/audio")
async def upload_audio(
    request: Request,
    audio: UploadFile = File(..., description="Archivo WAV (campo: audio)"),
    deviceName: str = Form(...),
    latitude: Optional[str] = Form(None),
    longitude: Optional[str] = Form(None),
):
    # --- Validaciones básicas ---
    originalname = audio.filename or "audio.wav"
    ext = pathlib.Path(originalname).suffix.lower()
    if ext != ".wav":
        raise HTTPException(status_code=400, detail="Only .wav files are allowed")

    # Nombre final
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"{slugify(originalname)}_{ts}.wav"
    dest_path = UPLOAD_DIR / filename

    # Guardado por chunks + límite de tamaño
    total = 0
    CHUNK = 1024 * 1024  # 1 MB
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
                    raise HTTPException(
                        status_code=413,
                        detail=f"File too large (> {MAX_BYTES} bytes)"
                    )
                out.write(chunk)
    except HTTPException:
        # re-lanza tal cual
        raise
    except Exception as e:
        dest_path.unlink(missing_ok=True)
        raise HTTPException(status_code=500, detail=f"Error saving file: {e}")

    # Info de respuesta/CSV
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
        # si falló el CSV no rompemos la subida, pero avisamos
        return JSONResponse(
            status_code=201,
            content={
                "ok": True,
                "warning": f"No se pudo escribir en el CSV: {e}",
                "filename": filename,
                "size": total,
                "path": str(dest_path),
            },
        )

    return {
        "ok": True,
        "filename": filename,
        "size": total,
        "path": str(dest_path),
    }

# -------------------- Arranque por comando --------------------
if __name__ == "__main__":
    # Permite: python server.py  (sin uvicorn en CLI)
    import uvicorn
    uvicorn.run("server:app", host=HOST, port=PORT, reload=True)
