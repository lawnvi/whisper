package com.vireen.whisper.agent;

/** Host-side test for {@link Shell}; run by script/build_window_agent.sh. */
public final class ShellTest {

    public static void main(String... args) {
        // Bug: am's arguments (another app's activity name, a request's app
        // id) went through sh -c, so a name like "A;reboot" ran as shell.
        String name = "com.evil/.A;echo${IFS}injected|sh;$(id)`id`'\"";
        String out = Shell.exec("echo", name);
        if (!out.equals(name + "\n")) {
            throw new AssertionError("argument reached a shell: " + out);
        }
        System.out.println("ShellTest: 1 passed");
    }
}
