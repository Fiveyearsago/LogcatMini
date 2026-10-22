using System.Text.Json;
using LogcatMini.Core;

int passed=0;
void Check(bool ok,string name){if(!ok)throw new Exception("FAIL: "+name);Console.WriteLine("PASS "+name);passed++;}
LogRecord R(string message,long id=1,string time="12:00:00.100",string tag="Test",string tid="34",Level level=Level.Debug)=>new(id,"2026-10-13",time,"12",tid,level,tag,message,$"2026-10-13 {time} 12 {tid} {"VDIWEF"[(int)level]} {tag}: {message}");
var parsed=LogParser.Parse("2026-10-13 11:25:11.081 14832 16730 D MD.Test: 11:25:11.079[11549] interval = 1",1)!;
Check(parsed.Level==Level.Debug&&parsed.Tag=="MD.Test"&&parsed.DisplayMessage=="interval = 1","threadtime parse and framework timestamp cleanup");
Check(parsed.Raw.Contains("11:25:11.079"),"original detail preserves complete source");
Check(LogParser.Clean("11:25:11.079 scheduled event")=="11:25:11.079 scheduled event","legitimate timestamp is not removed");
Check(LogParser.Parse("--------- beginning of main",2)==null,"buffer separator is ignored");
Check(LogParser.Parse("10-13 12:00:00.001 12 34 A Crash: abort",2)?.Level==Level.Fatal,"legacy date and assert severity");
var b=new LogBuffer();
var fixture=File.ReadAllLines(Path.Combine(AppContext.BaseDirectory,"Fixtures/task-config-parts.log")).Where(s=>s.Length>0).Select((s,i)=>LogParser.Parse(s,i+1)!).ToArray();
b.Append(fixture);
Check(b.Entries.Count==1&&b.Entries[0].Parts==3,"synthetic three-part config becomes one record");
Check(b.Entries[0].Message.Contains("result={")&&!b.Entries[0].Message.Contains("result_part="),"merged result field contains full payload");
Check(!b.Entries[0].FullText.Contains("result_part=")&&b.Entries[0].FullText.Split('\n').Length==1,"copy/export uses one reconstructed record");
Check(JsonLog.Parse(b.Entries[0].Message)?.Fragments.Count==1,"synthetic merged payload parses as JSON");
foreach(var bad in new[]{new[]{R("result_part=1/2 result=a"),R("result_part=2/2 result=b",3)},new[]{R("result_part=1/2 result=a"),R("result_part=2/2 result=b",2,tid:"35")},new[]{R("result_part=1/2 result=a"),R("result_part=2/2 result=b",2,time:"12:00:03.000")},new[]{R("result_part=1/2 result=a"),R("unrelated",2),R("result_part=2/2 result=b",3)}})
{var buffer=new LogBuffer();buffer.Append(bad);Check(buffer.Entries.Count==bad.Length,"ambiguous or interrupted chunks remain separate");}
Check(new LogFilter(query:"missing | INTERVAL",tag:"Other|MD.Test").Matches(parsed),"OR keywords per field and AND across fields");
Check(!new LogFilter(Level.Error,query:"interval").Matches(parsed),"minimum severity filter");
Check(new LogFilter(query:@"interval\s*=\s*\d+",regex:true).Matches(parsed),"regex filter");
bool rejected=false;try{_ = new LogFilter(query:"[",regex:true);}catch(ArgumentException){rejected=true;}Check(rejected,"invalid regex rejected");
Check(FindText.Ranges("中文 a😀A 中", "a").Select(r=>r.Start).SequenceEqual(new[]{3,6}),"case-insensitive UTF-16 find offsets");
var j=JsonLog.Parse("result={\"n\":123456789012345678901234567890,\"s\":\"brace } inside\",\"items\":[{\"needle\":true}]} end")!;
Check(j.Fragments[0].Prefix=="result="&&j.Suffix==" end","JSON preserves surrounding log content");
Check(j.AllNodes().Any(n=>n.Value=="123456789012345678901234567890"),"JSON preserves integer precision");
var hits=JsonRows.Find(j,"needle");var rows=JsonRows.Visible(j,hits[0].Ancestors);
Check(rows.Any(r=>r.Node?.Id==hits[0].Node),"JSON search expands hidden ancestor path");
Check(JsonLog.Parse("bad {\"incomplete\":") is null,"incomplete JSON stays raw");
Check(JsonLog.Parse("first={\"a\":1} next=[false]")?.Fragments.Count==2,"multiple JSON fragments");
Check(AndroidDevice.Parse("List of devices attached\nabc device model:Pixel_6 transport_id:1\nbad unauthorized\n").Count==2,"device list and authorization states");
Check(AndroidPackage.Parse("package:com.example.test uid:10123\npackage:bad;rm uid:1").Count==1,"package and UID parsing validates identifiers");
Check(!AndroidPackage.ValidPackage("app; rm -rf /"),"package arguments cannot contain shell syntax");
rejected=false;try{AdbClient.CaptureCommand("1;echo bad");}catch(ArgumentException){rejected=true;}Check(rejected,"capture UID cannot inject shell commands");
Check(AdbClient.CaptureCommand("10123").Contains("--uid=10123")&&AdbClient.CaptureCommand(null).Contains("$(date"),"UID filter and fresh-session start command");
using(var process=new AdbClient(@"C:\Program Files\platform-tools\adb.exe").MakeProcess(["-s","device with spaces","shell","echo hello"]))Check(!process.StartInfo.UseShellExecute&&process.StartInfo.ArgumentList[1]=="device with spaces","Windows executable paths and arguments remain separate");
var temp=Path.Combine(Path.GetTempPath(),"logcat-mini-checks-"+Guid.NewGuid());Directory.CreateDirectory(temp);
try{
var path=Path.Combine(temp,"settings.json");var prefs=new Preferences{Theme="paper",FontSize=18,SidebarWidth=412,Favorites=["com.example.test"],Columns=["time","message"]};prefs.Save(path);var restored=Preferences.Load(path);
Check(restored.Theme=="paper"&&restored.FontSize==18&&restored.SidebarWidth==412&&restored.Favorites.SetEquals(prefs.Favorites)&&restored.Columns.SetEquals(prefs.Columns),"settings round trip persists favorites, theme, size and columns");
var saved=new SavedLogFilter("request|请求","MD.Network",true,Level.Warn);
prefs.FilterHistory.Remember(saved);prefs.FilterHistory.ToggleFavorite(saved);
for(int i=0;i<45;i++)prefs.FilterHistory.Remember(new SavedLogFilter("term"+i));
Check(prefs.FilterHistory.Entries.Count==31&&prefs.FilterHistory.Ordered.First().Filter==saved,"30 recents with favorites pinned and exempt from eviction");
prefs.FilterHistory.Remember(saved);prefs.FilterHistory.Remember(saved);
Check(prefs.FilterHistory.Entries.Count==31&&prefs.FilterHistory.IsFavorite(saved),"duplicate combinations move to front without losing favorite");
prefs.Save(path);restored=Preferences.Load(path);
Check(restored.FilterHistory.IsFavorite(saved)&&restored.FilterHistory.Entries.Count==31,"filter combination and favorite survive settings reload");
restored.FilterHistory.ClearRecent();restored.Save(path);restored=Preferences.Load(path);
Check(restored.FilterHistory.Entries.Count==1&&restored.FilterHistory.IsFavorite(saved),"clear history preserves favorite after restart");
restored.FilterHistory.ToggleFavorite(saved);restored.Save(path);
Check(!Preferences.Load(path).FilterHistory.IsFavorite(saved),"unfavorite persists");
var history=new FilterHistory();history.Remember(new SavedLogFilter("  "));history.Remember(new SavedLogFilter("[",Regex:true));Check(history.Entries.Count==0,"empty and invalid regex are excluded from history");
history.Remember(new SavedLogFilter(Tag:"Network"));history.Remember(new SavedLogFilter(Minimum:Level.Error));history.Remember(new SavedLogFilter(" x",Regex:true));Check(history.Entries.Count==3&&history.Entries[0].Filter.Query==" x","Tag-only and level-only filters saved; regex whitespace preserved");
File.WriteAllText(path,"{\"FilterHistory\":{\"Entries\":[null,{\"Filter\":null},{\"Filter\":{\"Query\":\"bad\",\"Minimum\":99}}]}}");Check(Preferences.Load(path).FilterHistory.Entries.Count==0,"malformed filter entries sanitized");
File.WriteAllText(path,"{\"Columns\":[],\"Favorites\":null,\"FontSize\":999}");restored=Preferences.Load(path);Check(restored.Columns.SetEquals(["message"])&&restored.FontSize==26,"corrupt preference values sanitized");
File.WriteAllText(path,"not-json");Check(Preferences.Load(path).FontSize==14,"malformed settings use defaults");
}finally{Directory.Delete(temp,true);}
var big=new LogBuffer();big.Append(Enumerable.Range(1,100001).Select(i=>R("interval=1",i)));Check(big.Entries.Count==100001&&big.Entries[0].Id==1,"100001 records retained without old 30000 cap");Check(new LogBuffer().Entries.Count==0,"new session has no restored history");
if(args.Contains("--device")){
    var serial=Environment.GetEnvironmentVariable("LOGCAT_MINI_DEVICE")??throw new Exception("Set LOGCAT_MINI_DEVICE to an authorized test device serial");
    var packageId=Environment.GetEnvironmentVariable("LOGCAT_MINI_PACKAGE")??throw new Exception("Set LOGCAT_MINI_PACKAGE to an installed test package");
    var adb=new AdbClient(AdbClient.Locate()??throw new Exception("ADB unavailable"));var dev=AndroidDevice.Parse(await adb.Run(["devices","-l"])).First(d=>d.Serial==serial&&d.Ready);
    var packages=AndroidPackage.Parse(await adb.Device(dev.Serial,["shell","pm","list","packages","-3","-U"]));Check(packages.Any(p=>p.Id==packageId),"Authorized device actual package and UID read");
    string metadataDir=Path.Combine(Path.GetTempPath(),"logcat-mini-metadata-"+Guid.NewGuid());try{var service=new MetadataService(metadataDir,Path.GetFullPath("Sources/LogcatMini/Resources/AppMetadata.jar"));var data=await service.Refresh(adb,dev.Serial,[packageId],default);Check(!string.IsNullOrWhiteSpace(data[packageId].Label)&&data[packageId].IconPNG is {Length:>100},"Authorized device actual favorite label and icon");Check(service.Load(dev.Serial)[packageId].Label==data[packageId].Label,"metadata cache round trip");}finally{if(Directory.Exists(metadataDir))Directory.Delete(metadataDir,true);}
    string tag="LogcatMiniWinQA",mark=Guid.NewGuid().ToString("N");List<string> received=[];using var cts=new CancellationTokenSource(TimeSpan.FromSeconds(12));var capture=adb.Capture(dev.Serial,null,line=>{lock(received)received.Add(line);},cts.Token);
    await Task.Delay(700);await adb.Device(dev.Serial,["shell","log","-p","i","-t",tag,mark]);for(int i=0;i<30;i++){await Task.Delay(100);lock(received)if(received.Any(l=>l.Contains(mark)))break;}cts.Cancel();await capture;Check(received.Any(l=>l.Contains(mark)&&LogParser.Parse(l,1)?.Tag==tag),"Authorized device real live log received and owned capture stopped");
}
await ParityChecks.Run(Check,args);
Console.WriteLine($"PASS {passed} checks");
