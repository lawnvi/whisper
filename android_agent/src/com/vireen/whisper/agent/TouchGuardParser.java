package com.vireen.whisper.agent;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Pure parsing for {@link TouchGuard}, testable on the host. */
final class TouchGuardParser {

    /** An app whose leftover sink blocks touches on display 0. */
    static final class Blocked {
        final int taskId;
        final String appId;

        Blocked(int taskId, String appId) {
            this.taskId = taskId;
            this.appId = appId;
        }
    }

    private static final Pattern SINK = Pattern.compile(
            "ActivityRecordInputSink ([\\w.]+)/([\\w.$]+)'.*?displayId=0, inputConfig=([^,]*)");
    private static final Pattern TASK = Pattern.compile("\\* Task\\{\\w+ #(\\d+) .*?visible=(true|false)");
    private static final Pattern ACTIVITY = Pattern.compile("ActivityRecord\\{\\w+ u0 ([\\w.]+)/([\\w.$]+)\\}");

    private TouchGuardParser() {
    }

    /**
     * [inputDump] is `dumpsys input`, [activitiesDump] `dumpsys activity
     * activities`. Reports an app only when both agree: its sink on display 0
     * takes touches, and the activity is in an invisible task while still
     * marked visible without being asked to be.
     */
    static List<Blocked> parse(String inputDump, String activitiesDump) {
        List<String> sinks = new ArrayList<>();
        for (String line : inputDump.split("\n")) {
            Matcher m = SINK.matcher(line);
            if (m.find() && !m.group(3).contains("NOT_TOUCHABLE") && !m.group(3).contains("NOT_VISIBLE")) {
                sinks.add(m.group(1) + "/" + normalize(m.group(1), m.group(2)));
            }
        }
        List<Blocked> blocked = new ArrayList<>();
        if (sinks.isEmpty()) {
            return blocked;
        }
        String taskId = null;
        boolean taskVisible = true;
        String component = null;
        for (String line : activitiesDump.split("\n")) {
            Matcher task = TASK.matcher(line);
            if (task.find()) {
                taskId = task.group(1);
                taskVisible = "true".equals(task.group(2));
                component = null;
                continue;
            }
            Matcher activity = ACTIVITY.matcher(line);
            if (line.contains("* Hist") && activity.find()) {
                component = activity.group(1) + "/" + normalize(activity.group(1), activity.group(2));
                continue;
            }
            if (component != null && taskId != null && !taskVisible
                    && line.contains("mVisibleRequested=false mVisible=true") && sinks.contains(component)) {
                blocked.add(new Blocked(Integer.parseInt(taskId), component.substring(0, component.indexOf('/'))));
                sinks.remove(component);
                component = null;
            }
        }
        return blocked;
    }

    private static String normalize(String pkg, String cls) {
        return cls.startsWith(".") ? pkg + cls : cls;
    }
}
