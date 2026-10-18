package com.vireen.whisper.agent;

/**
 * Finds who owns the client end of a loopback TCP connection in the text of
 * {@code /proc/net/tcp} or {@code /proc/net/tcp6}, which the shell user may
 * read (apps may not). Pure Java so it is tested on the host JVM.
 */
public final class ProcNetParser {

    private static final String LOOPBACK_V4 = "0100007F";
    private static final String MAPPED_V4_PREFIX = "0000000000000000FFFF0000";
    private static final String LOOPBACK_V6 = "00000000000000000000000001000000";

    private ProcNetParser() {
    }

    /**
     * The uid of the socket bound to loopback port [localPort] and connected
     * to loopback port [remotePort], or -1 when the table has no such line.
     */
    public static int uidOf(String table, int localPort, int remotePort) {
        if (table == null) {
            return -1;
        }
        for (String line : table.split("\n")) {
            String[] fields = line.trim().split("\\s+");
            // sl local rem st tx:rx tr:when retrnsmt uid ...
            if (fields.length < 8 || !fields[0].endsWith(":")) {
                continue;
            }
            if (port(fields[1], localPort) && port(fields[2], remotePort)) {
                try {
                    return Integer.parseInt(fields[7]);
                } catch (NumberFormatException e) {
                    return -1;
                }
            }
        }
        return -1;
    }

    /** Whether [address] ("HEXIP:HEXPORT") is loopback on [port]. */
    private static boolean port(String address, int port) {
        int colon = address.indexOf(':');
        if (colon < 0) {
            return false;
        }
        String ip = address.substring(0, colon).toUpperCase(java.util.Locale.ROOT);
        boolean loopback = ip.equals(LOOPBACK_V4) || ip.equals(LOOPBACK_V6)
                || (ip.length() == 32 && ip.startsWith(MAPPED_V4_PREFIX) && ip.endsWith(LOOPBACK_V4));
        if (!loopback) {
            return false;
        }
        try {
            return Integer.parseInt(address.substring(colon + 1), 16) == port;
        } catch (NumberFormatException e) {
            return false;
        }
    }
}
