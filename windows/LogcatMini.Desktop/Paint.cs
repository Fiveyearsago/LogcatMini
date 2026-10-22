using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Media;
using LogcatMini.Core;
namespace LogcatMini.Desktop;
public sealed record Palette(bool Dark,IBrush Canvas,IBrush Panel,IBrush Text,IBrush Muted,IBrush Accent,IBrush Field,IBrush Line,IBrush Chip,IBrush Stripe,IBrush Selection)
{
    public static string[] IDs=["system","mist","paper","nightfall","light","graphite","ocean"];
    public static string[] Names=["跟随系统","雾白","暖纸","夜航蓝","明亮","石墨","深海"];
    public static IBrush Brush(string hex)=>Avalonia.Media.Brush.Parse(hex);
    static Palette Make(bool dark,params string[] c)=>new(dark,Brush(c[0]),Brush(c[1]),Brush(c[2]),Brush(c[3]),Brush(c[4]),Brush(c[5]),Brush(c[6]),Brush(c[7]),Brush(c[8]),Brush(c[9]));
    public static Palette For(string id,bool systemDark)=> (id=="system"?(systemDark?"graphite":"light"):id) switch {
        "mist"=>Make(false,"#F7F9FC","#EDF1F7","#223044","#56667D","#24787D","#FFFFFF","#D8E1ED","#E7EDF5","#F0F4F9","#DCEBF3"),
        "paper"=>Make(false,"#F6F0E5","#EAE3D6","#352F28","#655D50","#4E7055","#FFFAF1","#D8CDBB","#E9E0D0","#F0EADD","#E1E6D4"),
        "light"=>Make(false,"#FAFBFD","#EDF1F5","#202B35","#526170","#00686C","#FFFFFF","#D4DCE4","#E9EEF3","#F0F4F9","#DCEBF3"),
        "graphite"=>Make(true,"#20242A","#292E36","#E8EDF3","#B0BBC7","#8DE0BE","#181D23","#414A55","#303741","#252E39","#2D3D4C"),
        "ocean"=>Make(true,"#152231","#1D2D40","#E4EEF8","#ACBED1","#99C8FF","#101D2B","#384D64","#25384E","#1C2938","#293D50"),
        _=>Make(true,"#182330","#202F40","#DCE5EF","#A2B2C7","#8BBFE8","#13202D","#34495C","#293C50","#1C2938","#293D50")};
    public IBrush Severity(Level l)=>l switch{Level.Debug=>Brush(Dark?"#96DFBB":"#286445"),Level.Info=>Brush(Dark?"#99C8FF":"#185AB0"),Level.Warn=>Brush(Dark?"#F1CE86":"#805308"),Level.Error or Level.Fatal=>Brush(Dark?"#FF9DA4":"#AB2737"),_=>Muted};
    public IBrush Token(string kind)=>Brush((kind,Dark) switch{("key",true)=>"#BCA5DE",("key",false)=>"#7154A2",("string",true)=>"#AACF95",("string",false)=>"#2E704F",("number",true)=>"#E5B47F",("number",false)=>"#9A571B",("literal",true)=>"#D8A0B8",("literal",false)=>"#A14765",("url",true)=>"#8BCBE3",_=>"#236D9D"});
}
public static class Paint
{
    public static readonly Typeface Mono=new(new FontFamily(OperatingSystem.IsWindows()?"Cascadia Mono,Consolas,Microsoft YaHei UI":"Menlo,PingFang SC"));
    internal static readonly Regex Tokens=new("(?<url>https?://[^\\s\\\"<>]+)|(?<key>\\\"(?:[^\\\"\\\\]|\\\\.)*\\\"(?=\\s*:)|[\\p{L}_][\\w.\\-]*(?=\\s*[:=]))|(?<string>\\\"(?:[^\\\"\\\\]|\\\\.)*\\\")|(?<literal>\\b(?:true|false|null|nil)\\b)|(?<number>(?<![\\w])[-+]?\\d+(?:\\.\\d+)?(?:[eE][-+]?\\d+)?\\b)",RegexOptions.Compiled,TimeSpan.FromMilliseconds(50));
    public static FormattedText Text(string s,double size,IBrush brush)=>new(s,CultureInfo.CurrentCulture,FlowDirection.LeftToRight,Mono,size,brush);
    public static FormattedText Styled(string s,double size,Palette p,IBrush? foreground=null)
    {
        var f=Text(s,size,foreground??p.Text);
        try{foreach(Match m in Tokens.Matches(s))foreach(var name in new[]{"url","key","string","literal","number"})if(m.Groups[name].Success){f.SetForegroundBrush(p.Token(name),m.Index,m.Length);break;}}
        catch(RegexMatchTimeoutException){}return f;
    }
    public static void Draw(DrawingContext context,FormattedText text,Point origin,string original,string query,int active=-1)
    {
        var ranges=FindText.Ranges(original,query);for(int i=0;i<ranges.Count;i++)
        {
            var r=ranges[i];var geometry=text.BuildHighlightGeometry(origin,r.Start,r.Length);
            if(geometry is not null)context.DrawGeometry(Palette.Brush(i==active?"#CCAD7224":"#665E531D"),null,geometry);
        }
        context.DrawText(text,origin);
    }
}
