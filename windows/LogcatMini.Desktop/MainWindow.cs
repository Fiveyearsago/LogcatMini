using System.Collections.Concurrent;
using System.Text;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LogcatMini.Core;
namespace LogcatMini.Desktop;
public sealed partial class MainWindow : Window
{
    readonly Preferences prefs=Preferences.Load();
    Palette colors=Palette.For("nightfall",true);
    LogBuffer buffer=new();
    readonly Dictionary<string,LogBuffer> sessions=[];
    string activeSerial="";
    readonly ConcurrentQueue<(int Generation,LogRecord Record)> pending=new();
    List<LogRecord> filtered=[];List<LogRecord>? frozen;
    List<AndroidPackage> packages=[];Dictionary<string,AppMetadata> metadata=[];
    readonly MetadataService metadataService=new(Path.Combine(Preferences.DirectoryPath,"metadata"),Path.Combine(AppContext.BaseDirectory,"AppMetadata.jar"));
    readonly Dictionary<string,Bitmap> icons=[];
    AdbClient? adb;CancellationTokenSource? capture,deviceLoad;long nextId;int captureGeneration;
    bool running,paused,follow=true,listFullscreen,detailFullscreen,detailActive,initializing=true,refreshing,closing;
    LogRecord? selected;int listMatch=-1;List<int> listHits=[];
    readonly DispatcherTimer flush=new(){Interval=TimeSpan.FromMilliseconds(200)};
    readonly DispatcherTimer devicePoll=new(){Interval=TimeSpan.FromSeconds(3)};
    readonly Grid root=new(), main=new(), listPanel=new(), detailPanel=new();
    readonly Border sidebar=new(),header=new(),footer=new();
    readonly Border filterPanel=new(){Margin=new Thickness(20,0,20,12)};
    readonly GridSplitter sidebarGrip=new(){Width=5,ResizeDirection=GridResizeDirection.Columns,HorizontalAlignment=HorizontalAlignment.Stretch},detailGrip=new(){Height=6,ResizeDirection=GridResizeDirection.Rows,HorizontalAlignment=HorizontalAlignment.Stretch};
    readonly ComboBox devices=new(){HorizontalAlignment=HorizontalAlignment.Stretch,MinWidth=160};
    readonly ListBox appList=new(){BorderThickness=new Thickness(0),Padding=new Thickness(0)};
    readonly TextBox appQuery=Input("搜索包名或收藏名称"),filterQuery=Input("过滤日志、Tag、PID；多个关键词用 | 分隔"),tagQuery=Input("Tag，支持 | 分隔"),listQuery=Input("在日志列表中查找"),detailQuery=Input("在日志详情中查找");
    readonly CheckBox systemApps=new(){Content="显示系统应用"},regex=new(){Content="正则"};
    readonly ComboBox theme=new(){ItemsSource=Palette.Names,MinWidth=110},level=new(){ItemsSource=new[]{"全部等级","Debug+","Info+","Warn+","Error+","Fatal+"},SelectedIndex=0,MinWidth=105};
    readonly TextBlock status=new(){VerticalAlignment=VerticalAlignment.Center,TextTrimming=TextTrimming.CharacterEllipsis},subtitle=new(),counter=new(),fontLabel=new(),detailTitle=new(),listCount=new(),detailCount=new();
    readonly Button start=new(),pause=new(),followButton=new(),fullButton=new(),detailFullButton=new(),jsonButton=new(),restoreButton=new();

