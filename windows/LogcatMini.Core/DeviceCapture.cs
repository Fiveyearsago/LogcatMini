using System.Diagnostics;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
namespace LogcatMini.Core;

public static class DeviceCapture
{
    public static async Task Screenshot(AdbClient adb,string serial,string destination,CancellationToken token=default)
    {
        var data=await ScreenshotData(adb,serial,token);
        string temp=destination+"."+Guid.NewGuid().ToString("N")+".tmp";
        try{await File.WriteAllBytesAsync(temp,data,token);File.Move(temp,destination,false);}finally{if(File.Exists(temp))File.Delete(temp);}
    }
    public static async Task<byte[]> ScreenshotData(AdbClient adb,string serial,CancellationToken token=default)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var p=adb.MakeProcess(["-s",serial,"exec-out","screencap","-p"]);p.Start();
        using var cancel=timeout.Token.Register(()=>{try{p.Kill(true);}catch(InvalidOperationException){}});
        var error=p.StandardError.ReadToEndAsync();using var bytes=new MemoryStream();
        await p.StandardOutput.BaseStream.CopyToAsync(bytes,timeout.Token);await p.WaitForExitAsync(timeout.Token);
        if(p.ExitCode!=0)throw new IOException(await error);
        var data=bytes.ToArray();ValidatePNG(data);
        return data;
    }
    public static void ValidatePNG(byte[] bytes)
    {
        if(bytes.Length<=24||!bytes.AsSpan(0,8).SequenceEqual(new byte[]{137,80,78,71,13,10,26,10}))throw new IOException("手机未返回有效的 PNG 截图");
    }
}

/// Local scrcpy muxing works on OEM devices that reject Android screenrecord file writes.
public sealed class ScreenRecording
{
    public string Serial {get;}
    public string TemporaryMovie {get;}
    public DateTime StartedAt {get;}=DateTime.Now;
    readonly Process process;
    readonly Task completion;
    readonly NamedPipeServerStream? pipe;
    readonly string diagnosticPath;
    bool stopRequested;
    public bool IsRunning=>!process.HasExited;
    public static string? Locate(string? custom=null)
    {
        string exe=OperatingSystem.IsWindows()?"scrcpy.exe":"scrcpy";
        var paths=new List<string?>{custom,Path.Combine(AppContext.BaseDirectory,"Recording",exe)};
        paths.AddRange((Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator).Select(p=>Path.Combine(p,exe)));
        return paths.FirstOrDefault(p=>!string.IsNullOrEmpty(p)&&File.Exists(p));
    }
    public static string[] Arguments(string serial,string movie)=>["--serial",serial,"--no-audio","--no-control","--no-playback","--no-window","--record="+movie,"--time-limit=180","--max-size=1920","--video-bit-rate=8M"];
    public ScreenRecording(string adb,string serial,string runtime)
    {
        Serial=serial;string dir=Path.Combine(Path.GetTempPath(),"logcat-mini-recording-"+Guid.NewGuid());Directory.CreateDirectory(dir);
        TemporaryMovie=Path.Combine(dir,"recording.mp4");diagnosticPath=Path.Combine(dir,"recorder.log");
        if(OperatingSystem.IsWindows())
        {
            // A worker owns a separate hidden console. Ctrl+C can never reach another capture or the app.
            string pipeName="LogcatMiniRecord-"+Guid.NewGuid();pipe=new(pipeName,PipeDirection.Out,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
            var info=new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=false,CreateNoWindow=true};
            if((Path.GetFileNameWithoutExtension(Environment.ProcessPath)??"").Equals("dotnet",StringComparison.OrdinalIgnoreCase))info.ArgumentList.Add(System.Reflection.Assembly.GetEntryAssembly()!.Location);
            foreach(var arg in new[]{"--record-worker",pipeName,runtime,adb,serial,TemporaryMovie,diagnosticPath})info.ArgumentList.Add(arg);
            process=Process.Start(info)??throw new IOException("无法启动录屏组件");
            completion=process.WaitForExitAsync();
        }
        else
        {
            var info=RecorderInfo(runtime,adb,serial,TemporaryMovie);process=Process.Start(info)??throw new IOException("无法启动录屏组件");
            completion=ReadDiagnostics(process,diagnosticPath);
        }
    }
    internal static ProcessStartInfo RecorderInfo(string runtime,string adb,string serial,string movie)
    {
        var info=new ProcessStartInfo(runtime){UseShellExecute=false,RedirectStandardError=true,RedirectStandardOutput=true,CreateNoWindow=false};
        foreach(var arg in Arguments(serial,movie))info.ArgumentList.Add(arg);info.Environment["ADB"]=adb;
        string server=Path.Combine(Path.GetDirectoryName(runtime)!,"scrcpy-server");if(File.Exists(server))info.Environment["SCRCPY_SERVER_PATH"]=server;
        return info;
    }
    internal static async Task ReadDiagnostics(Process process,string path)
    {
        var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();await process.WaitForExitAsync();
        await File.WriteAllTextAsync(path,await stdout+"\n"+await stderr);
    }
    public async Task Stop()
    {
        if(stopRequested||process.HasExited)return;stopRequested=true;
        try{if(pipe is not null)
        {
            using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await pipe.WaitForConnectionAsync(timeout.Token);await pipe.WriteAsync(new byte[]{1},timeout.Token);await pipe.FlushAsync(timeout.Token);
        }
        else if(kill(process.Id,2)!=0&&!process.HasExited)throw new IOException("无法停止当前录屏进程");}
        catch{stopRequested=false;throw;}
    }
    public async Task SaveWhenFinished(string destination)
    {
        await completion;
        try
        {
            ValidateMovie(TemporaryMovie);
            string temp=destination+"."+Guid.NewGuid().ToString("N")+".tmp";
            try{File.Copy(TemporaryMovie,temp,false);File.Move(temp,destination,false);}finally{if(File.Exists(temp))File.Delete(temp);}
        }
        catch(Exception e)when(e is IOException or UnauthorizedAccessException)
        {
            string error=File.Exists(diagnosticPath)?await File.ReadAllTextAsync(diagnosticPath):"";
            throw new IOException($"录屏尚未保存：{e.Message}\n{error}\n临时文件保留在：{TemporaryMovie}",e);
        }
        pipe?.Dispose();process.Dispose();Directory.Delete(Path.GetDirectoryName(TemporaryMovie)!,true);
    }
    public void LeaveTemporaryFile()
    {
        if(!process.HasExited)throw new InvalidOperationException("录屏尚未结束");pipe?.Dispose();process.Dispose();
    }
    public static void ValidateMovie(string path)
    {
        using var file=File.OpenRead(path);var header=new byte[16];bool type=false,media=false,index=false;
        while(file.Position+8<=file.Length)
        {
            long start=file.Position;file.ReadExactly(header.AsSpan(0,8));long size=BinaryPrimitives.ReadUInt32BigEndian(header);string kind=Encoding.ASCII.GetString(header,4,4);int headerSize=8;
            if(size==1){file.ReadExactly(header.AsSpan(8,8));ulong large=BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(8));if(large>long.MaxValue)throw new IOException("MP4 大小无效");size=(long)large;headerSize=16;}
            if(size==0)size=file.Length-start;if(size<headerSize||size>file.Length-start)throw new IOException("MP4 文件不完整");
            type|=kind=="ftyp";media|=kind=="mdat"&&size>headerSize;index|=kind=="moov"&&size>headerSize;file.Position=start+size;
        }
        if(!type||!media||!index)throw new IOException("MP4 尚未完成写入，请重试录制");
    }
    [DllImport("libc",SetLastError=true)]static extern int kill(int pid,int signal);
}

