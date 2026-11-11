import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/models/transport_type.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/services/mesh_discovery_service.dart';
import 'package:privatelm/services/mesh_distribution_service.dart';
import 'package:privatelm/widgets/mesh_allocation_visualizer.dart';

void main() {
  group('Unified Mesh & Instant Worker Exit Tests', () {
    test('workerStopsWithApp is false on Windows/Desktop so exiting worker mode never requires restart', () {
      expect(ClusterService.workerStopsWithApp, isFalse);
    });

    test('classifySilhouetteType selects appropriate symbol for PC, Tablet, and Phone', () {
      expect(classifySilhouetteType('PC', 'Gaming PC'), MeshDeviceSilhouetteType.pc);
      expect(classifySilhouetteType('Mac', 'MacBook Pro'), MeshDeviceSilhouetteType.pc);
      expect(classifySilhouetteType('Tablet', 'Galaxy Tab S9'), MeshDeviceSilhouetteType.tablet);
      expect(classifySilhouetteType('Device', 'iPad Pro 12.9'), MeshDeviceSilhouetteType.tablet);
      expect(classifySilhouetteType('Phone', 'Samsung Galaxy S24'), MeshDeviceSilhouetteType.phone);
    });

    test('MeshNode tracks offline state and custom rename via copyWith', () {
      final node = MeshNode(
        id: 'node_android_123',
        name: 'SM-S928B',
        host: '192.168.1.45',
        deviceType: 'Phone',
        freeRamGB: 6.0,
        status: 'ready',
        lastSeen: DateTime.now(),
      );
      expect(node.isOffline, isFalse);

      final renamedAndOffline = node.copyWith(
        name: 'Samsung S24 (Kitchen)',
        status: 'offline',
      );
      expect(renamedAndOffline.name, 'Samsung S24 (Kitchen)');
      expect(renamedAndOffline.isOffline, isTrue);
    });

    test('MeshDeviceSlice computes assignedLayers and proportional shares accurately', () {
      const sliceLocal = MeshDeviceSlice(
        id: 'local',
        name: 'Gaming PC (This Device)',
        deviceType: 'PC',
        hardwareBackend: 'Vulkan · RTX 4070',
        transportType: TransportType.unknown,
        latencyMs: 0.0,
        capacityMb: 12288,
        assignedModelMb: 6144,
        poolShareFraction: 0.667,
        modelFraction: 0.75,
        memoryUtilization: 0.50,
        layerStart: 0,
        layerEnd: 24,
        isLocal: true,
      );

      const slicePeer = MeshDeviceSlice(
        id: 'peer_1',
        name: 'Galaxy S24 Ultra',
        deviceType: 'Phone',
        hardwareBackend: 'Vulkan · Adreno',
        transportType: TransportType.usb,
        latencyMs: 1.5,
        capacityMb: 6144,
        assignedModelMb: 2048,
        poolShareFraction: 0.333,
        modelFraction: 0.25,
        memoryUtilization: 0.333,
        layerStart: 24,
        layerEnd: 32,
        isLocal: false,
      );

      expect(sliceLocal.assignedLayers, 24);
      expect(slicePeer.assignedLayers, 8);
      expect(sliceLocal.poolShareFraction + slicePeer.poolShareFraction, closeTo(1.0, 0.01));
      expect(sliceLocal.modelFraction + slicePeer.modelFraction, closeTo(1.0, 0.01));
    });
  });

  group('Receiving-Client Push Notification & Progress Model Tests', () {
    test('PeerDistributionProgress tracks incoming transfer and loaded state', () {
      final incoming = PeerDistributionProgress(
        peerId: '192.168.1.10',
        peerName: 'Studio-PC → This Device',
        filename: 'Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf',
        modelName: 'Qwen 2.5 Coder 7B',
        isIncoming: true,
        progress: 0.45,
        speedMBps: 88.5,
        status: 'transferring',
      );

      expect(incoming.isIncoming, isTrue);
      expect(incoming.modelName, 'Qwen 2.5 Coder 7B');
      expect(incoming.progress, 0.45);

      incoming.progress = 1.0;
      incoming.status = 'completed & loaded';
      expect(incoming.status.startsWith('completed'), isTrue);
    });
  });
}

