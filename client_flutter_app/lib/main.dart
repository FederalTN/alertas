// lib/clientMain.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const ClientApp());
}

class ClientApp extends StatelessWidget {
  const ClientApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cliente Nodos (Audios)',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const ConnectScreen(),
    );
  }
}

/* =======================
   ====== ETAPA 1 ========
   ======================= */

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _serverCtrl = TextEditingController(text: 'http://10.0.2.2:4000');
  final _deviceCtrl = TextEditingController();
  bool _connecting = false;
  String? _userId;
  String? _error;
  final List<String> _devices = [];
  ClientConnection? _conn;

  void _addDevice() {
    final raw = _deviceCtrl.text.trim();
    if (raw.isEmpty) return;
    for (final d in raw.split(',')) {
      final dn = d.trim().toLowerCase();
      if (dn.isNotEmpty && !_devices.contains(dn)) {
        _devices.add(dn);
      }
    }
    _deviceCtrl.clear();
    setState(() {});
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });

    try {
      final conn = ClientConnection(_serverCtrl.text.trim());
      await conn.connect();
      setState(() {
        _conn = conn;
        _userId = conn.userId;
      });
    } catch (e) {
      setState(() => _error = 'No se pudo conectar: $e');
    } finally {
      setState(() => _connecting = false);
    }
  }

  Future<void> _continue() async {
    if (_conn == null) return;
    if (_devices.isEmpty) {
      setState(() => _error = 'Agrega al menos 1 deviceName.');
      return;
    }
    await _conn!.subscribe(_devices);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TimelineScreen(connection: _conn!, devices: List.of(_devices)),
    ));
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _userId != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Conexión y Suscripción')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _serverCtrl,
              decoration: const InputDecoration(
                labelText: 'URL del servidor (http://host:4000)',
                prefixIcon: Icon(Icons.cloud_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _deviceCtrl,
                    onSubmitted: (_) => _addDevice(),
                    decoration: const InputDecoration(
                      labelText: 'deviceName (coma para varios)',
                      prefixIcon: Icon(Icons.perm_device_information),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _addDevice,
                  child: const Text('Agregar'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: -8,
              children: _devices
                  .map((d) => Chip(
                        label: Text(d),
                        onDeleted: () {
                          _devices.remove(d);
                          setState(() {});
                        },
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            if (!connected)
              FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(_connecting ? 'Conectando...' : 'Conectar'),
              ),
            if (connected)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.verified_user, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text('userId: $_userId', style: const TextStyle(fontFamily: 'monospace'))),
                  ]),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _continue,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continuar a Historial'),
                  ),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ]
          ],
        ),
      ),
    );
  }
}

/* =======================
   ====== ETAPA 2 ========
   ======================= */

class TimelineScreen extends StatefulWidget {
  final ClientConnection connection;
  final List<String> devices;
  const TimelineScreen({super.key, required this.connection, required this.devices});

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: widget.devices.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final one = widget.devices.length == 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial y tiempo real'),
        bottom: one
            ? null
            : TabBar(
                controller: _tab,
                isScrollable: true,
                tabs: [for (final d in widget.devices) Tab(text: d)],
              ),
      ),
      body: one
          ? DeviceTimeline(deviceName: widget.devices.first, connection: widget.connection)
          : TabBarView(
              controller: _tab,
              children: [for (final d in widget.devices) DeviceTimeline(deviceName: d, connection: widget.connection)],
            ),
    );
  }
}

class DeviceTimeline extends StatefulWidget {
  final String deviceName;
  final ClientConnection connection;
  const DeviceTimeline({super.key, required this.deviceName, required this.connection});

  @override
  State<DeviceTimeline> createState() => _DeviceTimelineState();
}

class _DeviceTimelineState extends State<DeviceTimeline> {
  late Future<List<AudioItem>> _initial;
  late StreamSubscription _sub;
  final List<AudioItem> _items = [];
  bool _loaded = false;

  // Reproductor
  final AudioPlayer _player = AudioPlayer();
  String? _playingUrl;
  PlayerState _pstate = PlayerState.stopped;

  // Poll cada 30s
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _initial = _fetchInitial();
    _sub = widget.connection.events.listen((evt) {
      if (evt['type'] == 'new_audio' &&
          (evt['deviceName'] as String).toLowerCase() == widget.deviceName.toLowerCase()) {
        setState(() {
          _items.insert(
            0,
            AudioItem.fromMap(evt, baseUrl: widget.connection.baseHttp),
          );
        });
      }
    });

    _player.onPlayerStateChanged.listen((s) {
      setState(() => _pstate = s);
    });

