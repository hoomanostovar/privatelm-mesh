import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../controllers/model_controller.dart';
import '../core/ui.dart';
import 'cluster_service.dart';
import 'download_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mesh_discovery_service.dart';
import 'mesh_telemetry_service.dart';

/// Progress state of a model distribution job to or from a peer device.
class PeerDistributionProgress {
  final String peerId;
  final String peerName;
  final String filename;
  final String modelName;
  final bool isIncoming;
  double progress; // 0.0 to 1.0
  double speedMBps;
  String status; // 'pending', 'connecting', 'transferring', 'loading', 'completed', 'completed & loaded', 'failed'
  String? error;

  PeerDistributionProgress({
    required this.peerId,
    required this.peerName,
    required this.filename,
    String? modelName,
    this.isIncoming = false,
    this.progress = 0.0,
    this.speedMBps = 0.0,
    this.status = 'pending',
    this.error,
  }) : modelName = modelName ?? filename;
}

/// Mesh Distribution Service:
/// Streams GGUF model files directly across local LAN / USB to other mesh devices (P2P),
/// with automatic fallback to download from public source URL.
/// Enables seamless auto-sync for newly connected devices on the mesh.
class MeshDistributionService extends GetxService {
  static const int p2pStreamPort = 50054;
  final HiveService _hive = Get.find<HiveService>();

  HttpServer? _p2pServer;
  final isP2pServerRunning = false.obs;

  /// Active distribution jobs keyed by '${peerId}_${filename}'.
  final activeTransfers = <String, PeerDistributionProgress>{}.obs;

  /// Currently active incoming model push on this client (for live UI banner & toast).
  final incomingTransfer = Rxn<PeerDistributionProgress>();

  /// Whether new devices that join the mesh automatically sync the active model.
  final autoSyncOnJoin = true.obs;

  /// Active mesh model broadcast by coordinator.
  final meshOfferedModel = Rxn<MeshModelOffer>();

  @override
  void onInit() {
    super.onInit();
    final savedAuto = _hive.getSetting<bool>('mesh_auto_sync_on_join') ?? true;
    autoSyncOnJoin.value = savedAuto;

    if (!kIsWeb) {
      _startP2pStreamServer();
    }
  }

  @override
  void onClose() {
    _p2pServer?.close(force: true);
    super.onClose();
  }

  Future<void> setAutoSyncOnJoin(bool value) async {
    autoSyncOnJoin.value = value;
    await _hive.setSetting('mesh_auto_sync_on_join', value);
  }

  /// Starts the local HTTP streaming server on port 50054.
  Future<void> _startP2pStreamServer() async {
    try {
      _p2pServer = await HttpServer.bind(InternetAddress.anyIPv4, p2pStreamPort);
      isP2pServerRunning.value = true;
      _p2pServer?.listen(_handleP2pRequest, onError: (e) {
        print('[MeshDistribution] Server error: $e');
      });
      print('[MeshDistribution] P2P Model Stream Server listening on port $p2pStreamPort');
    } catch (e) {
      print('[MeshDistribution] Could not bind P2P server on port $p2pStreamPort: $e');
      isP2pServerRunning.value = false;
    }
  }

  /// Handles incoming requests for model downloads and sync notifications.
  Future<void> _handleP2pRequest(HttpRequest request) async {
    // Enable CORS
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    // Handle WAN / Mobile status & multi-node mesh gossip handshake:
    // GET /api/mesh/status or POST /api/mesh/handshake
    if (path == '/api/mesh/status' || path == '/api/mesh/handshake') {
      try {
        final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
        final discovery = Get.isRegistered<MeshDiscoveryService>()
            ? Get.find<MeshDiscoveryService>()
            : null;

        if (request.method == 'POST' && discovery != null) {
          final bodyStr = await utf8.decodeStream(request);
          if (bodyStr.trim().isNotEmpty) {
            final incoming = jsonDecode(bodyStr) as Map<String, dynamic>;
            await discovery.ingestRemoteHandshake(incoming, remoteIp: remoteIp);
          }
        }

        if (Get.isRegistered<ClusterService>()) {
          final cluster = Get.find<ClusterService>();
          if (!cluster.worker.value.running) {
            unawaited(cluster.startWorker());
          }
        }

        final statusPayload = discovery != null
            ? await discovery.buildFullHandshakePayload()
            : <String, dynamic>{'status': 'ok', 'port': 50052};

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(statusPayload));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      }
      return;
    }

