import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'share_link_store.dart';

/// The extension names, after `ext.whisper.share.`.
const shareDebugCommands = [
  'create',
  'list',
  'setEnabled',
  'remove',
  'service',
];

bool _registered = false;

/// VM service extensions for driving share links from tests on other
/// machines (debug and profile builds only; release builds skip this).
/// Parameters are strings; lists are JSON. Every answer is JSON:
///
/// * `ext.whisper.share.create`: `paths` (JSON list), optional `route`,
///   `short` (`true`), `password`, `name` → the link
/// * `ext.whisper.share.list` → links, server state, port, addresses
/// * `ext.whisper.share.setEnabled`: `id`, `enabled` (`true`/`false`)
/// * `ext.whisper.share.remove`: `id`
/// * `ext.whisper.share.service`: optional `on` (`true`/`false`) → state
///
/// Errors come back as extension errors whose message is JSON:
/// `{"error": "route", "problem": "taken"}`, `{"error": "link", …}`,
/// `{"error": "missing", "id": …}`, `{"error": "failed", "detail": …}`.
void registerShareDebugHooks({ShareLinkStore? store}) {
  if (!kDebugMode || _registered) {
    return;
  }
  _registered = true;
  final links = store ?? ShareLinkStore.shared;
  for (final name in shareDebugCommands) {
    developer.registerExtension('ext.whisper.share.$name', (
      method,
      params,
    ) async {
      final (ok, body) = await runShareDebugCommand(links, name, params);
      return ok
          ? developer.ServiceExtensionResponse.result(jsonEncode(body))
          : developer.ServiceExtensionResponse.error(
              developer.ServiceExtensionResponse.extensionErrorMin,
              jsonEncode(body),
            );
    });
  }
}

/// One debug command: whether it worked, and the JSON-able answer.
@visibleForTesting
Future<(bool, Map<String, Object?>)> runShareDebugCommand(
  ShareLinkStore links,
  String command,
  Map<String, String> params,
) async {
  try {
    await links.initialize();
    switch (command) {
      case 'create':
        final paths = (jsonDecode(params['paths'] ?? '[]') as List)
            .cast<String>()
            .toList();
        final link = await links.create(
          paths: paths,
          route: params['route'],
          short: params['short'] == 'true',
          password: params['password'],
          name: params['name'],
        );
        return (true, _describe(links, link));
      case 'list':
        await links.refreshAddresses();
        await links.refreshAvailability();
        return (
          true,
          {
            ..._service(links),
            'links': [for (final link in links.links) _describe(links, link)],
          },
        );
      case 'setEnabled':
        final id = params['id'] ?? '';
        if (links.linkById(id) == null) {
          return (false, {'error': 'missing', 'id': id});
        }
        await links.setEnabled(id, params['enabled'] != 'false');
        return (true, _describe(links, links.linkById(id)!));
      case 'remove':
        final id = params['id'] ?? '';
        if (links.linkById(id) == null) {
          return (false, {'error': 'missing', 'id': id});
        }
        await links.remove(id);
        return (true, {'removed': id});
      case 'service':
        final on = params['on'];
        if (on != null) {
          await links.setServiceOn(on != 'false');
        }
        await links.refreshAddresses();
        return (true, _service(links));
    }
    return (false, {'error': 'unknown', 'command': command});
  } on ShareRouteException catch (error) {
    return (false, {'error': 'route', 'problem': error.problem.name});
  } on ShareLinkException catch (error) {
    return (false, {'error': 'link', 'problem': error.problem.name});
  } on Object catch (error) {
    return (false, {'error': 'failed', 'detail': '$error'});
  }
}

Map<String, Object?> _service(ShareLinkStore links) => {
  'service': links.serviceOn,
  'server': links.serverState.toJson(),
  'port': links.port,
  'addresses': links.addresses,
};

Map<String, Object?> _describe(ShareLinkStore store, ShareLink link) => {
  'id': link.id,
  'route': link.route,
  'name': link.name,
  'enabled': link.enabled,
  'password': link.hasPassword,
  'items': [
    for (final item in link.items)
      {'path': item.path, 'name': item.name, 'dir': item.isDir},
  ],
  'availability': store.availabilityOf(link).name,
  'visits': link.visits,
  'downloads': link.downloads,
  'bytes': link.bytesServed,
  'lastVisit': link.lastVisitAt?.toIso8601String(),
  'created': link.createdAt.toIso8601String(),
  'urls': [for (final address in store.addresses) store.urlFor(link, address)],
};
