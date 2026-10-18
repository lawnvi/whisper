package com.vireen.whisper.agent;

/** Host-side tests for {@link ProcNetParser}; run by script/build_window_agent.sh. */
public final class ProcNetParserTest {

    private static int passed;

    private static final String TCP = ""
            + "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
            + "   0: 0100007F:A2B0 0100007F:9C40 01 00000000:00000000 00:00000000 00000000 10435        0 1 1 0 20 4 30 10 -1\n"
            + "   1: 0100007F:9C40 0100007F:A2B0 01 00000000:00000000 00:00000000 00000000  2000        0 2 1 0 20 4 30 10 -1\n"
            + "   2: 0A00020F:A2B0 0100007F:9C40 01 00000000:00000000 00:00000000 00000000 10111        0 3 1 0 20 4 30 10 -1\n";

    private static final String TCP6 = ""
            + "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
            + "   0: 0000000000000000FFFF00000100007F:C350 0000000000000000FFFF00000100007F:9C40 01 00000000:00000000 00:00000000 00000000 10435        0 9 1\n";

    public static void main(String... args) {
        check(ProcNetParser.uidOf(TCP, 0xA2B0, 0x9C40) == 10435, "client end found by its ports");
        check(ProcNetParser.uidOf(TCP, 0x9C40, 0xA2B0) == 2000, "server end is the other line");
        check(ProcNetParser.uidOf(TCP, 0xA2B1, 0x9C40) == -1, "unknown port");
        check(ProcNetParser.uidOf(TCP6, 0xC350, 0x9C40) == 10435, "IPv4-mapped loopback in tcp6");
        check(ProcNetParser.uidOf(TCP.replace("0100007F:A2B0 0100007F", "0A00020F:A2B0 0100007F"), 0xA2B0, 0x9C40)
                == -1, "only loopback lines count");
        check(ProcNetParser.uidOf(null, 1, 2) == -1, "unreadable table");
        check(ProcNetParser.uidOf("garbage\n", 1, 2) == -1, "garbage");
        System.out.println("ProcNetParserTest: " + passed + " passed");
    }

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
        passed++;
    }
}
