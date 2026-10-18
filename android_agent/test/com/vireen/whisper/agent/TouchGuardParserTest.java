package com.vireen.whisper.agent;

import java.util.List;

/** Host test with lines as a OnePlus 8 (Android 13) printed them. */
public final class TouchGuardParserTest {
    private static final String STUCK_SINK =
            "      12: name='32e22fa ActivityRecordInputSink com.phoenix.read/com.dragon.read.pages.main.MainFragmentActivity', "
                    + "id=118855, displayId=0, inputConfig=NO_INPUT_CHANNEL | NOT_FOCUSABLE, alpha=1.00, frame=[0,0][0,0]";
    private static final String HIDDEN_SINK =
            "      11: name='2f8bd92 ActivityRecordInputSink com.vireen.whisper/.MainActivity', id=127295, displayId=0, "
                    + "inputConfig=NO_INPUT_CHANNEL | NOT_VISIBLE | NOT_FOCUSABLE | NOT_TOUCHABLE, alpha=1.00";
    private static final String ACTIVITIES = String.join("\n",
            "  * Task{84fab60 #18655 type=standard A=10435:com.vireen.whisper U=0 visible=false visibleRequested=false mode=fullscreen translucent=true sz=1}",
            "    * Hist  #0: ActivityRecord{921771d u0 com.vireen.whisper/.MainActivity} t18655}",
            "      mVisibleRequested=false mVisible=false mClientVisible=false reportedDrawn=false reportedVisible=false",
            "  * Task{7c5b826 #17685 type=standard A=10300:com.phoenix.read U=0 visible=false visibleRequested=false mode=fullscreen translucent=true sz=2}",
            "    * Hist  #1: ActivityRecord{fb937b3 u0 com.phoenix.read/com.dragon.read.component.shortvideo.impl.ShortSeriesActivity} t17685}",
            "      mVisibleRequested=false mVisible=false mClientVisible=false reportedDrawn=false reportedVisible=false",
            "    * Hist  #0: ActivityRecord{a70f125 u0 com.phoenix.read/com.dragon.read.pages.main.MainFragmentActivity} t17685}",
            "      mVisibleRequested=false mVisible=true mClientVisible=false reportedDrawn=false reportedVisible=false");

    public static void main(String[] args) {
        List<TouchGuardParser.Blocked> blocked =
                TouchGuardParser.parse(HIDDEN_SINK + "\n" + STUCK_SINK, ACTIVITIES);
        check(blocked.size() == 1, "one blocked app");
        check(blocked.get(0).taskId == 17685, "its task");
        check(blocked.get(0).appId.equals("com.phoenix.read"), "its package");

        // A sink that does not take touches is harmless.
        check(TouchGuardParser.parse(HIDDEN_SINK, ACTIVITIES).isEmpty(), "hidden sink");
        // A visible task's own sink sits under its windows: not stuck.
        String visible = ACTIVITIES.replace("#17685 type=standard A=10300:com.phoenix.read U=0 visible=false",
                "#17685 type=standard A=10300:com.phoenix.read U=0 visible=true");
        check(TouchGuardParser.parse(STUCK_SINK, visible).isEmpty(), "visible task");
        // Consistent visibility flags: not stuck.
        String fine = ACTIVITIES.replace("mVisibleRequested=false mVisible=true", "mVisibleRequested=false mVisible=false");
        check(TouchGuardParser.parse(STUCK_SINK, fine).isEmpty(), "consistent flags");
        System.out.println("TouchGuardParserTest: 4 checks passed");
    }

    private static void check(boolean condition, String what) {
        if (!condition) {
            throw new AssertionError(what);
        }
    }
}