    Border listFindBorder=new(),detailFindBorder=new();
    readonly LogCanvas logs=new(),columnHeader=new(){Header=true,Height=30};
    readonly DetailCanvas detail=new();
    readonly ScrollViewer logScroll=new(){HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Auto},detailScroll=new(){HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
    readonly List<Button> buttons=[];readonly List<TextBox> inputs=[];
    public MainWindow(string[] args)
    {
        if(File.Exists(Path.Combine(AppContext.BaseDirectory,"AppIcon.ico")))Icon=new WindowIcon(Path.Combine(AppContext.BaseDirectory,"AppIcon.ico"));
        Title="Logcat Mini · Windows";Width=1440;Height=900;MinWidth=1020;MinHeight=620;FontSize=13;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        systemApps.IsChecked=prefs.ShowSystemApps;BuildLayout();BindActions();ApplyTheme();initializing=false;
        SizeChanged+=(_,_)=>root.ColumnDefinitions[0].MaxWidth=Math.Clamp(Bounds.Width-745,240,680);
        Opened+=async(_,_)=>{if(args.Contains("--demo"))LoadDemo();else if(!args.Contains("--test")){LocateAdb();await RefreshDevices();devicePoll.Start();}};
        Closing+=OnClosing;
        flush.Tick+=(_,_)=>Drain();flush.Start();devicePoll.Tick+=async(_,_)=>await RefreshDevices(false);
        AddHandler(KeyDownEvent,Shortcuts,RoutingStrategies.Tunnel);
    }
    static TextBox Input(string placeholder)=>new(){PlaceholderText=placeholder,BorderThickness=new Thickness(0),MinHeight=34,Padding=new Thickness(10,6),VerticalContentAlignment=VerticalAlignment.Center};
    Button Button(string title,Action action,string? tip=null)
    {
        var b=new Button{Content=title,Padding=new Thickness(10,6),MinHeight=32,CornerRadius=new CornerRadius(5)};b.Click+=(_,_)=>action();if(tip is not null)ToolTip.SetTip(b,tip);buttons.Add(b);return b;
    }
    Button IconButton(string icon,string title,Action action,string? tip=null,string? shortcut=null){var b=Button(title,action,tip);b.Classes.Add("quiet");Symbol.Set(b,icon,title,shortcut:shortcut);return b;}
    void Setup(Button b,string title,Action action,string? tip=null){b.Content=title;b.Padding=new Thickness(10,6);b.MinHeight=32;b.CornerRadius=new CornerRadius(5);b.Click+=(_,_)=>action();if(tip is not null)ToolTip.SetTip(b,tip);buttons.Add(b);}
    static StackPanel Horizontal(params Control[] children){var p=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,VerticalAlignment=VerticalAlignment.Center};foreach(var c in children)p.Children.Add(c);return p;}
    static WrapPanel Wrap(params Control[] children){var p=new WrapPanel{Orientation=Orientation.Horizontal};foreach(var c in children){c.Margin=new Thickness(0,2,6,2);p.Children.Add(c);}return p;}
    static void At(Grid grid,Control control,int row,int col=0){Grid.SetRow(control,row);Grid.SetColumn(control,col);grid.Children.Add(control);}
    void BuildLayout()
    {
        root.ColumnDefinitions=new ColumnDefinitions($"{prefs.SidebarWidth},5,*");root.ColumnDefinitions[0].MinWidth=240;root.ColumnDefinitions[0].MaxWidth=680;
        root.RowDefinitions=new RowDefinitions("*");Content=root;At(root,sidebar,0);At(root,sidebarGrip,0,1);At(root,main,0,2);
        var side=new Grid{RowDefinitions=new RowDefinitions("Auto,Auto,Auto,Auto,*,Auto"),Margin=new Thickness(12)};sidebar.Child=side;
        var brand=new StackPanel{Margin=new Thickness(6,15,0,22),Spacing=6};brand.Children.Add(Horizontal(new Symbol("terminal"){Width=26,Height=26,Foreground=colors.Accent},new TextBlock{Text="Logcat Mini",FontSize=23,FontWeight=FontWeight.Bold}));brand.Children.Add(new TextBlock{Text="少一点噪声，多一点线索",Opacity=.65});At(side,brand,0);
        var deviceBox=new StackPanel{Spacing=8};deviceBox.Children.Add(Horizontal(new TextBlock{Text="设备",VerticalAlignment=VerticalAlignment.Center},IconButton("refresh","",()=>_=RefreshDevices(),"刷新设备与应用")));deviceBox.Children.Add(devices);At(side,deviceBox,1);
        appQuery.Margin=new Thickness(0,18,0,8);At(side,appQuery,2);At(side,IconButton("apps","全部应用",()=>SelectPackage("")),3);appList.Margin=new Thickness(0,10,0,8);At(side,appList,4);At(side,IconButton("settings","设置",OpenSettings,"外观、保存目录与 ADB · Ctrl+,",shortcut:"Ctrl+,"),5);
        appList.ItemTemplate=new FuncDataTemplate<AppItem>((item,_)=>AppRow(item!),false);
        main.MinWidth=740;main.RowDefinitions=new RowDefinitions("Auto,*,0,0,Auto");At(main,header,0);At(main,listPanel,1);At(main,detailGrip,2);At(main,detailPanel,3);At(main,footer,4);
        var h=new StackPanel{Spacing=13,Margin=new Thickness(20,17,20,15)};header.Child=h;
        var top=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto")};var heading=new StackPanel{Spacing=5};heading.Children.Add(new TextBlock{Text="实时日志",FontSize=24,FontWeight=FontWeight.Bold});heading.Children.Add(subtitle);At(top,heading,0);
        Setup(start,"开始采集",ToggleCapture,"Ctrl+R");Setup(fullButton,"⛶ 日志全屏",ToggleListFullscreen,"Ctrl+Shift+F");fontLabel.VerticalAlignment=VerticalAlignment.Center;
        theme.SelectedIndex=Math.Max(0,Array.IndexOf(Palette.IDs,prefs.Theme));At(top,Horizontal(fullButton,start),0,1);h.Children.Add(top);
        Setup(pause,"暂停显示",TogglePause,"Ctrl+P");pause.Classes.Add("quiet");Setup(followButton,"✓ 跟随最新",ToggleFollow);
        var commands=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto")};counter.VerticalAlignment=VerticalAlignment.Center;counter.TextTrimming=TextTrimming.CharacterEllipsis;At(commands,counter,0);At(commands,Horizontal(pause,IconButton("trash","清空视图",Clear,"Ctrl+K",shortcut:"Ctrl+K"),IconButton("export","导出",()=>_=Export(),"Ctrl+Shift+S",shortcut:"Ctrl+Shift+S")),0,1);h.Children.Add(commands);
        h.Children.Add(BuildMediaControls());
        filterPanel.Child=BuildFilters();
        listPanel.RowDefinitions=new RowDefinitions("Auto,Auto,Auto,*");At(listPanel,filterPanel,0);listFindBorder=FindBar(listQuery,listCount,()=>FindList(-1),()=>FindList(1),()=>ToggleFind(false));listFindBorder.IsVisible=false;At(listPanel,listFindBorder,1);At(listPanel,columnHeader,2);At(listPanel,logScroll,3);logScroll.Content=logs;logs.Viewer=logScroll;
        detailPanel.RowDefinitions=new RowDefinitions("Auto,Auto,*");var dt=new Grid{RowDefinitions=new RowDefinitions("Auto,Auto"),Margin=new Thickness(12,8)};detailTitle.VerticalAlignment=VerticalAlignment.Center;detailTitle.TextTrimming=TextTrimming.CharacterEllipsis;At(dt,detailTitle,0);
        Setup(detailFullButton,"⛶ 全屏",ToggleDetailFullscreen,"Ctrl+Alt+F");Setup(jsonButton,"格式化日志",ToggleFormatting,"Ctrl+J：格式化 / 还原");
        At(dt,Wrap(Button("展开",()=>detail.ExpandAll(true)),Button("折叠",()=>detail.ExpandAll(false)),IconButton("search","",()=>ToggleFind(true),"查找详情 · Ctrl+F",shortcut:"Ctrl+F"),detailFullButton,jsonButton,IconButton("copy","复制",()=>_=CopyDetail(),"复制完整详情；Ctrl+C 复制选中文字",shortcut:"Ctrl+Alt+C"),IconButton("close","",CloseDetail,"关闭详情")),1);At(detailPanel,dt,0);
        detailFindBorder=FindBar(detailQuery,detailCount,()=>FindDetail(-1),()=>FindDetail(1),()=>ToggleFind(true));detailFindBorder.IsVisible=false;At(detailPanel,detailFindBorder,1);At(detailPanel,detailScroll,2);detailScroll.Content=detail;detail.Viewer=detailScroll;detailPanel.IsVisible=false;
        var bottom=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto"),Margin=new Thickness(16,7)};At(bottom,status,0);Setup(restoreButton,"↙ 恢复菜单",()=>{if(detailFullscreen)detailFullscreen=false;else listFullscreen=false;ApplyLayout();});restoreButton.IsVisible=false;At(bottom,restoreButton,0,1);footer.Child=bottom;
        inputs.AddRange([appQuery,filterQuery,tagQuery,listQuery,detailQuery]);
    }
    Border FindBar(TextBox query,TextBlock count,Action previous,Action next,Action close)
    {
        var grid=new Grid{ColumnDefinitions=new ColumnDefinitions("24,*,Auto,Auto,Auto,Auto"),Margin=new Thickness(10,4)};At(grid,new Symbol("search"),0);At(grid,query,0,1);count.VerticalAlignment=VerticalAlignment.Center;At(grid,count,0,2);At(grid,IconButton("up","",previous,"上一处",shortcut:"Ctrl+Shift+G"),0,3);At(grid,IconButton("down","",next,"下一处",shortcut:"Ctrl+G"),0,4);At(grid,IconButton("close","",close,"关闭查找"),0,5);
        query.KeyDown+=(_,e)=>{if(e.Key==Key.Enter){if(e.KeyModifiers.HasFlag(KeyModifiers.Shift))previous();else next();e.Handled=true;}};
        return new Border{Child=grid};
    }
    Button ColumnMenu()
    {
        var b=IconButton("columns","显示列",()=>{});var menu=new ContextMenu();b.Click+=(_,_)=>{menu.Items.Clear();foreach(var (id,title) in new[]{("level","等级"),("time","时间"),("tag","Tag"),("pid","PID"),("message","消息")}){var item=new MenuItem{Header=(prefs.Columns.Contains(id)?"✓  ":"    ")+title,IsEnabled=!prefs.Columns.Contains(id)||prefs.Columns.Count>1};item.Click+=(_,_)=>{if(!prefs.Columns.Add(id))prefs.Columns.Remove(id);Save();ApplyStyleToLogs();};menu.Items.Add(item);}menu.Open(b);};return b;
    }
    sealed record AppItem(string Id,string Title,bool Favorite,bool Installed,string? Icon){public override string ToString()=>Title+" · "+Id;}
    Control AppRow(AppItem? item)
    {
        if(item is null)return new Border();
        if(item.Id.StartsWith("$"))return new TextBlock{Text=item.Title,Foreground=colors.Muted,FontSize=12,Margin=new Thickness(6,12,0,4)};
        var g=new Grid{ColumnDefinitions=new ColumnDefinitions("32,*,30"),Margin=new Thickness(0,6)};
        Control icon=new Symbol("apps"){Width=25,Height=25,Foreground=colors.Accent};
        if(item.Icon is {} data)try{if(!icons.TryGetValue(data,out var bitmap)){bitmap=new Bitmap(new MemoryStream(Convert.FromBase64String(data)));icons[data]=bitmap;}icon=new Image{Source=bitmap,Width=28,Height=28};}catch(Exception e)when(e is FormatException or ArgumentException or IOException){}
        At(g,icon,0);var texts=new StackPanel{Spacing=4,Margin=new Thickness(7,0),Opacity=item.Installed?1:.5};texts.Children.Add(new TextBlock{Text=item.Title,FontWeight=FontWeight.SemiBold,TextTrimming=TextTrimming.CharacterEllipsis});texts.Children.Add(new TextBlock{Text=item.Id,FontSize=11,Foreground=colors.Muted,TextTrimming=TextTrimming.CharacterEllipsis});At(g,texts,0,1);
        var star=new Button{Content=item.Favorite?"★":"☆",Foreground=colors.Accent,Background=Brushes.Transparent,BorderThickness=new Thickness(0),Padding=new Thickness(2),FontSize=20,VerticalAlignment=VerticalAlignment.Center};Symbol.Set(star,"star","",item.Favorite);star.Click+=(_,e)=>{ToggleFavorite(item.Id);e.Handled=true;};At(g,star,0,2);return g;
    }
    void BindActions()
    {
        theme.SelectionChanged+=(_,_)=>{if(initializing)return;prefs.Theme=Palette.IDs[Math.Max(0,theme.SelectedIndex)];ApplyTheme();Save();};
        level.SelectionChanged+=(_,_)=>{UpdateLevelButtons();Refilter();};filterQuery.TextChanged+=(_,_)=>Refilter();tagQuery.TextChanged+=(_,_)=>Refilter();regex.IsCheckedChanged+=(_,_)=>Refilter();
        appQuery.TextChanged+=(_,_)=>RefreshAppList();systemApps.IsCheckedChanged+=async(_,_)=>{prefs.ShowSystemApps=systemApps.IsChecked==true;Save();await LoadPackages();};
        devices.SelectionChanged+=async(_,_)=>{if(initializing||refreshing)return;SwitchDevice((devices.SelectedItem as AndroidDevice)?.Serial??"");await LoadPackages();};
        appList.SelectionChanged+=(_,_)=>{if(!initializing&&appList.SelectedItem is AppItem item&&item.Installed)SelectPackage(item.Id);};
        logScroll.AddHandler(PointerWheelChangedEvent,(_,e)=>logs.HandleWheel(e),RoutingStrategies.Tunnel,true);
        logScroll.SizeChanged+=(_,_)=>{logs.UpdateWidth();SyncLogHeader();};
        logs.Picked+=Pick;logs.ManualScroll+=()=>{if(follow){follow=false;UpdateLabels();}};
        logScroll.ScrollChanged+=(_,_)=>{logs.UpdateWidth();SyncLogHeader();logs.InvalidateVisual();};detailScroll.ScrollChanged+=(_,_)=>detail.InvalidateVisual();
        detail.Activated+=()=>detailActive=true;listPanel.PointerPressed+=(_,_)=>detailActive=false;detailPanel.PointerPressed+=(_,_)=>detailActive=true;
        listQuery.TextChanged+=(_,_)=>SearchList();detailQuery.TextChanged+=(_,_)=>SearchDetail();
        sidebarGrip.DragCompleted+=(_,_)=>SaveDimensions();detailGrip.DragCompleted+=(_,_)=>SaveDimensions();
        var context=new ContextMenu();var copy=new MenuItem{Header="复制选中日志"};copy.Click+=async(_,_)=>await CopyRows();context.Items.Add(copy);logs.ContextMenu=context;
    }
    void ApplyTheme()
    {
        bool systemDark=Application.Current?.ActualThemeVariant==ThemeVariant.Dark;colors=Palette.For(prefs.Theme,systemDark);
        RequestedThemeVariant=prefs.Theme=="system"?ThemeVariant.Default:(colors.Dark?ThemeVariant.Dark:ThemeVariant.Light);
        Background=colors.Canvas;Foreground=colors.Text;sidebar.Background=colors.Panel;header.Background=colors.Canvas;footer.Background=colors.Panel;detailPanel.Background=colors.Panel;sidebarGrip.Background=colors.Line;detailGrip.Background=colors.Line;
        listFindBorder.Background=detailFindBorder.Background=colors.Field;appList.Background=colors.Panel;subtitle.Foreground=counter.Foreground=status.Foreground=colors.Muted;
        Resources["TextControlBackground"]=colors.Field;Resources["TextControlBackgroundPointerOver"]=colors.Field;Resources["TextControlBackgroundFocused"]=colors.Field;
        Resources["TextControlBorderBrush"]=Brushes.Transparent;Resources["TextControlBorderBrushPointerOver"]=Brushes.Transparent;Resources["TextControlBorderBrushFocused"]=Brushes.Transparent;Resources["TextControlForeground"]=colors.Text;
        foreach(var box in inputs){box.Background=colors.Field;box.Foreground=colors.Text;box.CaretBrush=colors.Accent;box.BorderBrush=Brushes.Transparent;}
        foreach(var b in buttons){b.Background=b.Classes.Contains("quiet")?Brushes.Transparent:colors.Chip;b.Foreground=colors.Text;b.BorderThickness=new Thickness(0);}
        foreach(var c in new[]{theme,level,devices,filterHistory}){c.Background=colors.Chip;c.Foreground=colors.Text;}
        foreach(var window in new[]{settingsWindow,historyWindow})if(window is not null){window.Background=colors.Canvas;window.Foreground=colors.Text;window.RequestedThemeVariant=RequestedThemeVariant;}
        UpdateFilterFavorite();UpdateLevelButtons();
        ApplyStyleToLogs();RefreshAppList();UpdateLabels();
    }
    void ApplyStyleToLogs(){foreach(var c in new[]{logs,columnHeader}){c.Palette=colors;c.TextSize=prefs.FontSize;c.Columns=new(prefs.Columns);c.RefreshStyle();}detail.Palette=colors;detail.TextSize=prefs.FontSize;detail.Refresh();SyncLogHeader();}
    void ChangeFont(int delta){prefs.FontSize=delta==0?14:Math.Clamp(prefs.FontSize+delta,10,26);ApplyStyleToLogs();UpdateLabels();Save();}
    void Save(){if(initializing)return;try{prefs.Save();}catch(Exception e)when(e is IOException or UnauthorizedAccessException){SetStatus("设置保存失败："+e.Message);}}
    void SaveDimensions(){if(!listFullscreen&&!detailFullscreen)prefs.SidebarWidth=Math.Clamp(root.ColumnDefinitions[0].ActualWidth,240,680);if(selected is not null&&!detailFullscreen)prefs.DetailHeight=Math.Clamp(main.RowDefinitions[3].ActualHeight,140,1000);Save();}
    void SetStatus(string message){status.Text=message;ToolTip.SetTip(status,message);}
    void UpdateLabels()
    {
        fontLabel.Text=$"{prefs.FontSize:0} pt";Symbol.Set(start,running?"stop":"play",running?"停止采集":"开始采集",shortcut:"Ctrl+R");start.Background=colors.Accent;start.Foreground=colors.Dark?Palette.Brush("#142330"):Brushes.White;
        Symbol.Set(pause,paused?"play":"pause",paused?"恢复显示":"暂停显示",shortcut:"Ctrl+P");Symbol.Set(followButton,follow?"check":"down","跟随最新",shortcut:"Ctrl+L");followButton.Background=follow?colors.Accent:colors.Chip;followButton.Foreground=follow?(colors.Dark?Palette.Brush("#142330"):Brushes.White):colors.Muted;
        subtitle.Text=prefs.Package.Length==0?"全部应用":prefs.Package;counter.Text=$"{filtered.Count:N0} 条匹配 · 缓存 {buffer.Entries.Count:N0} 条 · {buffer.Entries.Count(r=>r.Level>=Level.Error):N0} 条错误"+(paused?" · 显示已暂停":"");
        Symbol.Set(fullButton,listFullscreen?"restore":"expand",listFullscreen?"恢复菜单":"日志全屏",shortcut:"Ctrl+Shift+F");Symbol.Set(detailFullButton,detailFullscreen?"restore":"expand",detailFullscreen?"返回列表":"详情全屏",shortcut:"Ctrl+Alt+F");Symbol.Set(jsonButton,"format",detail.JsonMode?"还原格式":"格式化日志",shortcut:"Ctrl+J");jsonButton.IsEnabled=detail.CanFormat;UpdateMediaLabels();
        detailTitle.Text=selected is null?"":$"{(detail.JsonMode?"格式化":"原始")}日志详情  {selected.Tag}   PID {selected.Pid} · TID {selected.Tid}"+(selected.Parts>1?$" · 已合并 {selected.Parts} 段":"");
    }
    void ApplyLayout()
    {
        bool hide=listFullscreen||detailFullscreen;sidebar.IsVisible=sidebarGrip.IsVisible=!hide;root.ColumnDefinitions[0].MinWidth=hide?0:240;root.ColumnDefinitions[0].Width=new GridLength(hide?0:prefs.SidebarWidth);root.ColumnDefinitions[1].Width=new GridLength(hide?0:5);
        header.IsVisible=!hide;listPanel.IsVisible=!detailFullscreen;restoreButton.IsVisible=hide;Symbol.Set(restoreButton,"restore",detailFullscreen?"恢复日志列表":"恢复菜单",shortcut:detailFullscreen?"Ctrl+Alt+F":"Ctrl+Shift+F");
        main.RowDefinitions[1].Height=detailFullscreen?new GridLength(0):new GridLength(1,GridUnitType.Star);
        bool has=selected is not null;detailPanel.IsVisible=has;detailGrip.IsVisible=has&&!detailFullscreen;
        main.RowDefinitions[2].Height=new GridLength(has&&!detailFullscreen?6:0);
        main.RowDefinitions[3].Height=detailFullscreen?new GridLength(1,GridUnitType.Star):new GridLength(has?Math.Min(prefs.DetailHeight,Math.Max(140,Bounds.Height-350)):0);
        main.RowDefinitions[3].MinHeight=has?120:0;main.RowDefinitions[1].MinHeight=detailFullscreen?0:100;UpdateLabels();
    }
    void SyncLogHeader()=>columnHeader.SyncHeader(logs.ContentWidth,logScroll.Offset.X);
    void ToggleListFullscreen(){SaveDimensions();listFullscreen=!listFullscreen;detailFullscreen=false;ApplyLayout();}
    void ToggleDetailFullscreen(){if(selected is null)return;SaveDimensions();detailFullscreen=!detailFullscreen;detailActive=true;ApplyLayout();}
    void Pick(LogRecord record){bool first=selected is null;selected=record;detail.SetRecord(record);if(first)ApplyLayout();UpdateLabels();SearchDetail();}
    void CloseDetail(){selected=null;detailFullscreen=false;detailFindBorder.IsVisible=false;detailActive=false;ApplyLayout();}
    void ToggleFormatting(){if(selected is null||!detail.CanFormat)return;detailActive=true;detail.JsonMode=!detail.JsonMode;detail.Refresh();UpdateLabels();SearchDetail();}
    void ToggleFollow(){follow=!follow;UpdateLabels();if(follow)ScrollEnd();}
    void TogglePause(){paused=!paused;frozen=paused?buffer.Entries.ToList():null;Refilter();UpdateLabels();}
    void Clear(){buffer.Clear();while(pending.TryDequeue(out _)){}frozen=paused?[]:null;logs.Clear();CloseDetail();Refilter();SetStatus("视图已清空；继续采集新的日志");}
    void Drain()
    {
        if(closing)return;var batch=new List<LogRecord>();while(batch.Count<20000&&pending.TryDequeue(out var r))if(r.Generation==captureGeneration)batch.Add(r.Record);if(batch.Count==0)return;
        buffer.Append(batch);if(!paused)Refilter();else UpdateLabels();
    }
    void Refilter()
    {
        if(initializing||restoringFilter)return;
        UpdateFilterFavorite();
        try{var filter=new LogFilter((Level)Math.Max(0,level.SelectedIndex),filterQuery.Text??"",tagQuery.Text??"",regex.IsChecked==true);filtered=(frozen??buffer.Entries).Where(filter.Matches).ToList();}
        catch(ArgumentException){SetStatus("正则表达式无效，请检查过滤条件");return;}
        catch(RegexMatchTimeoutException){SetStatus("正则匹配耗时过长，请简化表达式");return;}
        if(selected is {} previous && (frozen??buffer.Entries).FirstOrDefault(r=>r.Id==previous.Id) is {} updated && updated!=previous)Pick(updated);
        logs.SetRows(filtered);SyncLogHeader();SearchList(false);UpdateLabels();if(follow)ScrollEnd();
    }
    void ScrollEnd()=>Dispatcher.UIThread.Post(()=>{if(follow&&!closing)logScroll.Offset=new Vector(logScroll.Offset.X,Math.Max(0,logScroll.Extent.Height-logScroll.Viewport.Height));},DispatcherPriority.Background);
    void ToggleFind(bool inDetail)
    {
        if(inDetail&&selected is null)return;detailActive=inDetail;var panel=inDetail?detailFindBorder:listFindBorder;panel.IsVisible=!panel.IsVisible;
        if(panel.IsVisible){var box=inDetail?detailQuery:listQuery;Dispatcher.UIThread.Post(()=>{box.Focus();box.SelectAll();});}else if(inDetail)detail.Focus();else logs.Focus();
        if(inDetail)SearchDetail();else SearchList();
    }
    void SearchList(bool jump=true)
    {
        logs.Query=listFindBorder.IsVisible?listQuery.Text??"":"";listHits=[];if(logs.Query.Length>0)for(int i=0;i<filtered.Count;i++)if(filtered[i].FullText.Contains(logs.Query,StringComparison.OrdinalIgnoreCase))listHits.Add(i);
        if(jump){listMatch=listHits.Count>0?0:-1;if(listMatch>=0){follow=false;logs.Reveal(listHits[0]);}}else if(listMatch>=listHits.Count)listMatch=listHits.Count-1;
        listCount.Text=logs.Query.Length==0?"":$"{Math.Max(0,listMatch+1)} / {listHits.Count}";logs.InvalidateVisual();UpdateLabels();
    }
    void FindList(int delta){if(listHits.Count==0)return;listMatch=(listMatch+delta+listHits.Count)%listHits.Count;follow=false;logs.Reveal(listHits[listMatch]);listCount.Text=$"{listMatch+1} / {listHits.Count}";UpdateLabels();}
    void SearchDetail(){detail.Query=detailFindBorder.IsVisible?detailQuery.Text??"":"";detail.Find(1,true);DetailCount();}
    void FindDetail(int delta){detail.Find(delta);DetailCount();}
    void DetailCount()=>detailCount.Text=detail.Query.Length==0?"":$"{Math.Max(0,detail.ActiveMatch+1)} / {detail.MatchCount}";
    void Shortcuts(object? sender,KeyEventArgs e)
    {
        bool command=(e.KeyModifiers&(KeyModifiers.Control|KeyModifiers.Meta))!=0,shift=e.KeyModifiers.HasFlag(KeyModifiers.Shift),alt=e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        if(e.Key==Key.Escape){if(detailActive&&detailFindBorder.IsVisible)ToggleFind(true);else if(listFindBorder.IsVisible)ToggleFind(false);else if(detailFullscreen){detailFullscreen=false;ApplyLayout();}else if(listFullscreen){listFullscreen=false;ApplyLayout();}else return;e.Handled=true;return;}
        if(!command)return;
        bool textInput=e.Source is Control control&&control.GetVisualAncestors().Prepend(control).Any(c=>c is TextBox);
        switch(e.Key)
        {
            case Key.F when alt:ToggleDetailFullscreen();break;
            case Key.F when shift:ToggleListFullscreen();break;
            case Key.F:ToggleFind(detailActive||detailFullscreen);break;
            case Key.G:if(detailActive||detailFullscreen)FindDetail(shift?-1:1);else FindList(shift?-1:1);break;
            case Key.OemPlus:case Key.Add:ChangeFont(1);break;
            case Key.OemMinus:case Key.Subtract:ChangeFont(-1);break;
            case Key.D0:case Key.NumPad0:ChangeFont(0);break;
            case Key.OemComma:OpenSettings();break;
            case Key.J when !shift&&!alt:ToggleFormatting();break;
            case Key.L when !shift&&!alt:ToggleFollow();break;
            case Key.H when shift&&!alt:OpenMediaHistory();break;
            case Key.C when alt&&!shift:_=CopyDetail();break;
            case Key.C when shift&&!alt:screenshotTask=TakeScreenshot(true);break;
            case Key.S when alt&&!shift:screenshotTask=TakeScreenshot();break;
            case Key.R when shift&&!alt:_=ToggleRecording();break;
            case Key.R when !shift&&!alt:ToggleCapture();break;
            case Key.P when !shift&&!alt:TogglePause();break;
            case Key.K when !shift&&!alt:Clear();break;
            case Key.S when shift&&!alt:_=Export();break;
            case Key.C when !textInput&&!shift&&!alt:if(detailActive||detailFullscreen){if(detail.TextView.SelectedText.Length>0)_=Copy(detail.TextView.SelectedText);else _=CopyDetail();}else _=CopyRows();break;
            case Key.A when !textInput&&!shift&&!alt:if(detailActive||detailFullscreen)detail.TextView.SelectAll();else{logs.Selection=filtered.Select(r=>r.Id).ToHashSet();logs.InvalidateVisual();}break;
            default:return;
        }
        e.Handled=true;
    }
    async Task CopyRows(){var rows=filtered.Where(r=>logs.Selection.Contains(r.Id)).ToArray();if(rows.Length==0&&selected is not null)rows=[selected];await Copy(string.Join(Environment.NewLine,rows.Select(r=>r.FullText)));}
    async Task CopyDetail(){if(selected is not null)await Copy(detail.CopyText);}
    async Task Copy(string text){try{if(Clipboard is {} c){await c.SetTextAsync(text);SetStatus("已复制日志");}}catch(Exception e){SetStatus("复制失败："+e.Message);}}
    async Task Export()
    {
        try{var file=await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions{Title="导出当前过滤结果",SuggestedFileName=$"LogcatMini-{DateTime.Now:yyyyMMdd-HHmmss}.log",DefaultExtension="log"});if(file is null)return;var snapshot=filtered.ToArray();await using var stream=await file.OpenWriteAsync();stream.SetLength(0);await using var writer=new StreamWriter(stream,new UTF8Encoding(false));foreach(var r in snapshot)await writer.WriteLineAsync(r.FullText);SetStatus($"已导出 {snapshot.Length:N0} 条日志");}catch(Exception e){SetStatus("导出失败："+e.Message);}
    }
}
