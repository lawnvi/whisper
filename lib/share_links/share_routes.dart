import 'dart:math';

/// Why a route someone typed cannot be used.
enum ShareRouteProblem { invalid, reserved, taken }

/// Raised by [ShareLinkStore.create] for a route that cannot be used.
class ShareRouteException implements Exception {
  const ShareRouteException(this.problem, this.route);

  final ShareRouteProblem problem;
  final String route;

  @override
  String toString() => 'ShareRouteException(${problem.name}, $route)';
}

/// The path part of a share link: `http://host:port/<route>`.
abstract final class ShareRoutes {
  /// Lowercase letters and digits without the ones that are easy to mix
  /// up when read out or written down: 0/o, 1/l/i.
  static const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

  static const defaultLength = 8;
  static const shortLength = 4;
  static const minLength = 2;
  static const maxLength = 32;

  /// Words the server uses itself or that would read as part of the site
  /// rather than a link. Single letters and names with dots never pass the
  /// pattern anyway (`f`, `favicon.ico`, `robots.txt`).
  static const reserved = <String>{
    'f',
    'd',
    's',
    'zip',
    'login',
    'logout',
    'assets',
    'static',
    'api',
    'admin',
    'index',
    'favicon',
    'robots',
    'well-known',
    'apple-touch-icon',
    'whisper',
    'share',
    'shares',
    'help',
  };

  static final _pattern = RegExp(r'^[a-z0-9_-]+$');

  /// What a typed route is stored as: trimmed and lowercase.
  static String normalize(String route) => route.trim().toLowerCase();

  /// Null when [route] (already [normalize]d) may be used, apart from
  /// being taken by another link.
  static ShareRouteProblem? check(String route) {
    if (route.length < minLength ||
        route.length > maxLength ||
        !_pattern.hasMatch(route)) {
      return ShareRouteProblem.invalid;
    }
    if (reserved.contains(route)) {
      return ShareRouteProblem.reserved;
    }
    return null;
  }

  /// A fresh random route that is not in [taken].
  static String generate({
    bool short = false,
    Set<String> taken = const {},
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    final length = short ? shortLength : defaultLength;
    for (var attempt = 0; attempt < 10000; attempt++) {
      final buffer = StringBuffer();
      for (var i = 0; i < length; i++) {
        buffer.write(alphabet[rng.nextInt(alphabet.length)]);
      }
      final route = buffer.toString();
      if (!taken.contains(route) && !reserved.contains(route)) {
        return route;
      }
    }
    // Practically unreachable (31^4 short routes); a longer one is free.
    return generate(taken: taken, random: rng);
  }
}