    // Handle peer worker auto-pair command: POST /api/mesh/pair-worker
    if (request.method == 'POST' && path == '/api/mesh/pair-worker') {
      try {
        if (Get.isRegistered<ClusterService>()) {
          final cluster = Get.find<ClusterService>();
          // Enable Unified Mesh Pool so this node runs its local RPC worker AND stays interactive
          if (!cluster.worker.value.running) {
            await cluster.startWorker();
          }
          if (!cluster.enabled.value && !cluster.dedicatedWorkerOnly.value) {
            await cluster.setRole(ClusterRole.master);
          }
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'status': 'worker_ready',
          'port': 50052,
        }));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      }
      return;
    }

    // Handle peer device rename command: POST /api/mesh/rename
    if (request.method == 'POST' && path == '/api/mesh/rename') {
      try {
        final bodyStr = await utf8.decodeStream(request);
        final json = jsonDecode(bodyStr) as Map<String, dynamic>;
        final targetId = json['target_id'] as String?;
        final targetHost = json['target_host'] as String?;
        final newName = json['name'] as String?;
        final aliases = json['aliases'] is Map
            ? Map<String, dynamic>.from(json['aliases'] as Map)
            : null;

        if (Get.isRegistered<MeshDiscoveryService>()) {
          final discovery = Get.find<MeshDiscoveryService>();
          await discovery.applyRemoteRename(
            targetId: targetId,
            targetHost: targetHost,
            newName: newName,
            incomingAliases: aliases,
          );
          unawaited(discovery.broadcastPresence());
        }

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'status': 'renamed'}));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      }
      return;
    }

    // Handle peer push command: POST /api/mesh/sync
    if (request.method == 'POST' && path == '/api/mesh/sync') {
      try {
        final bodyStr = await utf8.decodeStream(request);
        final json = jsonDecode(bodyStr) as Map<String, dynamic>;
        final filename = json['filename'] as String? ?? '';
        final modelName = json['model_name'] as String? ?? filename;
        final senderName = json['sender_name'] as String? ??
            (request.connectionInfo?.remoteAddress.address ?? 'Mesh Peer');
        final senderHost = json['sender_host'] as String? ??
            request.connectionInfo?.remoteAddress.address;
        final peerKeyOnSender = json['transfer_key'] as String?;
        final autoLoad = json['auto_load'] as bool? ?? true;
        final p2pUrl = json['p2p_url'] as String?;
        final sourceUrl = json['source_url'] as String?;

        if (filename.isEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(jsonEncode({'error': 'Missing filename'}));
          await request.response.close();
          return;
        }

        // Start local fetch in background with receiving notifications & load confirmation
        unawaited(_receiveAndLoadModelFromPeer(
          filename: filename,
          modelName: modelName,
          senderName: senderName,
          senderHost: senderHost,
          peerKeyOnSender: peerKeyOnSender,
          autoLoad: autoLoad,
          p2pUrl: p2pUrl,
          sourceUrl: sourceUrl,
        ));

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'status': 'sync_started', 'filename': filename}));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      }
      return;
    }

    // Handle receiving-client completion acknowledgment: POST /api/mesh/sync-ack
    if (request.method == 'POST' && path == '/api/mesh/sync-ack') {
      try {
        final bodyStr = await utf8.decodeStream(request);
        final json = jsonDecode(bodyStr) as Map<String, dynamic>;
        final transferKey = json['transfer_key'] as String? ?? '';
        final receiverName = json['receiver_name'] as String? ?? 'Mesh Peer';
        final modelName = json['model_name'] as String? ?? '';
        final loaded = json['loaded'] as bool? ?? false;

        if (transferKey.isNotEmpty && activeTransfers.containsKey(transferKey)) {
          final t = activeTransfers[transferKey]!;
          t.progress = 1.0;
          t.status = loaded ? 'completed & loaded' : 'completed';
          activeTransfers.refresh();
        }
        showToast(
          loaded ? 'Peer Model Loaded' : 'Peer Sync Complete',
          loaded
              ? '$receiverName received & loaded $modelName into memory.'
              : '$receiverName finished downloading $modelName.',
          tone: ToastTone.success,
        );

        request.response.statusCode = HttpStatus.ok;
        request.response.write(jsonEncode({'status': 'ack_received'}));
        await request.response.close();
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
      return;
    }

    // Handle model file streaming: GET /models/{filename}
    if (request.method == 'GET' && path.startsWith('/models/')) {
      final filename = Uri.decodeComponent(path.substring('/models/'.length));
      final downloadService = Get.find<DownloadService>();
      final filePath = await downloadService.modelPath(filename);
      final file = File(filePath);

      if (!await file.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Model file not found');
        await request.response.close();
        return;
      }

      final fileLength = await file.length();
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.add('Accept-Ranges', 'bytes');
      request.response.headers.add('Content-Disposition', 'attachment; filename="$filename"');

      // Check for Range request
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring('bytes='.length).split('-');
        final start = int.tryParse(parts[0]) ?? 0;
        final end = parts.length > 1 && parts[1].isNotEmpty
            ? int.tryParse(parts[1]) ?? (fileLength - 1)
            : fileLength - 1;

        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.add('Content-Range', 'bytes $start-$end/$fileLength');
        request.response.contentLength = (end - start) + 1;

        if (Get.isRegistered<MeshTelemetryService>()) {
          Get.find<MeshTelemetryService>().setLocalStatus('communicating');
        }

        await file.openRead(start, end + 1).pipe(request.response);
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = fileLength;

        if (Get.isRegistered<MeshTelemetryService>()) {
          Get.find<MeshTelemetryService>().setLocalStatus('communicating');
        }

        await file.openRead().pipe(request.response);
      }
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  /// Distribute a downloaded model file to selected peer devices.
  Future<void> distributeModelToNodes({
    required String filename,
    required String? sourceUrl,
    required List<MeshNode> targetNodes,
    String? modelName,
    bool autoLoad = true,
  }) async {
    if (targetNodes.isEmpty) return;

    final downloadService = Get.find<DownloadService>();
    final filePath = await downloadService.modelPath(filename);
    final file = File(filePath);
    if (!await file.exists()) {
      throw 'Model file $filename does not exist locally.';
    }

    // Ensure local stream server is up
    if (_p2pServer == null) {
      await _startP2pStreamServer();
    }

    // Determine our local IP and sender name to advertise to peers
    final localIp = await _getLocalIpForMesh();
    final senderName = Get.isRegistered<ClusterService>() &&
            Get.find<ClusterService>().deviceName.isNotEmpty
        ? Get.find<ClusterService>().deviceName
        : Platform.localHostname;

    for (final node in targetNodes) {
      final key = '${node.id}_$filename';
      final transfer = PeerDistributionProgress(
        peerId: node.id,
        peerName: node.name,
        filename: filename,
        modelName: modelName ?? filename,
        status: 'connecting',
      );
      activeTransfers[key] = transfer;

      // Launch distribution push asynchronously
      _pushModelToPeer(
        node: node,
        filename: filename,
        modelName: modelName ?? filename,
        senderName: senderName,
        senderHost: localIp,
        transferKey: key,
        autoLoad: autoLoad,
        p2pUrl: 'http://$localIp:$p2pStreamPort/models/${Uri.encodeComponent(filename)}',
        sourceUrl: sourceUrl,
      );
    }
  }

  Future<void> _pushModelToPeer({
    required MeshNode node,
    required String filename,
    required String modelName,
    required String senderName,
    required String senderHost,
    required String transferKey,
    required bool autoLoad,
    required String p2pUrl,
    required String? sourceUrl,
  }) async {
    final key = '${node.id}_$filename';
    final transfer = activeTransfers[key];
    if (transfer == null) return;

    try {
      transfer.status = 'connecting';
      activeTransfers.refresh();

      // Post sync command to peer's distribution port or cluster port
      final uri = Uri.parse('http://${node.host}:$p2pStreamPort/api/mesh/sync');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'filename': filename,
              'model_name': modelName,
              'sender_name': senderName,
              'sender_host': senderHost,
              'transfer_key': transferKey,
              'auto_load': autoLoad,
              'p2p_url': p2pUrl,
              'source_url': sourceUrl,
            }),
          )
          .timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        transfer.status = 'transferring';
        transfer.progress = 0.10;
        transfer.speedMBps = 65.0;
        activeTransfers.refresh();

        showToast(
          'Pushing Model to Peer',
          'Streaming $modelName to ${node.name}...',
          tone: ToastTone.info,
        );

        // Simulate progress feedback while peer downloads; peer's /api/mesh/sync-ack will mark 'completed & loaded'
        _simulateProgress(key);
      } else {
        transfer.status = 'failed';
        transfer.error = 'Peer HTTP ${response.statusCode}';
        activeTransfers.refresh();
      }
    } catch (e) {
      // If direct peer push failed (e.g. firewall), mark failed with reason
      transfer.status = 'failed';
      transfer.error = 'Can\'t reach peer push agent: $e';
      activeTransfers.refresh();
    }
  }

  void _simulateProgress(String key) {
    Timer.periodic(const Duration(milliseconds: 600), (timer) {
      final t = activeTransfers[key];
      if (t == null || t.status != 'transferring') {
        timer.cancel();
        return;
      }
      t.progress = (t.progress + 0.10).clamp(0.0, 0.95);
      t.speedMBps = 75.0 + (t.progress * 20.0);
      activeTransfers.refresh();
    });
  }

  /// Handles receiving a pushed model on this client:
  /// 1. Shows immediate toast notification & live incoming transfer banner.
  /// 2. Tracks real byte-by-byte download progress and MB/s speed.
  /// 3. Refreshes downloaded model catalog on completion.
  /// 4. Automatically loads the model into memory and shows completion confirmation toast.
  /// 5. Sends completion + load ACK back to the sender node.
  Future<void> _receiveAndLoadModelFromPeer({
    required String filename,
    required String modelName,
    required String senderName,
    String? senderHost,
    String? peerKeyOnSender,
    bool autoLoad = true,
    String? p2pUrl,
    String? sourceUrl,
  }) async {
    final key = 'incoming_$filename';
    final progressEntry = PeerDistributionProgress(
      peerId: senderHost ?? 'peer',
      peerName: '$senderName → This Device',
      filename: filename,
      modelName: modelName,
      isIncoming: true,
      status: 'transferring',
      progress: 0.01,
      speedMBps: 0.0,
    );

    activeTransfers[key] = progressEntry;
    incomingTransfer.value = progressEntry;
    activeTransfers.refresh();

    showToast(
      'Incoming Model Push',
      'Receiving $modelName from $senderName...',
      tone: ToastTone.info,
    );

    final downloadedOk = await _fetchModelFromMeshOrSource(
      filename: filename,
      p2pUrl: p2pUrl,
      sourceUrl: sourceUrl,
      onProgress: (fraction, mbps) {
        progressEntry.progress = fraction;
        progressEntry.speedMBps = mbps;
        incomingTransfer.refresh();
        activeTransfers.refresh();
      },
    );

    if (!downloadedOk) {
      progressEntry.status = 'failed';
      progressEntry.error = 'Transfer interrupted';
      incomingTransfer.refresh();
      activeTransfers.refresh();
      showToast(
        'Model Transfer Failed',
        'Could not finish receiving $modelName from $senderName.',
        tone: ToastTone.error,
      );
      return;
    }

    // Refresh local downloaded model state
    ModelController? modelCtrl;
    if (Get.isRegistered<ModelController>()) {
      modelCtrl = Get.find<ModelController>();
      await modelCtrl.refreshDownloaded();
    }

    var loadedSuccessfully = false;
    if (autoLoad) {
      progressEntry.progress = 1.0;
      progressEntry.status = 'loading';
      incomingTransfer.refresh();
      activeTransfers.refresh();

      showToast(
        'Model Downloaded · Loading',
        '$modelName received! Loading into memory...',
        tone: ToastTone.info,
      );

      try {
        if (modelCtrl != null) {
          final catalogMatch =
              modelCtrl.availableModels.firstWhereOrNull((m) => m.filename == filename);
          if (catalogMatch != null) {
            await modelCtrl.loadModel(catalogMatch.filename);
            loadedSuccessfully = Get.find<InferenceService>().isModelLoaded.value;
          }
        }
        if (!loadedSuccessfully && Get.isRegistered<InferenceService>()) {
          final destPath = await Get.find<DownloadService>().modelPath(filename);
          await Get.find<InferenceService>().loadModel(
            destPath,
            modelName: modelName,
          );
          loadedSuccessfully = Get.find<InferenceService>().isModelLoaded.value;
        }
      } catch (e) {
        print('[MeshDistribution] Auto-load after push failed: $e');
      }
    }

    progressEntry.progress = 1.0;
    progressEntry.status = loadedSuccessfully ? 'completed & loaded' : 'completed';
    incomingTransfer.refresh();
    activeTransfers.refresh();

    showToast(
      loadedSuccessfully ? 'Model Received & Loaded' : 'Model Sync Complete',
      loadedSuccessfully
          ? '$modelName from $senderName is loaded and ready for chat!'
          : '$modelName from $senderName has been saved to this device.',
      tone: ToastTone.success,
    );

    // Clear incoming banner after 6 seconds so UI stays clean
    Future.delayed(const Duration(seconds: 6), () {
      if (incomingTransfer.value == progressEntry) {
        incomingTransfer.value = null;
      }
    });

    // Notify sender via /api/mesh/sync-ack
    if (senderHost != null && senderHost.isNotEmpty) {
      try {
        final myName = Get.isRegistered<ClusterService>() &&
                Get.find<ClusterService>().deviceName.isNotEmpty
            ? Get.find<ClusterService>().deviceName
            : Platform.localHostname;
        await http
            .post(
              Uri.parse('http://$senderHost:$p2pStreamPort/api/mesh/sync-ack'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'transfer_key': peerKeyOnSender ?? '',
                'receiver_name': myName,
                'model_name': modelName,
                'loaded': loadedSuccessfully,
              }),
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }

  /// Public helper for joining and syncing an offered mesh model onto this device.
  Future<void> syncOfferedModel(MeshModelOffer offer) async {
    await _receiveAndLoadModelFromPeer(
      filename: offer.filename,
      modelName: offer.modelName,
      senderName: offer.sourceNodeName,
      p2pUrl: offer.p2pUrl,
      sourceUrl: offer.sourceUrl,
      autoLoad: true,
    );
  }

  /// Download model from P2P LAN stream with real byte-level progress tracking,
  /// falling back to source URL if needed.
  Future<bool> _fetchModelFromMeshOrSource({
    required String filename,
    String? p2pUrl,
    String? sourceUrl,
    void Function(double progress, double speedMBps)? onProgress,
  }) async {
    final downloadService = Get.find<DownloadService>();
    final destPath = await downloadService.modelPath(filename);

    if (await File(destPath).exists()) {
      print('[MeshDistribution] Model $filename already exists locally.');
      onProgress?.call(1.0, 0.0);
      return true;
    }

    if (p2pUrl != null && p2pUrl.isNotEmpty) {
      final client = http.Client();
      try {
        print('[MeshDistribution] Attempting high-speed P2P LAN stream from $p2pUrl');
        final request = http.Request('GET', Uri.parse(p2pUrl));
        final response = await client.send(request);

        if (response.statusCode == 200 || response.statusCode == 206) {
          final totalBytes = response.contentLength ?? 0;
          final file = File('$destPath.downloading');
          final sink = file.openWrite();
          var receivedBytes = 0;
          final startTime = DateTime.now();
          var lastUpdateMs = 0;

          await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
            if (elapsedMs - lastUpdateMs >= 180) {
              lastUpdateMs = elapsedMs;
              final frac = totalBytes > 0
                  ? (receivedBytes / totalBytes).clamp(0.01, 0.99)
                  : 0.5;
              final mbps = elapsedMs > 0
                  ? (receivedBytes / (1024 * 1024)) / (elapsedMs / 1000.0)
                  : 0.0;
              onProgress?.call(frac, mbps);
            }
          }

          await sink.flush();
          await sink.close();
          await file.rename(destPath);
          onProgress?.call(1.0, 0.0);
          print('[MeshDistribution] P2P transfer of $filename completed successfully!');
          return true;
        }
      } catch (e) {
        print('[MeshDistribution] P2P LAN stream failed ($e), falling back to source URL.');
      } finally {
        client.close();
      }
    }

    // Fallback: download from public source URL
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      try {
        print('[MeshDistribution] Starting fallback source download from $sourceUrl');
        await downloadService.downloadModel(url: sourceUrl, filename: filename);
        onProgress?.call(1.0, 0.0);
        return await File(destPath).exists();
      } catch (_) {}
    }
    return false;
  }

  /// Finds preferred local IP address to offer to peers.
  Future<String> _getLocalIpForMesh() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in interfaces) {
        for (final addr in i.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }
}

/// Information about an active model offered on the mesh.
class MeshModelOffer {
  final String filename;
  final String modelName;
  final double sizeMB;
  final String sourceNodeId;
  final String sourceNodeName;
  final String p2pUrl;
  final String? sourceUrl;

  const MeshModelOffer({
    required this.filename,
    required this.modelName,
    required this.sizeMB,
    required this.sourceNodeId,
    required this.sourceNodeName,
    required this.p2pUrl,
    this.sourceUrl,
  });
}

