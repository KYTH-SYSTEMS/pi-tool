import 'package:evcc_updater/src/docker_containers.dart';
import 'package:evcc_updater/src/full_update.dart';
import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceStatus _s(String id,
        {bool installed = true, bool known = true, bool available = false}) =>
    ServiceStatus(
        id: id,
        name: id,
        installed: installed,
        updateKnown: known,
        updateAvailable: available);

void main() {
  group('planFullUpdate', () {
    test('a Pi with only the system packages has no extra step', () {
      final plan = planFullUpdate([_s('system', available: true)]);
      expect(plan.pihole, isFalse);
      expect(plan.homeAssistant, isFalse);
      expect(plan.evcc, isFalse);
    });

    test('Pi-hole joins when it reports an update', () {
      expect(planFullUpdate([_s('pihole', available: true)]).pihole, isTrue);
      expect(planFullUpdate([_s('pihole')]).pihole, isFalse);
    });

    test('Pi-hole with an unknown state is pulled in (the update finds out)',
        () {
      expect(planFullUpdate([_s('pihole', known: false)]).pihole, isTrue);
    });

    test('Home Assistant always joins: a container reports no update state',
        () {
      expect(planFullUpdate([_s('homeassistant', known: false)]).homeAssistant,
          isTrue);
    });

    test('evcc joins when it has an update or runs in a container', () {
      expect(planFullUpdate([_s('evcc', available: true)]).evcc, isTrue);
      expect(planFullUpdate([_s('evcc', known: false)]).evcc, isTrue);
      expect(planFullUpdate([_s('evcc')]).evcc, isFalse);
    });

    test('a service that is not installed never joins', () {
      final plan = planFullUpdate([
        _s('pihole', installed: false, available: true),
        _s('homeassistant', installed: false, known: false),
        _s('evcc', installed: false, known: false),
      ]);
      expect(plan.pihole, isFalse);
      expect(plan.homeAssistant, isFalse);
      expect(plan.evcc, isFalse);
    });
  });

  group('fullUpdatePending', () {
    test('a known update on any installed service counts', () {
      expect(fullUpdatePending([_s('system', available: true)]), isTrue);
      expect(fullUpdatePending([_s('system'), _s('pihole', available: true)]),
          isTrue);
      expect(fullUpdatePending([_s('grafana', available: true)]), isTrue);
    });

    test('an unknown state is no pending update', () {
      expect(
          fullUpdatePending([
            _s('system'),
            _s('homeassistant', known: false),
            _s('evcc', known: false),
          ]),
          isFalse);
    });

    test('a not installed service does not count', () {
      expect(
          fullUpdatePending(
              [_s('system'), _s('pihole', installed: false, available: true)]),
          isFalse);
    });
  });

  group('otherContainersToUpdate', () {
    DockerContainer c(String name, String image, {String state = 'running'}) =>
        (name: name, state: state, status: '', image: image);

    test('every running container besides Home Assistant and evcc', () {
      final names = otherContainersToUpdate([
        c('homeassistant', 'ghcr.io/home-assistant/home-assistant:stable'),
        c('evcc', 'evcc/evcc:latest'),
        c('ring-mqtt', 'tsightler/ring-mqtt'),
        c('mosquitto', 'eclipse-mosquitto:2'),
      ], evccContainer: 'evcc');
      expect(names, ['ring-mqtt', 'mosquitto']);
    });

    test('Home Assistant is found by its image, whatever its name', () {
      expect(
          otherContainersToUpdate(
              [c('smarthome', 'homeassistant/home-assistant:2025.1')]),
          isEmpty);
    });

    test('a stopped container stays as it is', () {
      expect(
          otherContainersToUpdate(
              [c('old', 'nginx:1', state: 'exited'), c('web', 'nginx:1')]),
          ['web']);
    });

    test("Pi-Tool's rollback containers are never updated", () {
      expect(
          otherContainersToUpdate(
              [c('evcc-evccpitool-old', 'evcc/evcc:0.300.0')]),
          isEmpty);
    });

    test('without Docker there is nothing to do', () {
      expect(otherContainersToUpdate(const []), isEmpty);
    });
  });
}
