package com.songran.logcatmini.deviceinfo;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import com.google.android.gms.ads.identifier.AdvertisingIdClient;
import com.google.android.gms.common.GooglePlayServicesNotAvailableException;
import com.google.android.gms.common.GooglePlayServicesRepairableException;
import org.json.JSONObject;

/** Runs only when the authorized ADB client requests it. No activity, storage or Internet permission. */
public final class DeviceInfoReader extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    @Override public void onStart() {
        JSONObject result = new JSONObject();
        try {
            Context context = getTargetContext();
            result.put("schema", 1);
            result.put("permissionGranted", context.checkSelfPermission("com.google.android.gms.permission.AD_ID") == 0);
            // Instrumentation's worker thread is separate from Android's main looper.
            AdvertisingIdClient.Info info = AdvertisingIdClient.getAdvertisingIdInfo(context);
            String id = info.getId();
            result.put("gaid", id == null ? JSONObject.NULL : id);
            result.put("limitAdTracking", info.isLimitAdTrackingEnabled());
            result.put("status", id == null || id.isEmpty() ? "unavailable" :
                id.equals("00000000-0000-0000-0000-000000000000") ? "zero" : "available");
        } catch (GooglePlayServicesNotAvailableException error) {
            putError(result, "missing_play_services", error);
        } catch (GooglePlayServicesRepairableException error) {
            putError(result, "repair_play_services", error);
        } catch (Exception error) {
            putError(result, "error", error);
        }
        Bundle output = new Bundle();
        output.putString("logcatMiniInfo", result.toString());
        finish(-1, output);
    }

    private static void putError(JSONObject result, String status, Exception error) {
        try {
            result.put("schema", 1);
            result.put("status", status);
            result.put("error", error.getClass().getSimpleName());
        } catch (Exception ignored) { }
    }
}
