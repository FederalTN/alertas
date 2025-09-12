// server.ts
// Simple Express API (TypeScript) to receive .wav audio files via POST /api/audio
// -----------------------------------------------------------------------------
// Setup:
//   1. Crear proyecto e instalar dependencias:
//      npm init -y
//      npm install express multer dotenv
//      npm install -D typescript ts-node @types/node @types/express @types/multer nodemon
//   2. Inicializar TypeScript:
//      npx tsc --init  # asegúrate de que "esModuleInterop": true esté habilitado en tsconfig.json
//   3. (Opcional) Añadir scripts en package.json:
//      "scripts": {
//        "dev": "nodemon --exec ts-node server.ts",
//        "build": "tsc",
//        "start": "node dist/server.js"
//      }
//
// Desarrollo:
//   npm run dev
//
// Build (producción):
//   npm run build
//   npm run start
// -----------------------------------------------------------------------------
import express, { Request, Response, NextFunction, ErrorRequestHandler } from 'express';
import multer, { FileFilterCallback } from 'multer';
import path from 'path';
import fs from 'fs';
import dotenv from 'dotenv';

dotenv.config();

const app = express();
const PORT: number = Number(process.env.PORT) || 4000;

// ---------- Storage configuration ----------
const UPLOAD_DIR: string = process.env.UPLOAD_DIR || path.join(__dirname, 'uploads');
if (!fs.existsSync(UPLOAD_DIR)) {
  fs.mkdirSync(UPLOAD_DIR, { recursive: true });
}

const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
  filename: (_req, file, cb) => {
    const timestamp = Date.now();
    const slug = path.parse(file.originalname).name.replace(/\s+/g, '_');
    cb(null, `${slug}_${timestamp}${path.extname(file.originalname).toLowerCase()}`);
  },
});

// Only accept .wav files
const fileFilter = (
  _req: Request,
  file: Express.Multer.File,
  cb: FileFilterCallback,
): void => {
  if (path.extname(file.originalname).toLowerCase() !== '.wav') {
    cb(new Error('Only .wav files are allowed'));
  } else {
    cb(null, true);
  }
};

// Limit ~50 MB (≈ 5 min WAV @ 44.1 kHz/16 bit)
const upload = multer({
  storage,
  limits: { fileSize: 50 * 1024 * 1024 },
  fileFilter,
});

// ---------- Routes ----------

// Health‐check
app.get('/health', (_req: Request, res: Response): void => {
  res.json({ status: 'ok' });
});

// Audio upload endpoint – field name must be `audio`
app.post(
  '/api/audio',
  upload.single('audio'),
  (req: Request, res: Response): void => {
    if (!req.file) {
      res.status(400).json({ ok: false, message: 'No file provided' });
      return;
    }

    console.log('Archivo recibido:', {
      originalname: req.file.originalname,
      filename: req.file.filename,
      size: req.file.size,
      mimetype: req.file.mimetype,
      path: req.file.path,
    });

    res.json({
      ok: true,
      filename: req.file.filename,
      size: req.file.size,
      path: req.file.path,
    });
  }
);

// ---------- Global error handler ----------
const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err) {
    res.status(err instanceof multer.MulterError ? 400 : 500).json({ ok: false, message: err.message });
  }
};
app.use(errorHandler);

// ---------- Start server ----------
app.listen(PORT, () => {
  console.log(`🚀  Server listening on port ${PORT}`);
});
