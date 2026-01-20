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

  // Android Emulator -> localhost PC
  final _urlCtrl =
      TextEditingController(text: 'http://10.0.2.2:4000/api/audio');

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
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return 'La URL es requerida';
                  final uri = Uri.tryParse(s);
                  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                    return 'Ingresa una URL válida (ej: http://host:puerto/ruta)';
                  }
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
    required this.filePath,
    required this.startedAt,
    required this.totalSeconds,
    this.progressSeconds = 0,
    this.finishedAt,
    this.status = UploadStatus.grabando,
    this.error,
    this.latitude,
    this.longitude,
  });

  final int index;
  final String fileName;
  final String filePath;
  final DateTime startedAt;
  DateTime? finishedAt;
  UploadStatus status;
  String? error;

  int progressSeconds;
  final int totalSeconds;

  String? latitude;
  String? longitude;
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

  /// Asegura permisos de ubicación y obtiene posición (best effort).
  /// Si no hay permisos o falla, devuelve null.
  Future<Position?> _getPositionBestEffort() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      // Intenta una posición con precisión razonable
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
    } catch (_) {
      return null;
    }
  }

  /// Envia multipart/form-data como tu FastAPI espera:
  /// - file field: "audio"
  /// - form field requerido: "deviceName"
  /// - opcionales: "latitude", "longitude"
  Future<void> _subirAudio({
    required Uri endpoint,
    required String filePath,
    required String deviceName,
    String? latitude,
    String? longitude,
  }) async {
    final req = http.MultipartRequest('POST', endpoint);

    req.fields['deviceName'] = deviceName;
    if (latitude != null && latitude.trim().isNotEmpty) {
      req.fields['latitude'] = latitude.trim();
    }
    if (longitude != null && longitude.trim().isNotEmpty) {
      req.fields['longitude'] = longitude.trim();
    }

    req.files.add(
      await http.MultipartFile.fromPath(
        'audio', // <- CLAVE: tu server.py espera "audio"
        filePath,
        contentType: MediaType('audio', 'wav'),
      ),
    );

    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw Exception('HTTP ${streamed.statusCode}: $body');
    }
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

    final endpoint = Uri.parse(widget.endpointUrl);

    for (var i = 0; i < widget.cantidad && !_cancelado; i++) {
      final path = await _nuevoPathWav(i);
      final totalSec = widget.chunkSeconds.round();

      final item = AudioItem(
        index: i,
        fileName: path.split('/').last,
        filePath: path,
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
            item.progressSeconds = (sec + 1).clamp(0, item.totalSeconds);
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

      // Obtener ubicación (best effort)
      final pos = await _getPositionBestEffort();
      final lat = pos?.latitude.toString();
      final lon = pos?.longitude.toString();

      if (!mounted) return;
      setState(() {
        item.latitude = lat;
        item.longitude = lon;
      });

      // SUBIR
      try {
        await _subirAudio(
          endpoint: endpoint,
          filePath: item.filePath,
          deviceName: widget.deviceName,
          latitude: lat,
          longitude: lon,
        );

        if (!mounted) return;
        setState(() => item.status = UploadStatus.enviado);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          item.status = UploadStatus.fallo;
          item.error = e.toString();
        });
      }
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

          final subtitle = switch (a.status) {
            UploadStatus.grabando =>
              'Grabando... (${a.progressSeconds}/${a.totalSeconds})',
            UploadStatus.enviando => 'Enviando...',
            UploadStatus.enviado =>
              'Enviado (${a.latitude ?? "-"}, ${a.longitude ?? "-"})',
            UploadStatus.fallo => 'Falló: ${a.error ?? "desconocido"}',
          };

          return ListTile(
            leading: Icon(
              a.status == UploadStatus.grabando
                  ? Icons.mic
                  : a.status == UploadStatus.enviado
                      ? Icons.check_circle_outline
                      : a.status == UploadStatus.fallo
                          ? Icons.error_outline
                          : Icons.cloud_upload_outlined,
            ),
            title: Text(a.fileName),
            subtitle: Text(subtitle),
          );
        },
      ),
    );
  }
}