public static class RecordingWorker
{
    delegate bool ConsoleHandler(uint signal);
    static readonly ConsoleHandler IgnoreSignal=_=>true;
    [DllImport("kernel32.dll")]static extern bool AllocConsole();
    [DllImport("kernel32.dll")]static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]static extern bool ShowWindow(IntPtr window,int command);
    [DllImport("kernel32.dll")]static extern bool SetConsoleCtrlHandler(ConsoleHandler handler,bool add);
    [DllImport("kernel32.dll")]static extern bool GenerateConsoleCtrlEvent(uint signal,uint group);
    public static async Task<int> Run(string[] args)
    {
        if(!OperatingSystem.IsWindows()||args.Length!=7)return 1;
        try
        {
            if(!AllocConsole())throw new IOException("无法创建独立录屏控制台");ShowWindow(GetConsoleWindow(),0);SetConsoleCtrlHandler(IgnoreSignal,true);
            using var pipe=new NamedPipeClientStream(".",args[1],PipeDirection.In,PipeOptions.Asynchronous);await pipe.ConnectAsync(15000);
            using var recorder=Process.Start(ScreenRecording.RecorderInfo(args[2],args[3],args[4],args[5]))??throw new IOException("无法启动 scrcpy");
            var completed=ScreenRecording.ReadDiagnostics(recorder,args[6]);var stopped=pipe.ReadAsync(new byte[1]).AsTask();
            if(await Task.WhenAny(completed,stopped)==stopped&&!recorder.HasExited)
            {
                // Console is private to this worker + its one scrcpy child.
                GenerateConsoleCtrlEvent(0,0);
                if(await Task.WhenAny(completed,Task.Delay(20000))!=completed){recorder.Kill(true);await completed;return 1;}
            }
            await completed;return recorder.ExitCode;
        }
        catch(Exception e){await File.WriteAllTextAsync(args[6],e.ToString());return 1;}
    }
}
