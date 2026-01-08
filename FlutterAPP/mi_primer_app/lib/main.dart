import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() {
  runApp(const AudioMonitorApp());
}

class AudioMonitorApp extends StatelessWidget {
  const AudioMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitor de Audios',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const SetupPage(),
    );
  }
}

/// Lee chunk_seconds desde assets/config.json
Future<double> loadChunkSeconds() async {
  final raw = await rootBundle.loadString('assets/config.json');
  final jsonMap = json.decode(raw) as Map<String, dynamic>;
  final v = jsonMap['chunk_seconds'];
  if (v is num) return v.toDouble();
  throw Exception('config.json: chunk_seconds no válido');
}

/// ---------------------------
/// PANTALLA 1: Configuración
/// ---------------------------
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _cantidadCtrl = TextEditingController(text: '3');
  final _urlCtrl = TextEditingController(text: 'http://localhost:4000/api/audio');
  final _deviceNameCtrl = TextEditingController(text: 'MiDispositivo');

  double? _chunkSeconds;
  String? _configError;

  @override
  void initState() {
    super.initState();
    loadChunkSeconds().then((v) {
      if (!mounted) return;
      setState(() => _chunkSeconds = v);
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _configError = e.toString());
    });
  }

  @override
  void dispose() {
    _cantidadCtrl.dispose();
    _urlCtrl.dispose();
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chunkLabel = _configError != null
        ? 'chunk_seconds: error (${_configError!})'
        : (_chunkSeconds == null
            ? 'Leyendo config.json...'
            : 'chunk_seconds: $_chunkSeconds s');

    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              Text(chunkLabel),
              const SizedBox(height: 16),
              TextFormField(
                controller: _cantidadCtrl,
                decoration: const InputDecoration(
                  labelText: 'Cantidad de audios a grabar',
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  if (n == null || n <= 0) return 'Ingresa un número mayor a 0';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL de destino (POST)',
                ),
                validator: (v) {
                  if (v == null || v.isEmpty) return 'La URL es requerida';
                  final ok = Uri.tryParse(v)?.hasAbsolutePath ?? false;
                  if (!ok) return 'Ingresa una URL válida';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _deviceNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Device Name',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Ingresa un nombre de dispositivo';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.mic),
                label: const Text('Comenzar a monitorear'),
                onPressed: () {
                  if (_formKey.currentState?.validate() ?? false) {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MonitorPage(
                        cantidad: int.parse(_cantidadCtrl.text),
                        endpointUrl: _urlCtrl.text.trim(),
                        deviceName: _deviceNameCtrl.text.trim(),
                        chunkSeconds: _chunkSeconds ?? 300.0,
                      ),
                    ));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// ---------------------------------
/// Modelo simple para la lista UI
/// ---------------------------------
enum UploadStatus { grabando, enviando, enviado, fallo }

class AudioItem {
  AudioItem({
    required this.index,
    required this.fileName,
    required this.startedAt,
    required this.totalSeconds,
    this.progressSeconds = 0,
    this.finishedAt,
    this.status = UploadStatus.grabando,
    this.error,
  });

  final int index;
  final String fileName;
  final DateTime startedAt;
  DateTime? finishedAt;
  UploadStatus status;
  String? error;

  int progressSeconds;      // ✅ segundos actuales
  final int totalSeconds;   // ✅ segundos totales
}

/// ---------------------------
/// PANTALLA 2: Monitoreo
/// ---------------------------
class MonitorPage extends StatefulWidget {
  const MonitorPage({
    super.key,
    required this.cantidad,
    required this.endpointUrl,
    required this.deviceName,
    required this.chunkSeconds,
  });

  final int cantidad;
  final String endpointUrl;
  final String deviceName;
  final double chunkSeconds;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  final _recorder = AudioRecorder();
  bool _cancelado = false;
  bool _iniciado = false;
  int _hechos = 0;
  final List<AudioItem> _items = [];

  @override
  void initState() {
    super.initState();
    _iniciar();
  }

  @override
  void dispose() {
    _cancelado = true;
    _recorder.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<Directory> _ensureAudioDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/audios');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<String> _nuevoPathWav(int idx) async {
    final dir = await _ensureAudioDir();
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return '${dir.path}/audio_${idx + 1}_$ts.wav';
  }

  Future<void> _iniciar() async {
    if (_iniciado) return;
    _iniciado = true;

    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permiso de micrófono denegado')),
      );
      Navigator.of(context).pop();
      return;
    }

    for (var i = 0; i < widget.cantidad && !_cancelado; i++) {
      final path = await _nuevoPathWav(i);
      final totalSec = widget.chunkSeconds.round();

      final item = AudioItem(
        index: i,
        fileName: path.split('/').last,
        startedAt: DateTime.now(),
        totalSeconds: totalSec,
      );

      setState(() => _items.insert(0, item));

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );

      final dur = Duration(milliseconds: (widget.chunkSeconds * 1000).round());
      int lastShownSec = -1;

      for (var ms = 0; ms < dur.inMilliseconds; ms += 200) {
        if (_cancelado) break;
        await Future.delayed(const Duration(milliseconds: 200));

        final sec = (ms / 1000).floor();
        if (sec != lastShownSec) {
          lastShownSec = sec;
          if (!mounted) break;
          setState(() {
            item.progressSeconds =
                (sec + 1).clamp(0, item.totalSeconds);
          });
        }
      }

      if (_cancelado) break;

      await _recorder.stop();

      setState(() {
        item.finishedAt = DateTime.now();
        item.status = UploadStatus.enviando;
        item.progressSeconds = item.totalSeconds;
      });

      _hechos++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Monitoreo')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(),
        itemBuilder: (_, i) {
          final a = _items[i];
          return ListTile(
            leading: Icon(
              a.status == UploadStatus.grabando
                  ? Icons.mic
                  : Icons.cloud_upload_outlined,
            ),
            title: Text(a.fileName),
            subtitle: Text(
              a.status == UploadStatus.grabando
                  ? 'Grabando... (${a.progressSeconds}/${a.totalSeconds})'
                  : 'Enviando...',
            ),
          );
        },
      ),
    );
  }
}
