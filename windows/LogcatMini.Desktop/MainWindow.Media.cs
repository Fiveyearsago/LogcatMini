using System.Diagnostics;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LogcatMini.Core;
namespace LogcatMini.Desktop;

public sealed partial class MainWindow
{
    readonly MediaLibrary media=MediaLibrary.Load();
    readonly Button screenshotCopyButton=new(),screenshotButton=new(),recordButton=new(),cancelRetryButton=new();
    readonly TextBlock recordingDevice=new(){MaxWidth=190,TextTrimming=TextTrimming.CharacterEllipsis,VerticalAlignment=VerticalAlignment.Center};
    ScreenRecording? recorder;
    AndroidDevice? recordedDevice;
    string? recordingDestination;
    Task? screenshotTask,recordingTask;
    bool takingScreenshot,savingRecording,closeInProgress;
    readonly DispatcherTimer mediaTimer=new(){Interval=TimeSpan.FromSeconds(1)};
    Window? settingsWindow,historyWindow;
    Control BuildMediaControls()
    {
        Setup(screenshotCopyButton,"截图并复制",()=>screenshotTask=TakeScreenshot(true));Setup(screenshotButton,"截图",()=>screenshotTask=TakeScreenshot());Setup(recordButton,"录屏",()=>_=ToggleRecording());Setup(cancelRetryButton,"取消重试",()=>{if(recorder is {} session&&recordingTask?.IsCompleted==true){session.LeaveTemporaryFile();recorder=null;SetStatus("临时录屏已保留："+session.TemporaryMovie);UpdateMediaLabels();}});
        mediaTimer.Tick+=(_,_)=>UpdateMediaLabels();mediaTimer.Start();
        return Wrap(screenshotButton,screenshotCopyButton,recordButton,cancelRetryButton,recordingDevice,IconButton("history","媒体历史",OpenMediaHistory,shortcut:"Ctrl+Shift+H"));
    }
    void UpdateMediaLabels()
    {
        Symbol.Set(screenshotButton,"camera",takingScreenshot?"截图中…":"截图",shortcut:"Ctrl+Alt+S");screenshotButton.IsEnabled=!takingScreenshot&&adb is not null&&devices.SelectedItem is AndroidDevice{Ready:true};
        Symbol.Set(screenshotCopyButton,"copy","截图并复制",shortcut:"Ctrl+Shift+C");screenshotCopyButton.IsEnabled=screenshotButton.IsEnabled;
        bool active=recorder is not null;cancelRetryButton.IsVisible=active&&recordingTask?.IsCompleted==true&&!savingRecording;
        var elapsed=active?DateTime.Now-recorder!.StartedAt:TimeSpan.Zero;
        Symbol.Set(recordButton,active?"stop":"record",savingRecording?"保存录屏…":active?(recordingTask?.IsCompleted==true?"重试保存录屏":$"停止录屏 {elapsed:mm\\:ss}"):"录屏",shortcut:"Ctrl+Shift+R");
        recordButton.IsEnabled=!savingRecording&&(active||adb is not null&&devices.SelectedItem is AndroidDevice{Ready:true});
        recordingDevice.Text=active?recordedDevice?.Name:"";ToolTip.SetTip(recordingDevice,recordedDevice?.ToString());
    }
    async Task<string?> ChooseDirectory(string kind,bool force=false,Window? owner=null)
    {
        if(!force&&media.DirectoryFor(kind) is {} saved)return saved;
        var provider=(owner??this).StorageProvider;
        var folders=await provider.OpenFolderPickerAsync(new FolderPickerOpenOptions{Title=kind=="screenshot"?"选择截图保存文件夹":"选择录屏保存文件夹",AllowMultiple=false});
        if(folders.Count==0)return null;var path=folders[0].TryGetLocalPath()??throw new IOException("请选择本机文件夹");
        media.SetDirectory(kind,path);return path;
    }
    async Task TakeScreenshot(bool copy=false)
    {
        if(takingScreenshot||adb is null||devices.SelectedItem is not AndroidDevice{Ready:true} device)return;
        var client=adb;takingScreenshot=true;UpdateMediaLabels();
        try
        {
            if(copy){if(Clipboard is null)throw new IOException("剪贴板不可用");await ScreenshotClipboard.Copy(Clipboard,await DeviceCapture.ScreenshotData(client,device.Serial));SetStatus("截图已复制，可直接粘贴到聊天窗口");return;}
            if(await ChooseDirectory("screenshot") is null)return;var destination=media.Destination("screenshot",device);var created=DateTime.Now;
            await DeviceCapture.Screenshot(client,device.Serial,destination);media.Add(new(destination,"screenshot",device.Name,device.Serial,created));SetStatus("截图已保存："+destination);
        }
        catch(Exception e){SetStatus("截图失败："+e.Message);}
        finally{takingScreenshot=false;UpdateMediaLabels();}
    }
    async Task ToggleRecording()
    {
        if(savingRecording)return;
        if(recorder is not null)
        {
            if(recordingTask?.IsCompleted==true)
            {
                try{if(await ChooseDirectory("recording",true) is null)return;recordingDestination=media.Destination("recording",recordedDevice!);recordingTask=FinishRecording(recorder);await recordingTask;}catch(Exception e){SetStatus(e.Message);}
            }
            else
            {
                savingRecording=true;UpdateMediaLabels();
                try{await recorder.Stop();}catch(Exception e){savingRecording=false;SetStatus("停止录屏失败："+e.Message);UpdateMediaLabels();}
            }
            return;
        }
        if(adb is null||devices.SelectedItem is not AndroidDevice{Ready:true} device)return;
        try
        {
            var runtime=ScreenRecording.Locate(prefs.RecorderPath);
            if(runtime is null){SetStatus("请在设置中选择 scrcpy 录屏组件");OpenSettings();return;}
            if(await ChooseDirectory("recording") is null)return;
            recordingDestination=media.Destination("recording",device);recordedDevice=device;recorder=new(adb.Path,device.Serial,runtime);UpdateMediaLabels();
            recordingTask=FinishRecording(recorder);
        }
        catch(Exception e){recorder=null;SetStatus("录屏启动失败："+e.Message);UpdateMediaLabels();}
    }
    async Task FinishRecording(ScreenRecording session)
    {
        try
        {
            await session.SaveWhenFinished(recordingDestination!);
            recorder=null;
            media.Add(new(recordingDestination!,"recording",recordedDevice!.Name,session.Serial,session.StartedAt,(DateTime.Now-session.StartedAt).TotalSeconds));
            SetStatus("录屏已保存："+recordingDestination);
        }
        catch(Exception e){SetStatus(e.Message);}
        finally{savingRecording=false;UpdateMediaLabels();}
    }
    async void OnClosing(object? sender,WindowClosingEventArgs e)
    {
        if(closing)return;
        if(takingScreenshot||recorder is not null&&recordingTask?.IsCompleted!=true)
        {
            e.Cancel=true;if(closeInProgress)return;closeInProgress=true;
            if(screenshotTask is {} shot)await shot;
            if(recorder is {} session)
            {
                try{savingRecording=true;UpdateMediaLabels();await session.Stop();if(recordingTask is {} save)await save;}
                catch(Exception error){SetStatus(error.Message);}
                if(recorder is not null){closeInProgress=false;savingRecording=false;UpdateMediaLabels();return;}
            }
            closeInProgress=false;Close();return;
        }
        closing=true;RememberFilter();SaveDimensions();capture?.Cancel();deviceLoad?.Cancel();flush.Stop();devicePoll.Stop();mediaTimer.Stop();settingsWindow?.Close();historyWindow?.Close();foreach(var bitmap in icons.Values)bitmap.Dispose();
    }
    Window Auxiliary(string title,double width,double height)=>new(){Title=title,Width=width,Height=height,MinWidth=500,MinHeight=380,Background=colors.Canvas,Foreground=colors.Text,RequestedThemeVariant=RequestedThemeVariant,WindowStartupLocation=WindowStartupLocation.CenterOwner,Icon=Icon};
    async Task ChooseRecorder(Window owner)
    {
        var files=await owner.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions{Title="选择 scrcpy 目录中的 scrcpy.exe",AllowMultiple=false});
        if(files.Count==0)return;prefs.RecorderPath=files[0].TryGetLocalPath();Save();SetStatus("录屏组件已设置");
    }
    void OpenSettings()
    {
        if(settingsWindow is {} existing){existing.Activate();return;}
        var window=settingsWindow=Auxiliary("Logcat Mini 设置",690,680);
        var content=new StackPanel{Spacing=18,Margin=new Thickness(24)};
        void Heading(string title)=>content.Children.Add(new TextBlock{Text=title,FontSize=18,FontWeight=FontWeight.SemiBold});
        Heading("外观");content.Children.Add(Horizontal(new TextBlock{Text="主题",VerticalAlignment=VerticalAlignment.Center},theme));
        content.Children.Add(Horizontal(new TextBlock{Text="日志字号",VerticalAlignment=VerticalAlignment.Center},IconButton("minus","",()=>ChangeFont(-1)),fontLabel,IconButton("plus","",()=>ChangeFont(1)),Button("恢复默认",()=>ChangeFont(0))));
        content.Children.Add(Horizontal(ColumnMenu(),Button("恢复默认显示列",()=>{prefs.Columns=["level","time","tag","pid","message"];Save();ApplyStyleToLogs();})));Heading("设备与应用");content.Children.Add(systemApps);
        var adbLabel=new TextBlock{Text=adb?.Path??"尚未配置 ADB",TextWrapping=TextWrapping.Wrap};content.Children.Add(adbLabel);
        content.Children.Add(Button("更换 ADB…",async()=>{try{await ChooseAdb();adbLabel.Text=adb?.Path??"尚未配置 ADB";}catch(Exception e){SetStatus(e.Message);}}));
        Heading("截图与录屏保存位置");
        foreach(var kind in new[]{"screenshot","recording"})
        {
            var path=new TextBlock{Text=media.DirectoryFor(kind)??"首次使用时选择",TextWrapping=TextWrapping.Wrap,MaxWidth=440};
            content.Children.Add(Horizontal(new Symbol(kind=="screenshot"?"camera":"record"),new TextBlock{Text=kind=="screenshot"?"截图":"录屏"},Button("更换…",async()=>{try{await ChooseDirectory(kind,true,window);path.Text=media.DirectoryFor(kind)??"首次使用时选择";}catch(Exception e){SetStatus(e.Message);}})));
            content.Children.Add(path);
        }
        var recorderLabel=new TextBlock{Text=ScreenRecording.Locate(prefs.RecorderPath)??"尚未配置 scrcpy 录屏组件",TextWrapping=TextWrapping.Wrap};content.Children.Add(recorderLabel);
        content.Children.Add(Button("选择录屏组件…",async()=>{try{await ChooseRecorder(window);recorderLabel.Text=ScreenRecording.Locate(prefs.RecorderPath)??"尚未配置";}catch(Exception e){SetStatus(e.Message);}}));
        content.Children.Add(new TextBlock{Text="录屏最长 3 分钟，不录音；停止或退出时自动保存。",Foreground=colors.Muted});
        window.Content=new ScrollViewer{Content=content};window.Closed+=(_,_)=>{foreach(var control in new Control[]{theme,fontLabel,systemApps})if(control.Parent is Panel parent)parent.Children.Remove(control);content.Children.Clear();settingsWindow=null;};window.Show(this);ApplyTheme();
    }
    static void OpenFile(string path)=>Process.Start(new ProcessStartInfo(path){UseShellExecute=true});
    void OpenMediaHistory()
    {
        if(historyWindow is {} existing){existing.Activate();return;}
        var window=historyWindow=Auxiliary("截图与录屏历史",1000,700);Bitmap? previewBitmap=null;IDisposable? video=null;
        var layout=new Grid{RowDefinitions=new RowDefinitions("Auto,*,Auto"),Margin=new Thickness(18)};
        var search=Input("搜索设备、文件名或路径");var type=new ComboBox{ItemsSource=new[]{"全部","截图","录屏"},SelectedIndex=0,MinWidth=95};
        var filter=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto")};At(filter,search,0);At(filter,type,0,1);At(layout,filter,0);
        var body=new Grid{ColumnDefinitions=new ColumnDefinitions("340,*"),Margin=new Thickness(0,12)};var list=new ListBox();var preview=new Image{Stretch=Stretch.Uniform};var fileLabel=new SelectableTextBlock{TextWrapping=TextWrapping.Wrap};
        var previewHost=new ContentControl{Content=preview};
        var display=new Grid{RowDefinitions=new RowDefinitions("*,Auto"),Margin=new Thickness(16,0,0,0)};At(display,previewHost,0);At(display,fileLabel,1);At(body,list,0);At(body,display,0,1);At(layout,body,1);
        var copyButton=IconButton("copy","复制图片",async()=>await CopySelected(),shortcut:"Ctrl+Alt+C");copyButton.IsEnabled=false;
        async Task CopySelected(){if(list.SelectedItem is not MediaItem{Kind:"screenshot",Exists:true} item)return;try{if(window.Clipboard is null)throw new IOException("剪贴板不可用");await ScreenshotClipboard.Copy(window.Clipboard,await File.ReadAllBytesAsync(item.Path));fileLabel.Text=item.Path+"\n图片已复制，可粘贴到聊天窗口";}catch(Exception e){fileLabel.Text="复制失败："+e.Message;}}
        window.AddHandler(KeyDownEvent,(_,e)=>{if(e.Key==Key.C&&e.KeyModifiers==(KeyModifiers.Control|KeyModifiers.Alt)){_=CopySelected();e.Handled=true;}},RoutingStrategies.Tunnel);
        void Reload(){string q=search.Text??"";list.ItemsSource=media.Items.Where(i=>(type.SelectedIndex==0||i.Kind==(type.SelectedIndex==1?"screenshot":"recording"))&&(i.Path.Contains(q,StringComparison.OrdinalIgnoreCase)||i.DeviceName.Contains(q,StringComparison.OrdinalIgnoreCase)||i.Serial.Contains(q,StringComparison.OrdinalIgnoreCase))).ToArray();}
        search.TextChanged+=(_,_)=>Reload();type.SelectionChanged+=(_,_)=>Reload();
        list.SelectionChanged+=(_,_)=>
        {
            copyButton.IsEnabled=list.SelectedItem is MediaItem{Kind:"screenshot",Exists:true};
            video?.Dispose();video=null;previewHost.Content=preview;preview.Source=null;previewBitmap?.Dispose();previewBitmap=null;if(list.SelectedItem is not MediaItem item)return;
            fileLabel.Text=item.Path+(item.Exists?item.Kind=="recording"?OperatingSystem.IsWindows()?"":"\nMac 预览使用系统视频播放器。":"":"\n文件已移动或删除，历史记录已保留。");
            if(item.Kind=="recording"&&item.Exists&&OperatingSystem.IsWindows()){var player=new WindowsVideoPreview(item.Path,message=>fileLabel.Text=item.Path+"\n"+message);video=player;previewHost.Content=player;}
            if(item.Kind=="screenshot"&&item.Exists)try{using var stream=File.OpenRead(item.Path);previewBitmap=new Bitmap(stream);preview.Source=previewBitmap;}catch(Exception e){fileLabel.Text+="\n预览失败："+e.Message;}
        };
        void OpenSelected(bool folder){if(list.SelectedItem is not MediaItem item)return;try{OpenFile(folder?Path.GetDirectoryName(item.Path)!:item.Path);}catch(Exception e){fileLabel.Text=e.Message;}}
        At(layout,Wrap(copyButton,IconButton("play","打开 / 播放",()=>OpenSelected(false)),IconButton("folder","打开文件夹",()=>OpenSelected(true)),IconButton("refresh","刷新",Reload)),2);
        list.DoubleTapped+=(_,_)=>OpenSelected(false);Reload();window.Content=layout;window.Closed+=(_,_)=>{video?.Dispose();previewBitmap?.Dispose();historyWindow=null;};window.Show(this);
    }
}
