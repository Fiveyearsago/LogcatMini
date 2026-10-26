package com.songran.logcatmini.automationfixture;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.*;

/** Offline release fixture. It neither requests permissions nor contacts a backend. */
public final class MainActivity extends Activity {
    private LinearLayout root;
    @Override public void onCreate(Bundle state) { super.onCreate(state); home(); }
    private void page(String title) {
        root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(32, 96, 32, 32); setContentView(root);
        TextView heading = text(title, R.id.home_title); heading.setTextSize(24);
        text("独立演示应用 · Release · 无网络权限", View.NO_ID);
    }
    private TextView text(String value, int id) {
        TextView view = new TextView(this); view.setId(id); view.setText(value);
        view.setTextSize(18); view.setPadding(0, 16, 0, 16);
        root.addView(view); return view;
    }
    private void button(String title, int id, View.OnClickListener listener) {
        Button view = new Button(this); view.setId(id); view.setText(title);
        view.setOnClickListener(listener); root.addView(view);
    }
    private void home() {
        page("自动化测试首页");
        button("打开设置", R.id.settings_button, view -> settings());
        EditText input = new EditText(this); input.setId(R.id.name_input);
        input.setHint("输入测试名称"); input.setSingleLine(true); root.addView(input);
        TextView result = text("尚未保存", R.id.result_text);
        button("保存名称", R.id.save_button, view -> {
            String name = input.getText().toString();
            result.setText(name.isEmpty() ? "名称不能为空" : "已保存：" + name);
            Log.i("QA.Fixture", "event=name_saved empty=" + name.isEmpty());
        });
        Log.i("QA.Fixture", "event=home_shown");
    }
    private void settings() {
        page("语言设置");
        TextView value = text(getPreferences(0).getString("language", "简体中文"), R.id.language_value);
        button("English", R.id.english_button, view -> {
            getPreferences(0).edit().putString("language", "English").commit();
            value.setText("English"); Log.i("QA.Fixture", "event=settings_saved language=en");
        });
        button("简体中文", R.id.chinese_button, view -> {
            getPreferences(0).edit().putString("language", "简体中文").commit();
            value.setText("简体中文"); Log.i("QA.Fixture", "event=settings_saved language=zh");
        });
        button("返回首页", R.id.back_button, view -> home());
    }
    @Override public void onBackPressed() { home(); }
}
