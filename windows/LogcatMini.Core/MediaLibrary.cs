using System.Text.Json;
namespace LogcatMini.Core;

public sealed record MediaItem(string Path,string Kind,string DeviceName,string Serial,DateTime CreatedAt,double? Duration=null)
{
    public bool Exists=>File.Exists(Path);
    public override string ToString()=>$"{(Kind=="screenshot"?"截图":"录屏")} · {CreatedAt:yyyy-MM-dd HH:mm:ss} · {DeviceName}"+(Exists?"":" · 文件已移动或删除");
}
public sealed class MediaLibrary
{
    public string? ScreenshotDirectory {get;set;}
    public string? RecordingDirectory {get;set;}
    public List<MediaItem> Items {get;set;}=[];
    public static string IndexPath=>System.IO.Path.Combine(Preferences.DirectoryPath,"media.json");
    public static MediaLibrary Load(string? path=null)
    {
        try{var library=JsonSerializer.Deserialize<MediaLibrary>(File.ReadAllText(path??IndexPath))??new();library.Items=library.Items?.Where(i=>i is not null&&!string.IsNullOrWhiteSpace(i.Path)&&i.Kind is "screenshot" or "recording").DistinctBy(i=>i.Path).OrderByDescending(i=>i.CreatedAt).ToList()??[];return library;}
        catch(Exception e)when(e is IOException or JsonException or UnauthorizedAccessException){return new();}
    }
    public void Save(string? path=null)
    {
        path??=IndexPath;Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);var temp=path+".tmp";
        File.WriteAllText(temp,JsonSerializer.Serialize(this,new JsonSerializerOptions{WriteIndented=true}));File.Move(temp,path,true);
    }
    public string? DirectoryFor(string kind)=>kind=="screenshot"?ScreenshotDirectory:RecordingDirectory??ScreenshotDirectory;
    public void SetDirectory(string kind,string directory){if(kind=="screenshot")ScreenshotDirectory=directory;else RecordingDirectory=directory;Save();}
    public string Destination(string kind,AndroidDevice device)
    {
        var directory=DirectoryFor(kind)??throw new IOException("请先选择保存文件夹");Directory.CreateDirectory(directory);
        var serial=new string(device.Serial.Select(c=>char.IsAsciiLetterOrDigit(c)?c:'_').ToArray());
        var name=$"{(kind=="screenshot"?"Screenshot":"Recording")}-{serial}-{DateTime.Now:yyyyMMdd-HHmmss-fff}";
        for(int i=0;;i++){var path=System.IO.Path.Combine(directory,name+(i==0?"":$"-{i}")+(kind=="screenshot"?".png":".mp4"));if(!File.Exists(path))return path;}
    }
    public void Add(MediaItem item){Items.RemoveAll(i=>i.Path==item.Path);Items.Insert(0,item);Save();}
}
