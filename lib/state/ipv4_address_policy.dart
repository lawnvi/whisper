final class Ipv4AddressPolicy {
  const Ipv4AddressPolicy._();

  static List<int>? parseCanonical(String address) {
    final parts = address.split('.');
    if (parts.length != 4) {
      return null;
    }
    final octets = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) {
        return null;
      }
      final value = int.parse(part);
      if (value > 255) {
        return null;
      }
      octets.add(value);
    }
    return octets;
  }

  static bool isPrivate(String address) {
    final octets = parseCanonical(address);
    if (octets == null) return false;
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  static bool isLinkLocal(String address) {
    final octets = parseCanonical(address);
    if (octets == null) return false;
    // RFC 3927 reserves the first and last /24 within 169.254/16.
    return octets[0] == 169 &&
        octets[1] == 254 &&
        octets[2] >= 1 &&
        octets[2] <= 254;
  }

  static bool isUsableUnicast(String address) {
    final octets = parseCanonical(address);
    return octets != null && _isUsableUnicastOctets(octets);
  }

  static bool _isUsableUnicastOctets(List<int> octets) {
    final isLinkLocalReserved =
        octets[0] == 169 &&
        octets[1] == 254 &&
        (octets[2] == 0 || octets[2] == 255);
    // A subnet-directed broadcast depends on the route prefix and cannot be
    // identified from an address alone.
    return octets[0] != 0 &&
        octets[0] != 127 &&
        octets[0] < 224 &&
        !isLinkLocalReserved;
  }
}
