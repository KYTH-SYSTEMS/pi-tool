/// Where each service's own project lives: its website and — only where the
/// project actually ships one — its official Android app.
///
/// Requested by a user (2026-08-14): the app manages the services, but there was
/// no way from a card to the application behind it. This is deliberately a
/// static table, not detection: the app knows a fixed catalogue of services, so
/// nothing here can drift per Pi. Pure data, no I/O — the UI decides how to open
/// a link (browser, or [AppLauncher] for an app with a Play-Store fallback).
library;

/// The outward links for one service.
class ServiceLinks {
  const ServiceLinks({required this.website, this.appPackage, this.appUrl});

  /// The project's homepage (which is also the way into its docs).
  final String website;

  /// Android package of the project's OWN app, or null when there is none.
  /// Third-party apps are never listed — "official" has to mean official.
  final String? appPackage;

  /// Play listing for [appPackage] — the fallback when the app isn't installed.
  final String? appUrl;

  /// Whether an official app can be offered (both halves present).
  bool get hasApp => appPackage != null && appUrl != null;
}

String _play(String package) =>
    'https://play.google.com/store/apps/details?id=$package';

/// Keyed by the card id used across the UI (see `_serviceIcon`, the card
/// switch in main.dart, [knownAptServices] and [knownSystemdServices]).
final Map<String, ServiceLinks> serviceLinks = {
  'evcc': ServiceLinks(
    website: 'https://evcc.io',
    appPackage: 'io.evcc.android',
    appUrl: _play('io.evcc.android'),
  ),
  'pihole': const ServiceLinks(website: 'https://pi-hole.net'),
  'homeassistant': ServiceLinks(
    website: 'https://www.home-assistant.io',
    appPackage: 'io.homeassistant.companion.android',
    appUrl: _play('io.homeassistant.companion.android'),
  ),
  'grafana': const ServiceLinks(website: 'https://grafana.com'),
  'influxdb': const ServiceLinks(website: 'https://www.influxdata.com'),
  'mosquitto': const ServiceLinks(website: 'https://mosquitto.org'),
  'adguard':
      const ServiceLinks(website: 'https://adguard.com/adguard-home.html'),
  'nodered': const ServiceLinks(website: 'https://nodered.org'),
  'zigbee2mqtt': const ServiceLinks(website: 'https://www.zigbee2mqtt.io'),
  'tailscale': ServiceLinks(
    website: 'https://tailscale.com',
    appPackage: 'com.tailscale.ipn',
    appUrl: _play('com.tailscale.ipn'),
  ),
  'piconnect': const ServiceLinks(
      website: 'https://www.raspberrypi.com/software/connect/'),
};

/// Links for [serviceId], or null when the app has none on file for it (the
/// System card is the Pi itself, not an application).
ServiceLinks? linksFor(String serviceId) => serviceLinks[serviceId];
