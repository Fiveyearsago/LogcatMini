using System.Text.Json;
using LogcatMini.Core;

static class ParityChecks
{
    public static async Task Run(Action<bool,string> check,string[] args)
    {
        var input="onEvent(): lc_api_request, info = {endpoint=/incentive/v1/task/config, result=success, duration_ms=131, http_code=200}";
        var output=FormattedLog.Parse(input)!;
        check(output.Json is null&&output.Text=="onEvent(): lc_api_request,\ninfo = {\n  endpoint=/incentive/v1/task/config,\n  result=success,\n  duration_ms=131,\n  http_code=200\n}","Mac Android Map formatter parity");
        input="request url=https://[::1]:8443/a(b)?x=a,b=c&sign=abc==#node key=next time=15:25:26.889 ip=127.0.0.1:443 token=YWJjZA== msg=\"hello  world, a=b \\\"quoted\\\"\" end=true";
        output=FormattedLog.Parse(input)!;
        check(output.Text.Contains("url=https://[::1]:8443/a(b)?x=a,b=c&sign=abc==#node\nkey=next")&&output.Text.Contains("token=YWJjZA==\nmsg=\"hello  world"),"formatter protects URLs, IPv6, base64 and quoted whitespace");
        input="event=done data=User(name=\"张三, key=fake\", children=[Child(id=1, active=true), Child(id=2, active=false)]) id=3 id=4";
        output=FormattedLog.Parse(input)!;
        check(output.Text.Contains("\n  children=[Child(\n      id=1,")&&output.Text.EndsWith("id=3\nid=4"),"nested Android objects and repeated keys preserve order");
        check(KeyValueFormatter.Format("Beyla Event = eventType:0#eventName:lc_api_request#result:success; duration:544")!.Contains("\neventType:0#\neventName:lc_api_request#\nresult:success;\nduration:544"),"colon, hash and semicolon field layout matches Mac");
        foreach(var plain in new[]{"hello world\n\tat Example.kt:42\n\tat foo.bar(Baz.java:23)","https://host/path?a=1&b=2","15:26:60.123","cacheData == null","data={a=1, msg=\"unterminated"})check(FormattedLog.Parse(plain)?.Text==plain,"unstructured or damaged log remains untouched");
        var deep=new string('{',129)+"a=1"+new string('}',129);check(FormattedLog.Parse(deep)?.Text==deep&&FormattedLog.Parse(new string('a',2*1024*1024+1)) is null,"formatter resource limits fall back safely");
        var json="{\"n\":123456789012345678901234567890,\"same\":1,\"same\":2,\"array\":[true,{\"emoji\":\"😀中文\",\"exp\":1.00e+19}]}";
        var parsed=FormattedLog.Parse(json)!;using var doc=JsonDocument.Parse(parsed.Text);
        check(doc.RootElement.GetProperty("n").GetRawText()=="123456789012345678901234567890"&&parsed.Text.Contains("1.00e+19")&&doc.RootElement.EnumerateObject().Count(p=>p.Name=="same")==2,"formatted JSON remains parseable with arrays, duplicate keys and exact numbers");
        var escaped=JsonLog.Parse("{\"\\u4e2d\":\"\\u6587\",\"a\\/b\":1}")!;check(escaped.FormattedText.Contains("\"\\u4e2d\"")&&escaped.FormattedText.Contains("\"a\\/b\""),"JSON property names preserve original escape tokens");
        var folded=JsonRows.Visible(parsed.Json!,[]);check(folded.Count==1&&parsed.Text.Contains("emoji"),"collapsed display and complete formatted copy remain independent");
        var dir=Path.Combine(Path.GetTempPath(),"LogcatMini 媒体 QA "+Guid.NewGuid());Directory.CreateDirectory(dir);
        string? previous=Environment.GetEnvironmentVariable("LOGCAT_MINI_DATA_DIR");Environment.SetEnvironmentVariable("LOGCAT_MINI_DATA_DIR",dir);
        try
        {
            var library=new MediaLibrary();library.SetDirectory("screenshot",Path.Combine(dir,"first"));var device=new AndroidDevice("serial:5555","测试设备","device");
            string first=library.Destination("screenshot",device);File.WriteAllBytes(first,[1]);library.Add(new(first,"screenshot",device.Name,device.Serial,DateTime.Now));
            library.SetDirectory("recording",Path.Combine(dir,"movies"));library.SetDirectory("screenshot",Path.Combine(dir,"second"));library=MediaLibrary.Load();
            check(library.Items.Count==1&&library.Items[0].Exists&&library.ScreenshotDirectory!.EndsWith("second")&&library.RecordingDirectory!.EndsWith("movies"),"media history and independent folders survive reload and folder changes");
            File.Delete(first);check(!MediaLibrary.Load().Items[0].Exists,"missing capture retains its history with missing-file state");
            var prefs=new Preferences{ShowSystemApps=true,DevicePackages=new(){{"A","com.test.a"},{"B","com.test.b"}}};prefs.Save();prefs=Preferences.Load();check(prefs.ShowSystemApps&&prefs.DevicePackages["A"]=="com.test.a"&&prefs.DevicePackages["B"]=="com.test.b","system apps and device-specific package selections persist");
            var name=library.Destination("screenshot",device);File.WriteAllText(name,"reserved");check(library.Destination("screenshot",device)!=name,"capture naming never reuses an existing file");
            bool invalid=false;try{DeviceCapture.ValidatePNG([1,2,3]);}catch(IOException){invalid=true;}check(invalid,"invalid screenshot output rejected before writing");
            check(ScreenRecording.Arguments("serial with spaces","C:\\movie dir\\one.mp4").Contains("C:\\movie dir\\one.mp4")==false&&ScreenRecording.Arguments("serial with spaces","C:\\movie dir\\one.mp4")[1]=="serial with spaces","recorder passes paths and serial via separate arguments");
            if(args.Contains("--media-device"))
            {
                var adb=new AdbClient(AdbClient.Locate()??throw new Exception("ADB unavailable"));var actual=AndroidDevice.Parse(await adb.Run(["devices","-l"])).First(d=>d.Serial=="demo-device-001"&&d.Ready);
                string png=Path.Combine(dir,"real.png");await DeviceCapture.Screenshot(adb,actual.Serial,png);check(new FileInfo(png).Length>1000,"PJD110 real binary screenshot saved");
                string runtime=Environment.GetEnvironmentVariable("LOGCAT_MINI_TEST_RECORDER")??throw new Exception("Set LOGCAT_MINI_TEST_RECORDER");
                var recording=new ScreenRecording(adb.Path,actual.Serial,runtime);await Task.Delay(3500);await recording.Stop();
                bool failed=false;try{await recording.SaveWhenFinished(Path.Combine(dir,"missing","failure.mp4"));}catch(IOException){failed=true;}
                check(failed&&File.Exists(recording.TemporaryMovie),"recording save failure retains local MP4 for retry");
                string movie=Path.Combine(dir,"retry.mp4");await recording.SaveWhenFinished(movie);check(new FileInfo(movie).Length>1000&&!File.Exists(recording.TemporaryMovie),"PJD110 recording stops, retries save and cleans its temporary file");
                var evidence=Environment.GetEnvironmentVariable("LOGCAT_MINI_MEDIA_EVIDENCE");if(evidence is not null){Directory.CreateDirectory(evidence);File.Copy(png,Path.Combine(evidence,"PJD110.png"),true);File.Copy(movie,Path.Combine(evidence,"PJD110.mp4"),true);}
            }
        }
        finally{Environment.SetEnvironmentVariable("LOGCAT_MINI_DATA_DIR",previous);Directory.Delete(dir,true);}
    }
}
