import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:geolocator/geolocator.dart';

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

  @override
  void dispose() {
    _cantidadCtrl.dispose();
    _urlCtrl.dispose();
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
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
                  hintText: 'http://localhost:4000/api/audio',
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
                  hintText: 'Ej: SensorPatio01',
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
                    final cantidad = int.parse(_cantidadCtrl.text);
                    final url = _urlCtrl.text.trim();
                    final deviceName = _deviceNameCtrl.text.trim();
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MonitorPage(
                        cantidad: cantidad,
                        endpointUrl: url,
                        deviceName: deviceName,
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
  });

  final int cantidad;
  final String endpointUrl;
  final String deviceName;

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

  /// Obtiene la posición actual (si hay permisos y servicios activos).
  /// Devuelve null si no se puede.
  Future<Position?> _getPositionSafe() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      print('[GEO] serviceEnabled=$serviceEnabled');
      if (!serviceEnabled) {
        print('[GEO] Servicios de ubicación desactivados');
        return null;
      }
      var permission = await Geolocator.checkPermission();
      print('[GEO] initialPermission=$permission');
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        print('[GEO] Permiso de ubicación denegado');
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      print('[GEO] Posición: ${pos.latitude}, ${pos.longitude}');
      return pos;
    } catch (e) {
      print('[GEO][ERROR] $e');
      return null;
    }
  }

  Future<void> _iniciar() async {
    if (_iniciado) return;
    _iniciado = true;

    final ok = await _recorder.hasPermission();
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permiso de micrófono denegado')),
      );
      Navigator.of(context).pop();
      return;
    }

    for (var i = 0; i < widget.cantidad && !_cancelado; i++) {
      final path = await _nuevoPathWav(i);

      final item = AudioItem(
        index: i,
        fileName: path.split('/').last,
        startedAt: DateTime.now(),
        status: UploadStatus.grabando,
      );
      setState(() => _items.insert(0, item));

      final cfg = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 44100,
        numChannels: 1,
      );

      await _recorder.start(cfg, path: path);

      const dur = Duration(minutes: 5);
      for (var s = 0; s < dur.inSeconds; s++) {
        if (_cancelado) break;
        await Future.delayed(const Duration(seconds: 1));
      }
      if (_cancelado) break;

      final finalPath = await _recorder.stop();
      final realPath = finalPath ?? path;

      setState(() {
        final idx = _items.indexWhere((e) => e.index == item.index);
        if (idx != -1) {
          _items[idx].finishedAt = DateTime.now();
          _items[idx].status = UploadStatus.enviando;
        }
      });

      _hechos++;
      unawaited(_subirArchivo(realPath, item.index));
    }

    if (mounted && !_cancelado) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Monitoreo finalizado ($_hechos/${widget.cantidad})')),
      );
    }
  }

  Future<void> _subirArchivo(String filePath, int itemIndex) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) throw 'Archivo no encontrado';

      final len = await file.length();
      if (len == 0) throw 'Archivo vacío (0 bytes)';

      // Intentamos obtener coordenadas justo antes de subir
      final pos = await _getPositionSafe();

      final uri = Uri.parse(widget.endpointUrl);
      print('[UPLOAD] → $uri');
      print('[UPLOAD] Archivo: ${file.path} (${len} bytes)');

      final req = http.MultipartRequest('POST', uri);

      // Campos extra
      req.fields['deviceName'] = widget.deviceName;
      if (pos != null) {
        req.fields['latitude'] = pos.latitude.toString();
        req.fields['longitude'] = pos.longitude.toString();
      }

      // Archivo
      req.files.add(
        await http.MultipartFile.fromPath(
          'audio', // clave en minúsculas
          file.path,
          contentType: MediaType('audio', 'wav'),
          filename: file.uri.pathSegments.last,
        ),
      );

      final resp = await req.send();
      final body = await resp.stream.bytesToString();
      print('[UPLOAD] Status: ${resp.statusCode}');
      print('[UPLOAD] Body: $body');

      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((e) => e.index == itemIndex);
        if (idx != -1) {
          _items[idx].status =
              (resp.statusCode >= 200 && resp.statusCode < 300)
                  ? UploadStatus.enviado
                  : UploadStatus.fallo;
          if (resp.statusCode < 200 || resp.statusCode >= 300) {
            _items[idx].error = 'HTTP ${resp.statusCode}';
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final idx = _items.indexWhere((e) => e.index == itemIndex);
        if (idx != -1) {
          _items[idx].status = UploadStatus.fallo;
          _items[idx].error = e.toString();
        }
      });
      print('[UPLOAD][ERROR] $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final restantes = widget.cantidad - _hechos;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitoreo'),
        actions: [
          TextButton.icon(
            onPressed: () {
              _cancelado = true;
              _recorder.cancel();
              if (mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Detener', style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Grabando segmentos WAV de 5 min\nEnvío: POST → audio + deviceName + lat/long',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  label: Text('Restantes: $restantes'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              itemBuilder: (_, i) {
                final a = _items[i];
                return ListTile(
                  leading: Icon(
                    a.status == UploadStatus.grabando
                        ? Icons.mic
                        : a.status == UploadStatus.enviando
                            ? Icons.cloud_upload_outlined
                            : a.status == UploadStatus.enviado
                                ? Icons.check_circle
                                : Icons.error_outline,
                  ),
                  title: Text(a.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    a.status == UploadStatus.grabando
                        ? 'Grabando...'
                        : a.status == UploadStatus.enviando
                            ? 'Enviando...'
                            : a.status == UploadStatus.enviado
                                ? 'Enviado'
                                : 'Falló${a.error != null ? ': ${a.error}' : ''}',
                  ),
                  trailing: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Inicio: ${_fmt(a.startedAt)}'),
                      if (a.finishedAt != null) Text('Fin: ${_fmt(a.finishedAt!)}'),
                    ],
                  ),
                );
              },
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemCount: _items.length,
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime d) {
    final two = (int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
