using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.Threading;
using LogcatMini.Core;
namespace LogcatMini.Desktop;

/// A continuous native selectable document; only the gutter handles JSON folding.
public sealed class DetailCanvas : UserControl
{
    public Palette Palette=Palette.For("nightfall",true);
    public double TextSize=14;
    public ScrollViewer? Viewer;
    public string Raw="",Query="";
    public int ActiveMatch=-1;
    public JsonLog? Document;
    public bool JsonMode;
    public HashSet<int> Expanded=[];
    public readonly SelectableTextBlock TextView=new(){TextWrapping=TextWrapping.NoWrap,Focusable=true};
    readonly Canvas gutter=new(){Width=24};
    List<(JsonRow Row,int Start)> lines=[];
    FormattedLog? formatted;
    public string VisibleText {get;private set;}="";
    public string CopyText=>JsonMode?formatted?.Text??Raw:Raw;
    public bool CanFormat=>formatted is not null;
    public double LineHeight=>Math.Ceiling(TextSize*1.5+4);
    public event Action? Activated;
    public DetailCanvas()
    {
        Focusable=true;
        var grid=new Grid{ColumnDefinitions=new ColumnDefinitions("24,*"),Margin=new Thickness(8)};
        grid.Children.Add(gutter);Grid.SetColumn(TextView,1);grid.Children.Add(TextView);Content=grid;
        TextView.GotFocus+=(_,_)=>Activated?.Invoke();
        AddHandler(PointerPressedEvent,(_,_)=>Activated?.Invoke(),RoutingStrategies.Tunnel);
    }
    public void SetRecord(LogRecord row)
    {
        Raw=row.FullText;formatted=FormattedLog.Parse(row.Message);Document=formatted?.Json;
        Expanded=Document?.Fragments.Select(f=>f.Root.Id).ToHashSet()??[];
        if(formatted is null)JsonMode=false;ActiveMatch=-1;TextView.ClearSelection();Refresh();
    }
    public void Refresh()
    {
        lines=[];
        if(JsonMode&&Document is {} doc)
        {
            var parts=new List<string>();int offset=0;
            foreach(var row in JsonRows.Visible(doc,Expanded)){string text=new string(' ',row.Depth*2)+row.Text;lines.Add((row,offset));parts.Add(text);offset+=text.Length+1;}
            VisibleText=string.Join('\n',parts);
        }
        else VisibleText=JsonMode?formatted?.Text??Raw:Raw;
        var a=TextView.SelectionStart;var b=TextView.SelectionEnd;
        TextView.FontFamily=Paint.Mono.FontFamily;TextView.FontSize=TextSize;TextView.LineHeight=LineHeight;TextView.Foreground=Palette.Text;TextView.SelectionBrush=Palette.Selection;TextView.SelectionForegroundBrush=null;
        // Partition at syntax and search boundaries, preserving original UTF-16 positions.
        var tokens=new List<(int Start,int End,IBrush Brush)>();
        try{foreach(Match m in Paint.Tokens.Matches(VisibleText))foreach(var kind in new[]{"url","key","string","literal","number"})if(m.Groups[kind].Success){tokens.Add((m.Index,m.Index+m.Length,Palette.Token(kind)));break;}}catch(RegexMatchTimeoutException){}
        var hits=FindText.Ranges(VisibleText,Query);var points=new SortedSet<int>{0,VisibleText.Length};foreach(var t in tokens){points.Add(t.Start);points.Add(t.End);}foreach(var h in hits){points.Add(h.Start);points.Add(h.Start+h.Length);}
        TextView.Inlines!.Clear();var boundaries=points.ToArray();int ti=0,hi=0;
        for(int i=0;i+1<boundaries.Length;i++)
        {
            int start=boundaries[i],end=boundaries[i+1];if(end<=start)continue;
            while(ti<tokens.Count&&tokens[ti].End<=start)ti++;while(hi<hits.Count&&hits[hi].Start+hits[hi].Length<=start)hi++;
            var run=new Run(VisibleText[start..end]){Foreground=ti<tokens.Count&&tokens[ti].Start<=start?tokens[ti].Brush:Palette.Text};
            if(hi<hits.Count&&hits[hi].Start<=start)run.Background=Palette.Brush("#887B6426");TextView.Inlines.Add(run);
        }
        TextView.SelectionStart=Math.Min(a,VisibleText.Length);TextView.SelectionEnd=Math.Min(b,VisibleText.Length);
        gutter.Children.Clear();
        foreach(var (row,start) in lines)
        {
            if(row.Closing||row.Node is not {IsContainer:true,Children.Count:>0} n)continue;
            var button=new Button{Content=new Symbol(Expanded.Contains(n.Id)?"chevronDown":"chevronRight"){Width=12,Height=12},Width=22,Height=LineHeight,Padding=new Thickness(0),Background=Brushes.Transparent,BorderThickness=new Thickness(0),Foreground=Palette.Accent,Focusable=false};
            Avalonia.Automation.AutomationProperties.SetName(button,(Expanded.Contains(n.Id)?"折叠 ":"展开 ")+(n.Key??"JSON"));
            Canvas.SetTop(button,VisibleText.AsSpan(0,start).Count('\n')*LineHeight);button.Click+=(_,_)=>{if(!Expanded.Add(n.Id))Expanded.Remove(n.Id);Refresh();};gutter.Children.Add(button);
        }
        InvalidateMeasure();
    }
    public void ExpandAll(bool expanded){Expanded=expanded?Document?.AllNodes().Where(n=>n.IsContainer).Select(n=>n.Id).ToHashSet()??[]:[];Refresh();}
    public int MatchCount=>FindText.Ranges(JsonMode?formatted?.Text??Raw:Raw,Query).Count;
    public void Find(int delta,bool reset=false)
    {
        if(MatchCount==0){ActiveMatch=-1;Refresh();return;}ActiveMatch=reset?0:(ActiveMatch+delta+MatchCount)%MatchCount;
        if(JsonMode&&Document is {} doc)foreach(var match in JsonRows.Find(doc,Query))Expanded.UnionWith(match.Ancestors);
        Refresh();var hits=FindText.Ranges(VisibleText,Query);if(hits.Count==0)return;var hit=hits[Math.Min(ActiveMatch,hits.Count-1)];
        Dispatcher.UIThread.Post(()=>{if(Viewer is {} v){var rect=TextView.TextLayout.HitTestTextPosition(hit.Start);v.Offset=new Vector(Math.Max(0,rect.X-40),Math.Max(0,rect.Y-40));}},DispatcherPriority.Background);
    }
}
