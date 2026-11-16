import 'package:flutter_test/flutter_test.dart';
import 'package:obdscan/monitor/agent.dart';
import 'package:obdscan/monitor/baseline.dart';
import 'package:obdscan/obd/dtc.dart';
import 'package:obdscan/obd/elm327.dart';
import 'package:obdscan/obd/live_poller.dart';
import 'package:obdscan/obd/obd_client.dart';
import 'package:obdscan/obd/sim/simulated_adapter.dart';
import 'package:obdscan/obd/sim/simulated_vehicle.dart';

final DateTime _start = DateTime(2026, 1, 1, 12);

/// Feeds one sample per second for [seconds], starting at [from] seconds.
void feed(MonitorAgent agent, int from, int seconds, Map<int, double> Function(int second) values) {
  for (var i = from; i < from + seconds; i++) {
    agent.addSample(LiveSample(_start.add(Duration(seconds: i)), values(i)));
  }
}

Map<int, double> healthy(int second) => {
  0x0C: 2100,
  0x0D: 80,
  0x05: 90,
  0x42: 14.1,
  0x07: 2.5,
  0x5C: 95,
  0x2F: 60,
  0x0F: 25,
};

void main() {
  group('MonitorAgent rules', () {
    test('stays quiet on a healthy drive', () {
      final agent = MonitorAgent();
      feed(agent, 0, 1200, healthy);
      expect(agent.findings, isEmpty);
    });

    test('overheating is reported as critical and clears when it cools', () {
      final agent = MonitorAgent();
      final raised = <Finding>[];
      agent.onFinding.listen(raised.add);
      feed(agent, 0, 60, healthy);
      feed(agent, 60, 4, (s) => {...healthy(s), 0x05: 120});
      expect(agent.findings, isEmpty, reason: 'must persist for 5 s first');
      feed(agent, 64, 3, (s) => {...healthy(s), 0x05: 120});
      expect(agent.findings.single.id, 'coolant_critical');
      expect(agent.findings.single.severity, Severity.critical);
      expect(agent.findings.single.detail, contains('120'));

      feed(agent, 67, 40, (s) => {...healthy(s), 0x05: 120});
      expect(agent.findings.map((f) => f.id), containsAll(['coolant_critical', 'coolant_high']));
      expect(agent.findings.where((f) => f.id == 'coolant_critical'), hasLength(1), reason: 'reported once');

      feed(agent, 107, 30, healthy);
      expect(agent.activeFindings, isEmpty);
    });

    test('a brief spike does not raise an alarm', () {
      final agent = MonitorAgent();
      feed(agent, 0, 60, healthy);
      feed(agent, 60, 3, (s) => {...healthy(s), 0x05: 125});
      feed(agent, 63, 60, healthy);
      expect(agent.findings, isEmpty);
    });

    test('charging failure', () {
      final agent = MonitorAgent();
      feed(agent, 0, 90, healthy);
      feed(agent, 90, 59, (s) => {...healthy(s), 0x42: 11.9});
      expect(agent.findings, isEmpty);
      feed(agent, 149, 5, (s) => {...healthy(s), 0x42: 11.9});
      expect(agent.findings.single.id, 'voltage_low');
      feed(agent, 154, 30, (s) => {...healthy(s), 0x42: 11.2});
      expect(agent.findings.first.id, 'voltage_critical');
    });

    test('falls back to the adapter voltage when the car has no voltage PID', () {
      final agent = MonitorAgent();
      Map<int, double> noPid(int s) => {...healthy(s)..remove(0x42), adapterVoltagePid: 11.8};
      feed(agent, 0, 130, noPid);
      expect(agent.findings.single.id, 'voltage_low');
    });

    test('low voltage with the engine off is not a charging fault', () {
      final agent = MonitorAgent();
      feed(agent, 0, 300, (s) => {0x0C: 0, 0x0D: 0, 0x05: 40, 0x42: 11.9});
      expect(agent.findings, isEmpty);
    });

    test('lean mixture', () {
      final agent = MonitorAgent();
      feed(agent, 0, 30, healthy);
      feed(agent, 30, 62, (s) => {...healthy(s), 0x07: 21.0});
      expect(agent.findings.single.id, 'lean_bank1');
      expect(agent.findings.single.title, contains('lean'));
    });

    test('unstable idle', () {
      final agent = MonitorAgent();
      feed(agent, 0, 60, (s) => {...healthy(s), 0x0D: 0, 0x0C: 780});
      expect(agent.findings, isEmpty);
      feed(agent, 60, 40, (s) => {...healthy(s), 0x0D: 0, 0x0C: s.isEven ? 600 : 1000});
      expect(agent.findings.single.id, 'idle_unstable');
    });

    test('engine that never warms up', () {
      final agent = MonitorAgent();
      feed(agent, 0, 16 * 60, (s) => {...healthy(s), 0x05: 55});
      expect(agent.findings.single.id, 'not_warming');
    });

    test('new fault codes during the drive', () {
      final agent = MonitorAgent();
      MonitorStatus status(int count, bool mil) =>
          MonitorStatus(milOn: mil, dtcCount: count, compressionIgnition: false, tests: const []);
      expect(agent.addStatus(status(1, true)), isFalse, reason: 'codes present at connect are not new');
      expect(agent.addStatus(status(1, true)), isFalse);
      expect(agent.addStatus(status(2, true)), isTrue);
      agent.reportNewCodes(['P0301 Cylinder 1 Misfire Detected'], _start);
      expect(agent.findings.single.detail, contains('P0301'));
    });
  });

  group('Baseline learning', () {
    Map<int, double> idle(int s, double rpm) => {0x0C: rpm + (s % 3 - 1) * 5, 0x0D: 0, 0x05: 90, 0x42: 14.1, 0x07: 2.5};

    test('learns after a normal drive and flags drift later', () {
      final baseline = Baseline();
      for (var drive = 0; drive < 3; drive++) {
        final agent = MonitorAgent(baseline: baseline);
        feed(agent, 0, 600, (s) => idle(s, 780));
        expect(agent.findings, isEmpty);
        expect(agent.finishSession(), contains(Signature.idleRpm));
      }
      expect(baseline.isLearned(Signature.idleRpm), isTrue);
      expect(baseline.stats[Signature.idleRpm]!.mean, closeTo(780, 2));

      final agent = MonitorAgent(baseline: baseline);
      feed(agent, 0, 600, (s) => idle(s, 1010));
      final finding = agent.findings.single;
      expect(finding.id, 'baseline_idleRpm');
      expect(finding.title, contains('higher than usual'));
      expect(finding.detail, contains('780'));
      expect(agent.finishSession(), isNot(contains(Signature.idleRpm)), reason: 'abnormal readings are not learned');
      expect(baseline.stats[Signature.idleRpm]!.sessions, 3);
    });

    test('is silent until enough drives have been seen', () {
      final baseline = Baseline();
      final first = MonitorAgent(baseline: baseline);
      feed(first, 0, 600, (s) => idle(s, 780));
      first.finishSession();
      final second = MonitorAgent(baseline: baseline);
      feed(second, 0, 600, (s) => idle(s, 1010));
      expect(second.findings, isEmpty);
    });

    test('survives a save and reload', () {
      final baseline = Baseline()
        ..learn(Signature.chargingVoltage, 14.1)
        ..learn(Signature.chargingVoltage, 14.2)
        ..learn(Signature.chargingVoltage, 14.0);
      final restored = Baseline.fromJson(baseline.toJson());
      expect(restored.isLearned(Signature.chargingVoltage), isTrue);
      expect(restored.compare(Signature.chargingVoltage, 14.2), isNull);
      expect(restored.compare(Signature.chargingVoltage, 13.2), isNotNull);
    });
  });

  group('LivePoller with the simulated car', () {
    test('covers every requested parameter and catches an injected fault', () async {
      var seconds = 0.0;
      DateTime clock() => _start.add(Duration(milliseconds: (seconds * 1000).round()));
      final vehicle = SimulatedVehicle(elapsedSeconds: () => seconds, warmStart: true);
      final client = ObdClient(Elm327(SimulatedAdapter(vehicle: vehicle, latency: Duration.zero)));
      await client.connect();

      final poller = LivePoller(client, clock: clock)
        ..fastPids = {0x0C, 0x0D, 0x05}
        ..slowPids = client.readablePids.toSet();
      final agent = MonitorAgent();
      final seen = <int>{};
      final statuses = <MonitorStatus>[];
      poller.status.listen(statuses.add);

      vehicle.setFault(SimFault.overheating, true);
      poller.start();
      await for (final sample in poller.samples) {
        agent.addSample(sample);
        seen.addAll(sample.values.keys);
        expect(sample.values.keys, containsAll([0x0C, 0x0D, 0x05]), reason: 'fast PIDs arrive every cycle');
        seconds += 1;
        if (agent.findings.any((f) => f.id == 'coolant_critical') || seconds > 300) break;
      }
      await poller.stop();

      expect(agent.findings.any((f) => f.id == 'coolant_critical'), isTrue);
      expect(seen, containsAll(client.readablePids));
      expect(seen, contains(adapterVoltagePid));
      expect(statuses, isNotEmpty);
      expect(statuses.first.milOn, isTrue);
    });

    test('reports when the adapter goes away', () async {
      final adapter = SimulatedAdapter(latency: Duration.zero);
      final client = ObdClient(Elm327(adapter));
      await client.connect();
      final poller = LivePoller(client)..fastPids = {0x0C};
      final failure = poller.failures.first;
      poller.start();
      await poller.samples.first;
      await adapter.unplug();
      expect(await failure, isA<ElmException>());
      expect(poller.isRunning, isFalse);
    });
  });
}