    // Poll de reconciliación cada 30s por si se perdió algún WS
    _poll = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final latest = await _fetchInitial();
        _mergeNew(latest);
      } catch (_) {}
    });
  }

  Future<List<AudioItem>> _fetchInitial() async {
    final uri = widget.connection._buildUri('/api/audios', {'deviceName': widget.deviceName, 'limit': '50'});
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final list = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    return list.map((m) => AudioItem.fromMap(m, baseUrl: widget.connection.baseHttp)).toList();
  }

  void _mergeNew(List<AudioItem> fetched) {
    // Inserta elementos que no estén (dedup por filename)
    final known = _items.map((e) => e.filename).toSet();
    final toAdd = fetched.where((e) => !known.contains(e.filename)).toList();
    if (toAdd.isNotEmpty) {
      setState(() {
        _items.insertAll(0, toAdd);
      });
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _poll?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(AudioItem a) async {
    final url = a.fullUrl;
    if (_playingUrl == url && _pstate == PlayerState.playing) {
      await _player.pause();
      return;
    }
    _playingUrl = url;
    await _player.play(UrlSource(url));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AudioItem>>(
      future: _initial,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error cargando: ${snap.error}'));
        }
        if (!_loaded) {
          _items.addAll(snap.data ?? []);
          _loaded = true;
        }
        if (_items.isEmpty) {
          return const Center(child: Text('Sin registros aún.'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(8),
          itemCount: _items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final a = _items[i];
            final tsLocal = _formatLocal(a.timestamp);
            final kb = (a.size / 1024).toStringAsFixed(1);
            final isPlaying = (_playingUrl == a.fullUrl && _pstate == PlayerState.playing);

            return ListTile(
              leading: const Icon(Icons.mic_rounded),
              title: Text(tsLocal),
              subtitle: Text(a.filename),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text('${kb}KB')],
              ),
              onTap: () => _showActionsSheet(context, a, isPlaying),
            );
          },
        );
      },
    );
  }

  void _showActionsSheet(BuildContext context, AudioItem a, bool isPlaying) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(isPlaying ? Icons.pause_circle : Icons.play_circle),
                title: Text(isPlaying ? 'Pausar audio' : 'Reproducir audio'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _togglePlay(a);
                },
              ),
              ListTile(
                enabled: a.hasCoords,
                leading: const Icon(Icons.map_outlined),
                title: Text(a.hasCoords ? 'Ver mapa' : 'Sin coordenadas'),
                onTap: !a.hasCoords
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => MapScreen(item: a),
                        ));
                      },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Abrir URL del audio'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final uri = Uri.parse(a.fullUrl);
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatLocal(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${_two(dt.day)}/${_two(dt.month)}/${dt.year} ${_two(dt.hour)}:${_two(dt.minute)}:${_two(dt.second)}';
    } catch (_) {
      return iso;
    }
  }

  String _two(int x) => x.toString().padLeft(2, '0');
}

class AudioItem {
  final String deviceName;
  final String timestamp;
  final String filename;
  final int size;
  final String urlPath;
  final String baseUrl;
  final double? latitude;
  final double? longitude;

  AudioItem({
    required this.deviceName,
    required this.timestamp,
    required this.filename,
    required this.size,
    required this.urlPath,
    required this.baseUrl,
    required this.latitude,
    required this.longitude,
  });

  factory AudioItem.fromMap(Map<String, dynamic> m, {required String baseUrl}) {
    double? _toD(v) {
      try {
        if (v == null) return null;
        if (v is num) return v.toDouble();
        final s = v.toString().trim();
        if (s.isEmpty) return null;
        return double.parse(s);
      } catch (_) {
        return null;
      }
    }

    return AudioItem(
      deviceName: m['deviceName'],
      timestamp: m['timestamp'],
      filename: m['filename'],
      size: (m['size'] as num?)?.toInt() ?? 0,
      urlPath: m['urlPath'],
      baseUrl: baseUrl,
      latitude: _toD(m['latitude']),
      longitude: _toD(m['longitude']),
    );
  }

  String get fullUrl {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base$urlPath';
  }

  bool get hasCoords => latitude != null && longitude != null;
}

/* =======================
   ====== CONEXIÓN =======
   ======================= */

class ClientConnection {
  final String baseHttp; // p.ej. http://10.0.2.2:4000
  late final String _wsUrl; // ws://host:port/ws
  WebSocketChannel? _ch;
  String? userId;
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  Timer? _heartbeat;

  Stream<Map<String, dynamic>> get events => _events.stream;

  ClientConnection(this.baseHttp) {
    final u = Uri.parse(baseHttp);
    final wsScheme = (u.scheme == 'https') ? 'wss' : 'ws';
    _wsUrl = Uri(scheme: wsScheme, host: u.host, port: u.hasPort ? u.port : null, path: '/ws').toString();
  }

  Uri _buildUri(String path, [Map<String, String>? q]) {
    final u = Uri.parse(baseHttp);
    return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: path, queryParameters: q);
  }

  Future<void> connect() async {
    _ch = WebSocketChannel.connect(Uri.parse(_wsUrl));
    final comp = Completer<void>();

    _ch!.stream.listen((data) {
      final Map<String, dynamic> msg = (data is String) ? jsonDecode(data) : Map<String, dynamic>.from(data);
      final type = msg['type'];
      if (type == 'welcome') {
        userId = msg['userId'];
        comp.complete();
      }
      _events.add(msg);
    }, onError: (e) {
      if (!comp.isCompleted) comp.completeError(e);
    }, onDone: () {
      _events.add({"type": "closed"});
      _stopHeartbeat();
    });

    await comp.future;
    _startHeartbeat();
  }

  Future<void> subscribe(List<String> deviceNames) async {
    final payload = jsonEncode({
      "action": "subscribe",
      "deviceNames": deviceNames,
    });
    _ch?.sink.add(payload);
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _ch?.sink.add(jsonEncode({"action": "ping"}));
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> close() async {
    _stopHeartbeat();
    await _ch?.sink.close();
  }
}

/* =======================
   ====== MAPA ===========
   ======================= */

class MapScreen extends StatelessWidget {
  final AudioItem item;
  const MapScreen({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final lat = item.latitude!;
    final lon = item.longitude!;
    final center = LatLng(lat, lon);

    return Scaffold(
      appBar: AppBar(title: Text('Mapa • ${item.deviceName}')),
      body: FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 16),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'client_flutter_app'),
          MarkerLayer(markers: [
            Marker(
              point: center,
              width: 40,
              height: 40,
              child: const Icon(Icons.location_on, size: 40, color: Colors.red),
            )
          ]),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Text(
          '${_two(lat)} , ${_two(lon)} • ${item.filename}',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  String _two(num v) => v.toStringAsFixed(5);
}
