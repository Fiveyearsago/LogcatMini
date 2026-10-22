using System.Text.Json;
namespace LogcatMini.Core;
public sealed class Preferences
{
    public string Theme {get;set;}="nightfall";
    public double FontSize {get;set;}=14;
    public double SidebarWidth {get;set;}=300;
    public double DetailHeight {get;set;}=240;
    public string? AdbPath {get;set;}
    public bool ShowSystemApps {get;set;}
    public string? RecorderPath {get;set;}
    public Dictionary<string,string> DevicePackages {get;set;}=[];
    public string Serial {get;set;}="";
    public string Package {get;set;}="";
    public HashSet<string> Favorites {get;set;}=[];
    public FilterHistory FilterHistory {get;set;}=new();
    public HashSet<string> Columns {get;set;}=["level","time","tag","pid","message"];
    public static string DirectoryPath=>Environment.GetEnvironmentVariable("LOGCAT_MINI_DATA_DIR")??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LogcatMiniWindows");
    public static Preferences Load(string? path=null)
    {
        Preferences p;
        try{p=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path??Path.Combine(DirectoryPath,"settings.json")))??new();}
        catch(Exception e)when(e is IOException or JsonException or UnauthorizedAccessException){p=new();}
        p.FontSize=double.IsFinite(p.FontSize)?Math.Clamp(p.FontSize,10,26):14;
        p.SidebarWidth=double.IsFinite(p.SidebarWidth)?Math.Clamp(p.SidebarWidth,240,680):300;
        p.DetailHeight=double.IsFinite(p.DetailHeight)?Math.Clamp(p.DetailHeight,140,1000):240;
        p.Favorites=p.Favorites?.Where(AndroidPackage.ValidPackage).ToHashSet()??[];
        p.DevicePackages??=[];p.FilterHistory??=new();p.FilterHistory.Normalize();
        p.Columns=p.Columns?.Where(c=>new[]{"level","time","tag","pid","message"}.Contains(c)).ToHashSet()??[];
        if(p.Columns.Count==0)p.Columns.Add("message");p.Serial??="";p.Package??="";p.Theme??="nightfall";
        return p;
    }
    public void Save(string? path=null)
    {
        path??=Path.Combine(DirectoryPath,"settings.json");Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path+".tmp",JsonSerializer.Serialize(this,new JsonSerializerOptions{WriteIndented=true}));File.Move(path+".tmp",path,true);
    }
}
