using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform;
using Avalonia.Threading;
namespace LogcatMini.Desktop;

/// Uses the Windows system H.264 player; no browser or additional codec runtime.
[SupportedOSPlatform("windows")]
public sealed class WindowsVideoPreview : Grid, IDisposable
{
    readonly VideoHost host;
    readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromMilliseconds(250)};
    readonly Slider seek=new(){Minimum=0,Maximum=1,HorizontalAlignment=HorizontalAlignment.Stretch};
    readonly TextBlock time=new(){VerticalAlignment=VerticalAlignment.Center};
    readonly Button toggle=new(){Content="暂停"};
    bool updating;
    public WindowsVideoPreview(string path,Action<string> error)
    {
        RowDefinitions=new RowDefinitions("*,Auto");host=new VideoHost(path,error);Children.Add(host);
        var controls=new Grid{ColumnDefinitions=new ColumnDefinitions("Auto,*,Auto"),Margin=new Thickness(4)};
        controls.Children.Add(toggle);Grid.SetColumn(seek,1);controls.Children.Add(seek);Grid.SetColumn(time,2);controls.Children.Add(time);Grid.SetRow(controls,1);Children.Add(controls);
        toggle.Click+=(_,_)=>{if(host.Player is not {} player)return;player.GetState(out int state);if(state==2)player.Pause();else{if(host.Position>=host.Duration-0.2)host.Seek(0);player.Play();}};
        seek.ValueChanged+=(_,_)=>{if(!updating)host.Seek(seek.Value);};
        timer.Tick+=(_,_)=>{updating=true;try{double duration=host.Duration;seek.Maximum=Math.Max(1,duration);seek.Value=host.Position;time.Text=$"{TimeSpan.FromSeconds(seek.Value):mm\\:ss} / {TimeSpan.FromSeconds(duration):mm\\:ss}";if(host.Player is {} p){p.GetState(out int state);toggle.Content=state==2?"暂停":"播放";p.UpdateVideo();}}finally{updating=false;}};timer.Start();
    }
    public void Dispose(){timer.Stop();host.Release();}

    sealed class VideoHost(string path,Action<string> error) : NativeControlHost
    {
        public Player? Player;
        PlayerCallback? callback;
        static readonly Guid PositionType=Guid.Empty;
        public double Position=>ReadTime(false);
        public double Duration=>ReadTime(true);
        double ReadTime(bool duration){if(Player is not {} p)return 0;Variant value;int hr=duration?p.GetDuration(in PositionType,out value):p.GetPosition(in PositionType,out value);return hr>=0&&value.Type is 20 or 21?Math.Max(0,value.Value/10_000_000d):0;}
        public void Seek(double seconds){if(Player is {} p){var value=new Variant{Type=20,Value=(long)(seconds*10_000_000)};p.SetPosition(in PositionType,in value);}}
        protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
        {
            var control=base.CreateNativeControlCore(parent);
            try{callback=new PlayerCallback(error);Marshal.ThrowExceptionForHR(MFCreateMFPMediaPlayer(path,true,0,callback,control.Handle,out Player));Player.SetAspectRatioMode(1);}
            catch(Exception e){Dispatcher.UIThread.Post(()=>error("视频预览不可用，可使用“打开 / 播放”："+e.Message));Release();}
            return control;
        }
        protected override void DestroyNativeControlCore(IPlatformHandle control){Release();base.DestroyNativeControlCore(control);}
        public void Release(){if(Player is {} p){Player=null;p.Shutdown();Marshal.ReleaseComObject(p);}callback=null;}
    }
    [DllImport("mfplay.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]static extern int MFCreateMFPMediaPlayer(string url,[MarshalAs(UnmanagedType.Bool)]bool start,uint options,Callback callback,IntPtr window,out Player player);
    [StructLayout(LayoutKind.Explicit,Size=24)]struct Variant{[FieldOffset(0)]public ushort Type;[FieldOffset(8)]public long Value;}
    [ComVisible(true),Guid("766C8FFB-5FDB-4FEA-A28D-B912996F51BD"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]public interface Callback{[PreserveSig]void OnMediaPlayerEvent(IntPtr header);}
    [ComVisible(true),ClassInterface(ClassInterfaceType.None)]sealed class PlayerCallback(Action<string> error) : Callback
    {
        public void OnMediaPlayerEvent(IntPtr header){int hr=Marshal.ReadInt32(header,4);if(hr<0)Dispatcher.UIThread.Post(()=>error("视频播放失败，可使用“打开 / 播放”："+(Marshal.GetExceptionForHR(hr)?.Message??hr.ToString())));}
    }
    // Vtable order and ABI from the Windows SDK mfplay.h (IMFPMediaPlayer).
    [ComImport,Guid("A714590A-58AF-430A-85BF-44F5EC838D85"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface Player
    {
        [PreserveSig]int Play();[PreserveSig]int Pause();[PreserveSig]int Stop();[PreserveSig]int FrameStep();
        [PreserveSig]int SetPosition(in Guid type,in Variant value);[PreserveSig]int GetPosition(in Guid type,out Variant value);[PreserveSig]int GetDuration(in Guid type,out Variant value);
        [PreserveSig]int SetRate(float rate);[PreserveSig]int GetRate(out float rate);[PreserveSig]int GetSupportedRates([MarshalAs(UnmanagedType.Bool)]bool forward,out float slow,out float fast);[PreserveSig]int GetState(out int state);
        [PreserveSig]int CreateMediaItemFromURL([MarshalAs(UnmanagedType.LPWStr)]string url,[MarshalAs(UnmanagedType.Bool)]bool sync,UIntPtr userData,out IntPtr item);
        [PreserveSig]int CreateMediaItemFromObject(IntPtr obj,[MarshalAs(UnmanagedType.Bool)]bool sync,UIntPtr userData,out IntPtr item);
        [PreserveSig]int SetMediaItem(IntPtr item);[PreserveSig]int ClearMediaItem();[PreserveSig]int GetMediaItem(out IntPtr item);
        [PreserveSig]int GetVolume(out float volume);[PreserveSig]int SetVolume(float volume);[PreserveSig]int GetBalance(out float balance);[PreserveSig]int SetBalance(float balance);[PreserveSig]int GetMute([MarshalAs(UnmanagedType.Bool)]out bool mute);[PreserveSig]int SetMute([MarshalAs(UnmanagedType.Bool)]bool mute);
        [PreserveSig]int GetNativeVideoSize(IntPtr video,IntPtr aspect);[PreserveSig]int GetIdealVideoSize(IntPtr min,IntPtr max);[PreserveSig]int SetVideoSourceRect(IntPtr rect);[PreserveSig]int GetVideoSourceRect(IntPtr rect);
        [PreserveSig]int SetAspectRatioMode(uint mode);[PreserveSig]int GetAspectRatioMode(out uint mode);[PreserveSig]int GetVideoWindow(out IntPtr window);[PreserveSig]int UpdateVideo();
        [PreserveSig]int SetBorderColor(uint color);[PreserveSig]int GetBorderColor(out uint color);[PreserveSig]int InsertEffect(IntPtr effect,[MarshalAs(UnmanagedType.Bool)]bool optional);[PreserveSig]int RemoveEffect(IntPtr effect);[PreserveSig]int RemoveAllEffects();[PreserveSig]int Shutdown();
    }
}
