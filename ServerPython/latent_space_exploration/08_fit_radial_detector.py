#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
08_fit_radial_detector.py

Lee config.json (en el project root), recorre los .wav en:
  latent_space_exploration/test_chunks/<ESPECIE>/*.wav
Obtiene el vector latente (256D) por wav (usando el mismo pipeline validado)
y calcula por especie:
  - centroide (mean de z)
  - umbral radial rk (percentil q de ||z - mu||)

Guarda en config.json (in-place) en:
  config["radial_detector"]["centroids"]
  config["radial_detector"]["thresholds"]

Uso:
  cd ~/Desktop/VAE/modelos_VAE
  python3 latent_space_exploration/08_fit_radial_detector.py
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

import numpy as np
import torch

try:
    import librosa
except Exception as e:
    raise SystemExit(f"❌ Falta librosa. Instala con: pip install librosa\nDetalle: {e}")

try:
    from omegaconf import OmegaConf  # type: ignore
    from hydra.utils import instantiate  # type: ignore
except Exception:
    OmegaConf = None  # type: ignore
    instantiate = None  # type: ignore


# ----------------------------
# Paths / config helpers
# ----------------------------

def find_project_root(start: Path) -> Path:
    cur = start.resolve()
    for _ in range(12):
        if (cur / "downloaded_models").exists() and (cur / "latent_space_exploration").exists():
            return cur
        cur = cur.parent
    # fallback
    return start.resolve()


def load_json(path: Path) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        raise SystemExit("❌ config.json no es un objeto JSON (dict).")
    return obj


def save_json(path: Path, obj: Dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)


def resolve_chunks_dir(project_root: Path, cfg_path: Path, cfg: Dict[str, Any]) -> Path:
    """
    Prioridad:
    1) usar cfg["output_dir"] si existe y el path existe (relativo al config.json)
    2) fallback a project_root/latent_space_exploration/test_chunks
    """
    # 1) config output_dir
    out_dir = cfg.get("output_dir", None)
    if isinstance(out_dir, str) and out_dir.strip():
        cand = (cfg_path.parent / out_dir).resolve()
        if cand.exists() and cand.is_dir():
            return cand

    # 2) fallback (tu estructura real)
    return (project_root / "latent_space_exploration" / "test_chunks").resolve()


def resolve_default_encoder_pt(project_root: Path) -> Path:
    p = project_root / "downloaded_models" / "bird_net_vae_audio_splitted_encoder_v0" / "model.pt"
    if not p.exists():
        raise SystemExit(f"❌ No encontré encoder .pt en: {p}")
    return p


def resolve_default_encoder_yaml(project_root: Path) -> Path:
    p = project_root / "downloaded_models" / "bird_net_vae_audio_splitted_encoder_v0" / "bird_net_vae_audio_splitted.yaml"
    if not p.exists():
        raise SystemExit(f"❌ No encontré encoder YAML en: {p}")
    return p


# ----------------------------
# Encoder loading (Hydra)
# ----------------------------

def load_yaml_cfg(cfg_path: Path) -> Dict[str, Any]:
    if OmegaConf is None:
        raise SystemExit("❌ Falta omegaconf/hydra-core. Instala en tu env: pip install omegaconf hydra-core")
    cfg_obj = OmegaConf.load(str(cfg_path))  # type: ignore
    cfg = OmegaConf.to_container(cfg_obj, resolve=False)  # type: ignore
    if not isinstance(cfg, dict):
        raise SystemExit("❌ No pude convertir YAML a dict.")
    return cfg


def pick_encoder_cfg(cfg: Dict[str, Any]) -> Dict[str, Any]:
    if "encoder" in cfg and isinstance(cfg["encoder"], dict):
        enc = cfg["encoder"]
        if "_target_" not in enc:
            raise SystemExit("❌ El bloque encoder del YAML no tiene _target_.")
        return enc
    raise SystemExit("❌ El YAML no contiene un bloque 'encoder:'.")


def split_model_and_state(ckpt: Any):
    if isinstance(ckpt, torch.nn.Module):
        return ckpt, ckpt.state_dict()
    if isinstance(ckpt, dict):
        if "state_dict" in ckpt and isinstance(ckpt["state_dict"], dict):
            return None, ckpt["state_dict"]
        if ckpt and all(torch.is_tensor(v) for v in ckpt.values()):
            return None, ckpt
    return None, None


def build_nn_module(obj: Any) -> torch.nn.Module:
    """
    En soundscape_vae, el instantiate(enc_cfg) devuelve un factory callable (_BirdNet),
    hay que llamar obj() para obtener nn.Module real.
    """
    if isinstance(obj, torch.nn.Module):
        return obj
    if callable(obj):
        m = obj()
        if isinstance(m, torch.nn.Module):
            return m
        raise SystemExit(f"❌ Llamé factory() pero no devolvió nn.Module: {type(m)}")
    raise SystemExit(f"❌ No pude construir nn.Module desde: {type(obj)}")


def load_encoder(encoder_pt: Path, encoder_yaml: Path, project_root: Path, device: torch.device) -> torch.nn.Module:
    # Asegurar importabilidad del repo (por si soundscape_vae vive dentro del project_root)
    if str(project_root) not in sys.path:
        sys.path.insert(0, str(project_root))

    ckpt = torch.load(str(encoder_pt), map_location=str(device))
    model_or_none, state = split_model_and_state(ckpt)

    if model_or_none is not None:
        module = build_nn_module(model_or_none)
        return module.to(device).eval()

    if instantiate is None:
        raise SystemExit("❌ hydra-core no disponible (instantiate).")

    if state is None:
        raise SystemExit("❌ No encontré state_dict en el checkpoint.")

    cfg = load_yaml_cfg(encoder_yaml)
    enc_cfg = pick_encoder_cfg(cfg)

    factory = instantiate(enc_cfg)  # type: ignore
    module = build_nn_module(factory)

    module.load_state_dict(state, strict=False)
    return module.to(device).eval()


# ----------------------------
# Audio -> mel (pipeline validado)
# ----------------------------

def crop_or_pad_time(mel: np.ndarray, target_frames: int) -> np.ndarray:
    # mel: [M, T]
    _, T = mel.shape
    if T == target_frames:
        return mel
    if T > target_frames:
        start = (T - target_frames) // 2
        return mel[:, start:start + target_frames]
    pad_total = target_frames - T
    pad_left = pad_total // 2
    pad_right = pad_total - pad_left
    return np.pad(mel, ((0, 0), (pad_left, pad_right)), mode="constant")


def wav_to_mel(
    wav_path: Path,
    sr: int,
    duration: float,
    n_mels: int,
    fmin: float,
    fmax: float,
    hop_length: int,
    n_fft: int,
    target_frames: int,
) -> torch.Tensor:
    y, _ = librosa.load(str(wav_path), sr=sr, mono=True)

    # forzar duración fija
    if duration > 0:
        target_len = int(sr * duration)
        if y.shape[0] < target_len:
            y = np.pad(y, (0, target_len - y.shape[0]), mode="constant")
        else:
            y = y[:target_len]

    S = librosa.feature.melspectrogram(
        y=y,
        sr=sr,
        n_fft=n_fft,
        hop_length=hop_length,
        n_mels=n_mels,
        fmin=fmin,
        fmax=fmax,
        power=2.0,
    )
    S_db = librosa.power_to_db(S, ref=np.max)

    # standardize
    S_db = (S_db - S_db.mean()) / (S_db.std() + 1e-8)

    # forzar frames
    S_db = crop_or_pad_time(S_db, target_frames=target_frames)

    return torch.tensor(S_db, dtype=torch.float32)  # [M,T]


@torch.no_grad()
def encode_wav_to_latent(
    encoder: torch.nn.Module,
    wav_path: Path,
    device: torch.device,
    *,
    sr: int,
    duration: float,
    n_mels: int,
    fmin: float,
    fmax: float,
    hop_length: int,
    n_fft: int,
    target_frames: int,
) -> np.ndarray:
    mel = wav_to_mel(
        wav_path=wav_path,
        sr=sr,
        duration=duration,
        n_mels=n_mels,
        fmin=fmin,
        fmax=fmax,
        hop_length=hop_length,
        n_fft=n_fft,
        target_frames=target_frames,
    )

    # CLAVE: encoder espera [B,1,T,M]
    x = mel.T.unsqueeze(0).unsqueeze(0).to(device)

    out = encoder(x)

    # la salida puede ser tensor, tupla o dict; nos quedamos con el primer tensor útil
    if isinstance(out, torch.Tensor):
        t = out
    elif isinstance(out, (list, tuple)):
        t = next((z for z in out if isinstance(z, torch.Tensor)), None)
        if t is None:
            raise RuntimeError("Salida del encoder es tuple/list sin tensor.")
    elif isinstance(out, dict):
        t = None
        for k in ("z", "latent", "mu", "mean", "embedding"):
            if k in out and isinstance(out[k], torch.Tensor):
                t = out[k]
                break
        if t is None:
            t = next((v for v in out.values() if isinstance(v, torch.Tensor)), None)
        if t is None:
            raise RuntimeError("Salida del encoder es dict sin tensor.")
    else:
        raise RuntimeError(f"No sé interpretar salida del encoder: {type(out)}")

    # si viene [B,T,C] -> promediar en T
    if t.ndim == 3:
        t = t.mean(dim=1)

    # si viene con más dims, flatten
    if t.ndim > 2:
        t = t.view(t.shape[0], -1)

    z = t.detach().cpu().numpy()
    if z.shape[0] != 1:
        raise RuntimeError(f"Esperaba batch=1, obtuve: {z.shape}")
    return z[0].astype(np.float32)  # [D]


# ----------------------------
# Detector: centroid + threshold
# ----------------------------

def l2_norm_rows(x: np.ndarray) -> np.ndarray:
    return np.sqrt(np.sum(x * x, axis=1))


def fit_species(Z: np.ndarray, q: float) -> Tuple[np.ndarray, float]:
    """
    Z: [N, D]
    centroid: mean
    threshold: quantile_q( ||z - centroid|| )
    """
    mu = np.mean(Z, axis=0)
    rho = l2_norm_rows(Z - mu[None, :])
    rk = float(np.quantile(rho, q)) if len(rho) > 0 else 0.0
    return mu.astype(np.float32), rk


# ----------------------------
# CLI / Main
# ----------------------------

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--config", type=str, default="config.json", help="Ruta a config.json (por defecto en project root)")
    p.add_argument("--q", type=float, default=0.99, help="Percentil para el umbral radial (default 0.99)")
    p.add_argument("--device", type=str, default="cpu")

    # parámetros del encoder/audio (los que ya validamos)
    p.add_argument("--sr", type=int, default=48000)
    p.add_argument("--n-mels", type=int, default=64)
    p.add_argument("--target-frames", type=int, default=192)
    p.add_argument("--fmin", type=float, default=150.0)
    p.add_argument("--fmax", type=float, default=15000.0)
    p.add_argument("--hop-length", type=int, default=384)
    p.add_argument("--n-fft", type=int, default=2048)

    # permitir override del yaml si quisieras (pero no obligatorio)
    p.add_argument("--encoder-pt", type=str, default=None)
    p.add_argument("--encoder-yaml", type=str, default=None)

    return p.parse_args()


def main():
    args = parse_args()

    here = Path(__file__).resolve()
    project_root = find_project_root(here.parent)

    cfg_path = Path(args.config)
    if not cfg_path.is_absolute():
        cfg_path = (project_root / cfg_path).resolve()

    if not cfg_path.exists():
        raise SystemExit(f"❌ No existe config.json en: {cfg_path}")

    cfg = load_json(cfg_path)

    species_list = cfg.get("species", None)
    if not isinstance(species_list, list) or not all(isinstance(s, str) for s in species_list):
        raise SystemExit("❌ config.json debe tener un campo 'species' que sea lista de strings.")

    chunk_seconds = cfg.get("chunk_seconds", 5.0)
    try:
        chunk_seconds = float(chunk_seconds)
    except Exception:
        chunk_seconds = 5.0

    chunks_dir = resolve_chunks_dir(project_root, cfg_path, cfg)

    device = torch.device(args.device)

    encoder_pt = Path(args.encoder_pt).resolve() if args.encoder_pt else resolve_default_encoder_pt(project_root)
    encoder_yaml = Path(args.encoder_yaml).resolve() if args.encoder_yaml else resolve_default_encoder_yaml(project_root)

    print(f"📌 Project root: {project_root}")
    print(f"🧾 Config: {cfg_path}")
    print(f"📁 Chunks dir: {chunks_dir}")
    print(f"🧠 Encoder PT: {encoder_pt}")
    print(f"🧾 Encoder YAML: {encoder_yaml}")
    print(f"🖥️ Device: {device}")
    print(f"⏱️ chunk_seconds: {chunk_seconds}")
    print(f"🎯 q (percentil): {args.q}\n")

    encoder = load_encoder(encoder_pt, encoder_yaml, project_root, device)

    centroids: Dict[str, List[float]] = {}
    thresholds: Dict[str, float] = {}

    for sp in species_list:
        sp_dir = (chunks_dir / sp).resolve()
        wavs = sorted(sp_dir.glob("*.wav")) if sp_dir.exists() else []

        if len(wavs) == 0:
            print(f"⚠️ {sp}: no encontré wavs en {sp_dir} (se omite).")
            continue

        Z = []
        for wav in wavs:
            try:
                z = encode_wav_to_latent(
                    encoder=encoder,
                    wav_path=wav,
                    device=device,
                    sr=args.sr,
                    duration=chunk_seconds,
                    n_mels=args.n_mels,
                    fmin=args.fmin,
                    fmax=args.fmax,
                    hop_length=args.hop_length,
                    n_fft=args.n_fft,
                    target_frames=args.target_frames,
                )
                Z.append(z)
            except Exception as e:
                print(f"⚠️ {sp}: fallo {wav.name}: {e}")

        if len(Z) == 0:
            print(f"⚠️ {sp}: no pude codificar ningún wav (se omite).")
            continue

        Zm = np.stack(Z, axis=0)  # [N,D]
        mu, rk = fit_species(Zm, q=args.q)

        centroids[sp] = mu.tolist()
        thresholds[sp] = rk

        print(f"✅ {sp}: N={Zm.shape[0]}  centroid_dim={mu.shape[0]}  threshold_r={rk:.6f}")

    # escribir SOLO centroides y umbrales dentro de radial_detector
    cfg.setdefault("radial_detector", {})
    if not isinstance(cfg["radial_detector"], dict):
        cfg["radial_detector"] = {}

    cfg["radial_detector"]["centroids"] = centroids
    cfg["radial_detector"]["thresholds"] = thresholds

    # backup y escritura
    backup = cfg_path.with_suffix(cfg_path.suffix + ".bak")
    shutil.copy2(cfg_path, backup)
    save_json(cfg_path, cfg)

    print(f"\n💾 Guardado en config.json: {cfg_path}")
    print(f"🗂️ Backup: {backup}")


if __name__ == "__main__":
    main()
