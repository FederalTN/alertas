"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
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
const express_1 = __importDefault(require("express"));
const multer_1 = __importDefault(require("multer"));
const path_1 = __importDefault(require("path"));
const fs_1 = __importDefault(require("fs"));
const dotenv_1 = __importDefault(require("dotenv"));
dotenv_1.default.config();
const app = (0, express_1.default)();
const PORT = Number(process.env.PORT) || 4000;
// ---------- Storage configuration ----------
const UPLOAD_DIR = process.env.UPLOAD_DIR || path_1.default.join(__dirname, 'uploads');
if (!fs_1.default.existsSync(UPLOAD_DIR)) {
    fs_1.default.mkdirSync(UPLOAD_DIR, { recursive: true });
}
const storage = multer_1.default.diskStorage({
    destination: (_req, _file, cb) => cb(null, UPLOAD_DIR),
    filename: (_req, file, cb) => {
        const timestamp = Date.now();
        const slug = path_1.default.parse(file.originalname).name.replace(/\s+/g, '_');
        cb(null, `${slug}_${timestamp}${path_1.default.extname(file.originalname).toLowerCase()}`);
    },
});
// Only accept .wav files
const fileFilter = (_req, file, cb) => {
    if (path_1.default.extname(file.originalname).toLowerCase() !== '.wav') {
        cb(new Error('Only .wav files are allowed'));
    }
    else {
        cb(null, true);
    }
};
// Limit ~50 MB (≈ 5 min WAV @ 44.1 kHz/16 bit)
const upload = (0, multer_1.default)({
    storage,
    limits: { fileSize: 50 * 1024 * 1024 },
    fileFilter,
});
// ---------- Routes ----------
// Health‐check
app.get('/health', (_req, res) => {
    res.json({ status: 'ok' });
});
// Audio upload endpoint – field name must be `audio`
app.post('/api/audio', upload.single('audio'), (req, res) => {
    if (!req.file) {
        res.status(400).json({ ok: false, message: 'No file provided' });
        return;
    }
    res.json({
        ok: true,
        filename: req.file.filename,
        size: req.file.size,
        path: req.file.path,
    });
});
// ---------- Global error handler ----------
const errorHandler = (err, _req, res, _next) => {
    if (err) {
        res.status(err instanceof multer_1.default.MulterError ? 400 : 500).json({ ok: false, message: err.message });
    }
};
app.use(errorHandler);
// ---------- Start server ----------
app.listen(PORT, () => {
    console.log(`🚀  Server listening on port ${PORT}`);
});
