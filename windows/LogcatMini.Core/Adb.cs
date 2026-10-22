using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
namespace LogcatMini.Core;

public sealed record AndroidDevice(string Serial,string Name,string State)
{
    public bool Ready=>State=="device";
    public override string ToString()=>$"{Name}  ·  {Serial}"+(Ready?"":$"  [{State}]");
    public static List<AndroidDevice> Parse(string output)=>output.Split('\n').Select(line=>line.Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries)).Where(p=>p.Length>=2 && new[]{"device","offline","unauthorized","recovery"}.Contains(p[1])).Select(p=>new AndroidDevice(p[0],p.FirstOrDefault(v=>v.StartsWith("model:"))?[6..].Replace('_',' ')??p[0],p[1])).ToList();
}
public sealed record AndroidPackage(string Id,string Uid)
{
    public string ShortName=>string.Join('.',Id.Split('.').TakeLast(2));
    public static List<AndroidPackage> Parse(string output)
    {
        List<AndroidPackage> result=[];
        foreach(var line in output.Split('\n'))
        {
            var p=line.Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries);
            var id=p.FirstOrDefault(x=>x.StartsWith("package:"))?[8..];var uid=p.FirstOrDefault(x=>x.StartsWith("uid:"))?[4..];
            if(id is not null && uid is not null && ValidPackage(id) && uid.Length>0 && uid.All(char.IsAsciiDigit))result.Add(new(id,uid));
        }
        return result.DistinctBy(p=>p.Id).OrderBy(p=>p.Id,StringComparer.OrdinalIgnoreCase).ToList();
    }
    public static bool ValidPackage(string id)=>id.Length is >0 and <=255 && Regex.IsMatch(id,@"\A[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*\z");
}
public sealed class AdbClient(string path)
{
    public string Path {get;}=path;
    public static string? Locate(string? custom=null)
    {
        string exe=OperatingSystem.IsWindows()?"adb.exe":"adb";
        var paths=new List<string?>{custom,System.IO.Path.Combine(AppContext.BaseDirectory,"platform-tools",exe),System.IO.Path.Combine(AppContext.BaseDirectory,exe)};
        foreach(var variable in new[]{"ANDROID_HOME","ANDROID_SDK_ROOT"})if(Environment.GetEnvironmentVariable(variable) is {} root)paths.Add(System.IO.Path.Combine(root,"platform-tools",exe));
        paths.Add(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Android","Sdk","platform-tools",exe));
        paths.Add(System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Library","Android","sdk","platform-tools",exe));
        paths.AddRange((Environment.GetEnvironmentVariable("PATH")??"").Split(System.IO.Path.PathSeparator).Select(p=>System.IO.Path.Combine(p,exe)));
        return paths.FirstOrDefault(p=>!string.IsNullOrEmpty(p)&&File.Exists(p));
    }
    public Process MakeProcess(IEnumerable<string> args)
    {
        var info=new ProcessStartInfo(Path){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8};
        foreach(var a in args)info.ArgumentList.Add(a);return new Process{StartInfo=info};
    }
    public async Task<string> Run(IEnumerable<string> args,CancellationToken cancellation=default,int seconds=12)
    {
        using var p=MakeProcess(args);using var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancellation);timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
        p.Start();var stdout=p.StandardOutput.ReadToEndAsync(timeout.Token);var stderr=p.StandardError.ReadToEndAsync(timeout.Token);
        try{await p.WaitForExitAsync(timeout.Token);var output=await stdout;var error=await stderr;if(p.ExitCode!=0)throw new IOException(string.IsNullOrWhiteSpace(error)?output:error);return output;}
        catch(OperationCanceledException){try{p.Kill(true);}catch(InvalidOperationException){}throw new IOException(cancellation.IsCancellationRequested?"ADB 操作已取消":"ADB 响应超时");}
    }
    public Task<string> Device(string serial,IEnumerable<string> args,CancellationToken token=default,int seconds=12)=>Run(new[]{"-s",serial}.Concat(args),token,seconds);
    public static string CaptureCommand(string? uid)
    {
        if(uid is not null && (uid.Length==0 || !uid.All(char.IsAsciiDigit)))throw new ArgumentException("无效的应用 UID");
        return "exec logcat -v threadtime -v year -T \"$(date '+%m-%d %H:%M:%S.%3N')\" -b main -b system -b crash"+(uid is null?"":" --uid="+uid)+" '*:V'";
    }
    public async Task Capture(string serial,string? uid,Action<string> receive,CancellationToken token)
    {
        using var p=MakeProcess(["-s",serial,"shell",CaptureCommand(uid)]);p.Start();var errors=p.StandardError.ReadToEndAsync();
        using var registration=token.Register(()=>{try{if(!p.HasExited)p.Kill(true);}catch(InvalidOperationException){} });
        try
        {
            while(await p.StandardOutput.ReadLineAsync(token) is {} line)receive(line);
            await p.WaitForExitAsync(token);if(!token.IsCancellationRequested)throw new IOException((await errors).Trim() is {Length:>0} e?e:"日志连接已结束，请检查设备后重新开始。");
        }
        catch(OperationCanceledException)when(token.IsCancellationRequested){}
        finally{if(!p.HasExited){try{p.Kill(true);}catch(InvalidOperationException){}}}
    }
}
public sealed record AppMetadata(string PackageName,string Label,string? IconPNG,long LastUpdateTime);
public sealed class MetadataService(string directory,string helper)
{
    readonly SemaphoreSlim gate=new(1,1);
    string CachePath(string serial)=>System.IO.Path.Combine(directory,Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(serial)))+".json");
    public Dictionary<string,AppMetadata> Load(string serial)
    {try{return JsonSerializer.Deserialize<Dictionary<string,AppMetadata>>(File.ReadAllText(CachePath(serial)))??[];}catch(Exception e)when(e is IOException or JsonException or UnauthorizedAccessException){return [];}}
    public static List<AppMetadata> Decode(string output,ISet<string> requested)
    {
        const string marker="LOGCAT_MINI_METADATA:";
        var line=output.Split('\n').LastOrDefault(x=>x.StartsWith(marker))??throw new IOException("未能读取应用名称和图标");
        using var doc=JsonDocument.Parse(line[marker.Length..]);var root=doc.RootElement;
        if(root.GetProperty("schema").GetInt32()!=1)throw new IOException("应用信息格式不支持");
        List<AppMetadata> result=[];
        foreach(var app in root.GetProperty("apps").EnumerateArray())
        {
            var id=app.GetProperty("packageName").GetString();if(id is null || !AndroidPackage.ValidPackage(id) || !requested.Contains(id) || app.TryGetProperty("error",out _))continue;
            var label=app.GetProperty("label").GetString();if(string.IsNullOrWhiteSpace(label))continue;string? icon=null;
            if(app.TryGetProperty("iconPNG",out var png)&&png.ValueKind==JsonValueKind.String && png.GetString() is {Length:<=700000} data)
                try{var bytes=Convert.FromBase64String(data);if(bytes.Length is >8 and <=512000 && bytes.AsSpan(0,8).SequenceEqual(new byte[]{137,80,78,71,13,10,26,10}))icon=data;}catch(FormatException){}
            result.Add(new(id,label[..Math.Min(256,label.Length)],icon,app.TryGetProperty("lastUpdateTime",out var time)?time.GetInt64():0));
        }
        return result;
    }
    public async Task<Dictionary<string,AppMetadata>> Refresh(AdbClient adb,string serial,IEnumerable<string> packages,CancellationToken token)
    {
        await gate.WaitAsync(token);
        try{return await RefreshLocked(adb,serial,packages,token);}finally{gate.Release();}
    }
    async Task<Dictionary<string,AppMetadata>> RefreshLocked(AdbClient adb,string serial,IEnumerable<string> packages,CancellationToken token)
    {
        var ids=packages.Where(AndroidPackage.ValidPackage).Distinct().ToArray();var cache=Load(serial);if(ids.Length==0)return cache;
        string remote="/data/local/tmp/logcat-mini-win-"+Guid.NewGuid().ToString("N")+".jar";
        try
        {
            await adb.Device(serial,["push",helper,remote],token);await adb.Device(serial,["shell","chmod","444",remote],token);
            foreach(var batch in ids.Chunk(20))
            {
                var output=await adb.Device(serial,new[]{"shell","env","CLASSPATH="+remote,"app_process","/","com.songran.logcatmini.AppMetadata"}.Concat(batch),token,25);
                foreach(var item in Decode(output,batch.ToHashSet()))cache[item.PackageName]=item;
            }
        }
        finally { try{await adb.Device(serial,["shell","rm","-f",remote],seconds:5);}catch(IOException){} }
        Directory.CreateDirectory(directory);var file=CachePath(serial);await File.WriteAllTextAsync(file+".tmp",JsonSerializer.Serialize(cache),token);File.Move(file+".tmp",file,true);return cache;
    }
}
