package com.songran.logcatmini;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Method;
import org.json.JSONArray;
import org.json.JSONObject;

/** Short-lived ADB shell helper. Reads package resources; never installs or launches apps. */
public final class AppMetadata {
    public static void main(String[] packages) throws Exception {
        if (Looper.myLooper() == null) Looper.prepareMainLooper();
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Method systemMain = activityThread.getDeclaredMethod("systemMain");
        systemMain.setAccessible(true);
        Object thread = systemMain.invoke(null);
        Method getSystemContext = activityThread.getDeclaredMethod("getSystemContext");
        getSystemContext.setAccessible(true);
        Context systemContext = (Context) getSystemContext.invoke(thread);
        // Use the actual ADB shell identity, including on OEM icon loaders that read Settings.
        Context context = systemContext.createPackageContext("com.android.shell", 0);
        PackageManager manager = context.getPackageManager();
        JSONArray apps = new JSONArray();
        for (String packageName : packages) {
            if (!packageName.matches("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)*")) continue;
            JSONObject item = new JSONObject();
            item.put("packageName", packageName);
            try {
                ApplicationInfo info = manager.getApplicationInfo(packageName, 0);
                CharSequence label = info.loadLabel(manager);
                item.put("label", label == null ? packageName : label.toString());
                PackageInfo packageInfo = manager.getPackageInfo(packageName, 0);
                item.put("lastUpdateTime", packageInfo.lastUpdateTime);
                try {
                    Drawable icon = info.loadIcon(manager);
                    if (icon != null) {
                        Bitmap bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888);
                        icon.setBounds(0, 0, 96, 96);
                        icon.draw(new Canvas(bitmap));
                        ByteArrayOutputStream png = new ByteArrayOutputStream();
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
                        bitmap.recycle();
                        item.put("iconPNG", Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP));
                    }
                } catch (Throwable error) {
                    item.put("iconError", error.getClass().getSimpleName());
                }
            } catch (Throwable error) {
                item.put("error", error.getClass().getSimpleName());
            }
            apps.put(item);
        }
        JSONObject result = new JSONObject();
        result.put("schema", 1);
        result.put("apps", apps);
        System.out.println("LOGCAT_MINI_METADATA:" + result.toString());
        System.exit(0);
    }
}
