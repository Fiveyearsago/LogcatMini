using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LogcatMini.Core;
namespace LogcatMini.Desktop;
public sealed partial class MainWindow
{
    void SwitchDevice(string serial)
    {
        if(activeSerial==serial)return;
        Drain();StopCapture();deviceLoad?.Cancel();
        if(activeSerial.Length>0){sessions[activeSerial]=buffer;prefs.DevicePackages[activeSerial]=prefs.Package;}
        string previous=activeSerial;activeSerial=serial;
        buffer=sessions.GetValueOrDefault(serial)??new LogBuffer();
        prefs.Package=prefs.DevicePackages.GetValueOrDefault(serial)??(previous.Length==0&&prefs.Serial==serial?prefs.Package:"");
        paused=false;frozen=null;packages=[];metadata=[];logs.Clear();CloseDetail();Refilter();RefreshAppList();
    }
    void LocateAdb(){var path=AdbClient.Locate(prefs.AdbPath);adb=path is null?null:new(path);SetStatus(path is null?"请选择 adb.exe；可从 Android 官方 platform-tools 获取":"ADB 已就绪 · 本地采集 · 无需登录");}
    async Task ChooseAdb()
    {
        var files=await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions{Title="选择 Android platform-tools 中的 adb.exe",AllowMultiple=false});if(files.Count==0)return;
        prefs.AdbPath=files[0].TryGetLocalPath();Save();StopCapture();LocateAdb();await RefreshDevices();
    }
    async Task RefreshDevices(bool manual=true)
    {
        if(adb is null||refreshing)return;refreshing=true;string previous=(devices.SelectedItem as AndroidDevice)?.Serial??prefs.Serial;
        try{var list=AndroidDevice.Parse(await adb.Run(["devices","-l"]));if(closing)return;if(!manual&&devices.ItemsSource is IEnumerable<AndroidDevice> current&&current.SequenceEqual(list))return;devices.ItemsSource=list;devices.SelectedItem=list.FirstOrDefault(d=>d.Serial==previous)??list.FirstOrDefault(d=>d.Ready)??list.FirstOrDefault();if(list.Count==0){StopCapture();SetStatus("未检测到设备：连接 USB 并开启 USB 调试");}else if(devices.SelectedItem is AndroidDevice {Ready:false} d)SetStatus(d.State=="unauthorized"?"请在手机上允许 USB 调试授权":"设备离线，请重新连接");}
        catch(Exception e){SetStatus("设备读取失败："+e.Message);}finally{refreshing=false;}
        SwitchDevice((devices.SelectedItem as AndroidDevice)?.Serial??"");
        if(devices.SelectedItem is AndroidDevice {Ready:true})await LoadPackages();else{StopCapture();packages=[];RefreshAppList();}
    }
    async Task LoadPackages()
    {
        if(adb is null||devices.SelectedItem is not AndroidDevice {Ready:true} device)return;
        deviceLoad?.Cancel();var tokenSource=deviceLoad=new();var token=tokenSource.Token;SwitchDevice(device.Serial);prefs.Serial=device.Serial;Save();metadata=metadataService.Load(device.Serial);
        try
        {
            var args=systemApps.IsChecked==true?new[]{"shell","pm","list","packages","-U"}:new[]{"shell","pm","list","packages","-3","-U"};
            var result=AndroidPackage.Parse(await adb.Device(device.Serial,args,token));if(token.IsCancellationRequested)return;packages=result;RefreshAppList();SetStatus($"已连接 {device.Name} · {packages.Count} 个应用");
            // Read metadata only for favorites; no APK needs to be pulled to this computer.
            var favorites=prefs.Favorites.Intersect(packages.Select(p=>p.Id)).ToArray();if(favorites.Length>0){var fresh=await metadataService.Refresh(adb,device.Serial,favorites,token);if(token.IsCancellationRequested)return;metadata=fresh;RefreshAppList();}
        }
        catch(Exception e){if(!token.IsCancellationRequested)SetStatus("应用读取失败："+e.Message);}
    }
    void RefreshAppList()
    {
        bool old=initializing;initializing=true;string q=appQuery.Text??"";
        var all=packages.Select(p=>new AppItem(p.Id,metadata.GetValueOrDefault(p.Id)?.Label??p.ShortName,prefs.Favorites.Contains(p.Id),true,metadata.GetValueOrDefault(p.Id)?.IconPNG)).ToList();
        foreach(var id in prefs.Favorites.Except(packages.Select(p=>p.Id)))all.Add(new(id,metadata.GetValueOrDefault(id)?.Label??id,true,false,metadata.GetValueOrDefault(id)?.IconPNG));
        var sorted=all.Where(a=>a.Id.Contains(q,StringComparison.OrdinalIgnoreCase)||a.Title.Contains(q,StringComparison.OrdinalIgnoreCase)).OrderBy(a=>a.Title,StringComparer.OrdinalIgnoreCase).ToArray();var items=new List<AppItem>();foreach(bool favorite in new[]{true,false}){var group=sorted.Where(a=>a.Favorite==favorite).ToArray();if(group.Length==0)continue;items.Add(new(favorite?"$favorites":"$other",favorite?$"★ 收藏夹 · {group.Length}":"其他应用",false,false,null));items.AddRange(group);}appList.ItemsSource=items;appList.SelectedItem=items.FirstOrDefault(a=>a.Id==prefs.Package);initializing=old;
    }
    void SelectPackage(string id)
    {
        if(prefs.Package==id)return;bool resume=running;StopCapture();prefs.Package=id;prefs.DevicePackages[activeSerial]=id;Save();Clear();RefreshAppList();UpdateLabels();if(resume)ToggleCapture();
    }
    async void ToggleFavorite(string id)
    {
        bool added=prefs.Favorites.Add(id);if(!added)prefs.Favorites.Remove(id);Save();RefreshAppList();
        if(added&&adb is not null&&devices.SelectedItem is AndroidDevice {Ready:true} d)
        {
            var serial=d.Serial;try{var cache=await metadataService.Refresh(adb,serial,[id],CancellationToken.None);if((devices.SelectedItem as AndroidDevice)?.Serial==serial){metadata=cache;RefreshAppList();}}catch(Exception e){SetStatus("已收藏包名，名称和图标暂未读取："+e.Message);}
        }
    }
    void StopCapture(){capture?.Cancel();Drain();captureGeneration++;capture=null;running=false;UpdateLabels();}
    async void ToggleCapture()
    {
        if(running){StopCapture();SetStatus("采集已停止，日志保留到退出本次会话");return;}
        if(adb is null){await ChooseAdb();return;}
        if(devices.SelectedItem is not AndroidDevice {Ready:true} device){SetStatus("请连接并授权一台 Android 设备");return;}
        var package=prefs.Package.Length==0?null:packages.FirstOrDefault(p=>p.Id==prefs.Package);if(prefs.Package.Length>0&&package is null){SetStatus("当前设备未找到选中的应用，请刷新应用列表");return;}
        var client=adb;var source=capture=new CancellationTokenSource();int generation=++captureGeneration;running=true;follow=true;UpdateLabels();SetStatus("LIVE · "+(metadata.GetValueOrDefault(prefs.Package)?.Label??(prefs.Package.Length==0?device.Name:prefs.Package)));
        try{await Task.Run(()=>client.Capture(device.Serial,package?.Uid,line=>{try{var record=LogParser.Parse(line,Interlocked.Increment(ref nextId));if(record is not null&&generation==Volatile.Read(ref captureGeneration))pending.Enqueue((generation,record));}catch(System.Text.RegularExpressions.RegexMatchTimeoutException){}},source.Token));}
        catch(Exception e){if(!source.IsCancellationRequested&&!closing)SetStatus("日志连接中断："+e.Message);}
        finally{if(generation==captureGeneration){running=false;capture=null;UpdateLabels();}source.Dispose();}
    }
    void LoadDemo()
    {
        // Explicit QA mode, using synthetic data only.
        devices.ItemsSource=new[]{new AndroidDevice("preview-device","Android 演示设备","device")};devices.SelectedIndex=0;
        metadata["com.example.demo"]=new("com.example.demo","示例应用",null,0);packages=[new("com.example.demo","10123")];RefreshAppList();
        string[] payloads=["request headers trace_id=preview-001 http_code=200 https://example.com/api/v1/config", "loadConfigValue interval = 0", "result_part=1/2 result={\"status\":\"ok\",\"data\":{\"items\":[", "result_part=2/2 result={\"id\":12345678901234567890,\"name\":\"Windows 预览\",\"enabled\":true}],\"count\":1}}", "request failed reason=timeout retry=false https://example.com/api/v1/config", "long_message="+string.Join(" ",Enumerable.Range(1,75).Select(n=>$"segment_{n:00}=value_{n:00}"))];
        follow=false;
        for(int i=0;i<90;i++){string p=payloads[i%payloads.Length];var l=i%6==4?'E':i%6==0?'I':'D';var line=$"2026-10-13 12:00:{i/6:00}.100 12345 12346 {l} Demo.Network: {p}";buffer.Append(new[]{LogParser.Parse(line,++nextId)!});}Refilter();logScroll.Offset=default;UpdateLabels();SetStatus("演示模式 · 合成日志，用于界面验证");
    }
}
