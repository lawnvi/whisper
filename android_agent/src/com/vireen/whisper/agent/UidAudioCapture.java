package com.vireen.whisper.agent;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.audio.AudioCapture;
import com.genymobile.scrcpy.audio.AudioCaptureException;
import com.genymobile.scrcpy.audio.AudioConfig;
import com.genymobile.scrcpy.audio.AudioRecordReader;
import com.genymobile.scrcpy.util.Ln;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.os.Build;

import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/**
 * Captures one app's playback through an audio policy matching its uid.
 * The mix loops back without rendering, so the streamed app falls silent on
 * the phone while everything else keeps playing there.
 */
final class UidAudioCapture implements AudioCapture {

    private final int uid;
    private Object policy;
    private AudioRecord recorder;
    private AudioRecordReader reader;

    UidAudioCapture(int uid) {
        this.uid = uid;
    }

    static boolean isSupported() {
        return Build.VERSION.SDK_INT >= 33;
    }

    @Override
    public void checkCompatibility() throws AudioCaptureException {
        if (!isSupported()) {
            throw new AudioCaptureException();
        }
    }

    @Override
    public void start() throws AudioCaptureException {
        try {
            Class<?> ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule");
            Class<?> ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
            Object ruleBuilder = ruleBuilderClass.getConstructor().newInstance();
            ruleBuilderClass.getMethod("setTargetMixRole", int.class)
                    .invoke(ruleBuilder, ruleClass.getField("MIX_ROLE_PLAYERS").getInt(null));
            ruleBuilderClass.getMethod("addMixRule", int.class, Object.class)
                    .invoke(ruleBuilder, ruleClass.getField("RULE_MATCH_UID").getInt(null), uid);
            Object rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder);

            Class<?> mixClass = Class.forName("android.media.audiopolicy.AudioMix");
            Class<?> mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix$Builder");
            Object mixBuilder = mixBuilderClass.getConstructor(ruleClass).newInstance(rule);
            mixBuilderClass.getMethod("setFormat", AudioFormat.class).invoke(mixBuilder, AudioConfig.createAudioFormat());
            mixBuilderClass.getMethod("setRouteFlags", int.class)
                    .invoke(mixBuilder, mixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null));
            Object mix = mixBuilderClass.getMethod("build").invoke(mixBuilder);

            Class<?> policyClass = Class.forName("android.media.audiopolicy.AudioPolicy");
            Class<?> policyBuilderClass = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");
            Object policyBuilder = policyBuilderClass.getConstructor(Context.class).newInstance(FakeContext.get());
            policyBuilderClass.getMethod("addMix", mixClass).invoke(policyBuilder, mix);
            Object built = policyBuilderClass.getMethod("build").invoke(policyBuilder);

            Method register = AudioManager.class.getDeclaredMethod("registerAudioPolicyStatic", policyClass);
            register.setAccessible(true);
            int result = (int) register.invoke(null, built);
            if (result != 0) {
                throw new IllegalStateException("registerAudioPolicy returned " + result);
            }
            policy = built;
            recorder = (AudioRecord) policyClass.getMethod("createAudioRecordSink", mixClass).invoke(built, mix);
            recorder.startRecording();
            reader = new AudioRecordReader(recorder);
        } catch (Exception e) {
            Ln.e("per-app audio capture failed", e);
            stop();
            throw new AudioCaptureException();
        }
    }

    @Override
    public void stop() {
        if (recorder != null) {
            try {
                recorder.stop();
            } catch (IllegalStateException e) {
                // ignore
            }
            recorder.release();
            recorder = null;
        }
        if (policy != null) {
            try {
                Method unregister = AudioManager.class.getDeclaredMethod("unregisterAudioPolicyAsyncStatic", policy.getClass());
                unregister.setAccessible(true);
                unregister.invoke(null, policy);
            } catch (Exception e) {
                Ln.w("could not unregister the audio policy: " + e);
            }
            policy = null;
        }
    }

    @Override
    public int read(ByteBuffer outDirectBuffer, MediaCodec.BufferInfo outBufferInfo) {
        return reader.read(outDirectBuffer, outBufferInfo);
    }
}
