// lib/clientMain.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:fl_chart/fl_chart.dart';

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
  final _serverCtrl = TextEditingController(text: 'http://0.0.0.0:4000');
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

  final AudioPlayer _player = AudioPlayer();
  String? _playingUrl;
  PlayerState _pstate = PlayerState.stopped;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _initial = _fetchInitial();

    _sub = widget.connection.events.listen((evt) {
      if (evt['type'] == 'new_audio' &&
          (evt['deviceName'] as String?)?.toLowerCase() == widget.deviceName.toLowerCase()) {
        setState(() {
          _items.insert(0, AudioItem.fromMap(evt, baseUrl: widget.connection.baseHttp));
        });
      }
    });

    _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _pstate = s);
    });

    _poll = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final latest = await _fetchInitial();
        _mergeNew(latest);
      } catch (_) {}
    });
  }

  Future<List<AudioItem>> _fetchInitial() async {
    final uri = widget.connection.buildUri('/api/audios', {'deviceName': widget.deviceName, 'limit': '200'});
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final list = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    return list.map((m) => AudioItem.fromMap(m, baseUrl: widget.connection.baseHttp)).toList();
  }

  void _mergeNew(List<AudioItem> fetched) {
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

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'device: ${widget.deviceName}',
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DetectionHistoryScreen(
                          deviceName: widget.deviceName,
                          connection: widget.connection,
                        ),
                      ));
                    },
                    icon: const Icon(Icons.show_chart),
                    label: const Text('Historial detección'),
                  )
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _items.isEmpty
                  ? const Center(child: Text('Sin registros aún.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(8),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final a = _items[i];
                        final tsLocal = _formatLocal(a.timestamp);
                        final kb = (a.size / 1024).toStringAsFixed(1);
                        final isPlaying = (_playingUrl == a.fullUrl && _pstate == PlayerState.playing);

                        final detIcon = a.detected
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : const Icon(Icons.cancel, color: Colors.red);

                        return ListTile(
                          leading: const Icon(Icons.mic_rounded),
                          title: Text(tsLocal),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.filename),
                              if (a.detected && a.categoria.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Wrap(
                                    spacing: 6,
                                    children: [
                                      Chip(
                                        label: Text(a.categoria),
                                        visualDensity: VisualDensity.compact,
                                      )
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              detIcon,
                              const SizedBox(height: 4),
                              Text('${kb}KB', style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                          onTap: () => _showActionsSheet(context, a, isPlaying),
                        );
                      },
                    ),
            ),
          ],
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

/* =======================
   ====== MODELO =========
   ======================= */

class AudioItem {
  final String deviceName;
  final String timestamp;
  final String filename;
  final int size;
  final String urlPath;
  final String baseUrl;
  final double? latitude;
  final double? longitude;

  // detección
  final int deteccionNum; // 0/1
  final String categoria;

  AudioItem({
    required this.deviceName,
    required this.timestamp,
    required this.filename,
    required this.size,
    required this.urlPath,
    required this.baseUrl,
    required this.latitude,
    required this.longitude,
    required this.deteccionNum,
    required this.categoria,
  });

  static double? _toD(dynamic v) {
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

  static int _toI(dynamic v) {
    try {
      if (v == null) return 0;
      if (v is bool) return v ? 1 : 0;
      if (v is num) return v.toInt();
      final s = v.toString().trim();
      if (s.isEmpty) return 0;
      return int.parse(s);
    } catch (_) {
      return 0;
    }
  }

  factory AudioItem.fromMap(Map<String, dynamic> m, {required String baseUrl}) {
    final detNum = _toI(m['deteccion_num']);
    final detTxt = (m['deteccion_texto'] ?? '').toString().toLowerCase().trim();
    final effectiveDet = detNum == 1 || detTxt == 'true';

    return AudioItem(
      deviceName: (m['deviceName'] ?? '').toString(),
      timestamp: (m['timestamp'] ?? '').toString(),
      filename: (m['filename'] ?? '').toString(),
      size: _toI(m['size']),
      urlPath: (m['urlPath'] ?? '').toString(),
      baseUrl: baseUrl,
      latitude: _toD(m['latitude']),
      longitude: _toD(m['longitude']),
      deteccionNum: effectiveDet ? 1 : 0,
      categoria: (m['categoria'] ?? '').toString(),
    );
  }

  String get fullUrl {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base$urlPath';
  }

  bool get hasCoords => latitude != null && longitude != null;
  bool get detected => deteccionNum == 1;
}

/* =======================
   ====== CONEXIÓN =======
   ======================= */

class ClientConnection {
  final String baseHttp; // http://host:4000
  late final String wsUrl; // ws://host:port/ws
  WebSocketChannel? _ch;
  String? userId;
  final StreamController<Map<String, dynamic>> _events = StreamController.broadcast();
  Timer? _heartbeat;

  Stream<Map<String, dynamic>> get events => _events.stream;

  ClientConnection(this.baseHttp) {
    final u = Uri.parse(baseHttp);
    final wsScheme = (u.scheme == 'https') ? 'wss' : 'ws';
    wsUrl = Uri(
      scheme: wsScheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: '/ws',
    ).toString();
  }

  Uri buildUri(String path, [Map<String, String>? q]) {
    final u = Uri.parse(baseHttp);
    return Uri(
      scheme: u.scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: path,
      queryParameters: q,
    );
  }

  Future<void> connect() async {
    _ch = WebSocketChannel.connect(Uri.parse(wsUrl));
    final comp = Completer<void>();

    _ch!.stream.listen((data) {
      final Map<String, dynamic> msg = (data is String) ? jsonDecode(data) : Map<String, dynamic>.from(data);
      final type = msg['type'];
      if (type == 'welcome') {
        userId = msg['userId'];
        if (!comp.isCompleted) comp.complete();
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
    final payload = jsonEncode({"action": "subscribe", "deviceNames": deviceNames});
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
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'client_flutter_app',
          ),
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

/* =======================================
   ====== HISTORIAL DETECCIÓN (SPLINE) ====
   ======================================= */

class DetectionHistoryScreen extends StatefulWidget {
  final String deviceName;
  final ClientConnection connection;
  const DetectionHistoryScreen({super.key, required this.deviceName, required this.connection});

  @override
  State<DetectionHistoryScreen> createState() => _DetectionHistoryScreenState();
}

class _DetectionHistoryScreenState extends State<DetectionHistoryScreen> {
  late Future<void> _initial;
  StreamSubscription? _sub;

  final List<AudioItem> _itemsAsc = [];

  int _window = 20; // rolling window (suavizado)
  bool _onlyLastN = true;
  int _lastN = 300;

  @override
  void initState() {
    super.initState();
    _initial = _loadInitial();

    _sub = widget.connection.events.listen((evt) {
      if (evt['type'] == 'new_audio' &&
          (evt['deviceName'] as String?)?.toLowerCase() == widget.deviceName.toLowerCase()) {
        final a = AudioItem.fromMap(evt, baseUrl: widget.connection.baseHttp);
        _insertSorted(a);
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _loadInitial() async {
    final uri = widget.connection.buildUri('/api/audios', {'deviceName': widget.deviceName, 'limit': '500'});
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final list = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    final items = list.map((m) => AudioItem.fromMap(m, baseUrl: widget.connection.baseHttp)).toList();

    // /api/audios viene desc, lo pasamos a asc
    items.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _itemsAsc
      ..clear()
      ..addAll(items);
  }

  void _insertSorted(AudioItem a) {
    if (_itemsAsc.any((x) => x.filename == a.filename)) return;
    final t = a.timestamp;

    int lo = 0, hi = _itemsAsc.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_itemsAsc[mid].timestamp.compareTo(t) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _itemsAsc.insert(lo, a);

    if (_onlyLastN && _itemsAsc.length > _lastN * 2) {
      _itemsAsc.removeRange(0, _itemsAsc.length - _lastN * 2);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  DateTime? _safeParse(String iso) {
    try {
      return DateTime.parse(iso).toLocal();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Historial detección • ${widget.deviceName}')),
      body: FutureBuilder<void>(
        future: _initial,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }

          // Datos a graficar (asc)
          final data = (_onlyLastN && _itemsAsc.length > _lastN)
              ? _itemsAsc.sublist(_itemsAsc.length - _lastN)
              : _itemsAsc;

          final total = data.length;
          final detected = data.fold<int>(0, (acc, a) => acc + a.deteccionNum);
          final ratio = total == 0 ? 0.0 : (detected / total);

          // Serie suavizada O(n) con x = índice (evita crash por epoch+interval)
          final w = max(1, min(_window, max(1, data.length)));
          final pts = <FlSpot>[];
          int rollingSum = 0;
          final queue = <int>[];

          for (int i = 0; i < data.length; i++) {
            final v = data[i].deteccionNum;
            queue.add(v);
            rollingSum += v;
            if (queue.length > w) {
              rollingSum -= queue.removeAt(0);
            }
            final y = rollingSum / queue.length; // 0..1
            pts.add(FlSpot(i.toDouble(), y));
          }

          // Interval razonable en índices
          final xInterval = max(1, (pts.length / 4).floor()).toDouble();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Chip(label: Text('Audios: $total')),
                    Chip(label: Text('Detecciones: $detected')),
                    Chip(label: Text('Ratio: ${(ratio * 100).toStringAsFixed(1)}%')),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Ventana'),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 120,
                          child: Slider(
                            value: _window.toDouble(),
                            min: 1,
                            max: 60,
                            divisions: 59,
                            label: '$_window',
                            onChanged: (v) => setState(() => _window = v.round()),
                          ),
                        ),
                        Text('$_window'),
                      ],
                    ),
                    FilterChip(
                      label: Text('Últimos $_lastN'),
                      selected: _onlyLastN,
                      onSelected: (v) => setState(() => _onlyLastN = v),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: pts.isEmpty
                      ? const Center(child: Text('Sin datos para graficar.'))
                      : LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: max(0, pts.length - 1).toDouble(),
                            minY: 0,
                            maxY: 1,
                            gridData: const FlGridData(show: true),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 42,
                                  getTitlesWidget: (value, meta) => Text('${(value * 100).round()}%'),
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 32,
                                  interval: xInterval,
                                  getTitlesWidget: (value, meta) {
                                    final i = value.round();
                                    if (i < 0 || i >= data.length) return const SizedBox.shrink();
                                    final dt = _safeParse(data[i].timestamp);
                                    if (dt == null) return const SizedBox.shrink();
                                    return Text(
                                      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                                      style: const TextStyle(fontSize: 10),
                                    );
                                  },
                                ),
                              ),
                            ),
                            lineBarsData: [
                              LineChartBarData(
                                spots: pts,
                                isCurved: true,
                                barWidth: 3,
                                dotData: const FlDotData(show: false),
                                belowBarData: BarAreaData(show: true),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  'Curva = promedio móvil (ventana $_window) de detección (0..1).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            ],
          );
        },
      ),
    );
  }
}
