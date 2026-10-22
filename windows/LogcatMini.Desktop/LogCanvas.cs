using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using LogcatMini.Core;
namespace LogcatMini.Desktop;
public sealed class LogCanvas : Control
{
    public IReadOnlyList<LogRecord> Rows {get;private set;}=[];
    public Palette Palette=Palette.For("nightfall",true);
    public double TextSize=14;
    public HashSet<string> Columns=["level","time","tag","pid","message"];
    public string Query="";
    public ScrollViewer? Viewer;
    public bool Header;
    public long? Selected;
    public HashSet<long> Selection=[];
    readonly Dictionary<long,(string Text,double Width)> widths=[];
    double maximumMessageWidth;
    public double HorizontalOffset;
    public double ContentWidth {get;private set;}
    readonly Dictionary<long,FormattedText> messages=[];

    public event Action<LogRecord>? Picked;
    public event Action? ManualScroll;
    public double RowHeight=>Math.Ceiling(TextSize*1.45+9);
    public LogCanvas(){ClipToBounds=true;Focusable=true;}
    public void SetRows(IReadOnlyList<LogRecord> rows){Rows=rows;Height=Header?30:Math.Max(1,rows.Count*RowHeight);messages.Clear();UpdateWidth(true);InvalidateVisual();}
    public void Clear(){widths.Clear();messages.Clear();Selection.Clear();Selected=null;HorizontalOffset=0;if(Viewer is {} v)v.Offset=default;UpdateWidth();}
    public void RefreshStyle(){messages.Clear();widths.Clear();Height=Header?30:Math.Max(1,Rows.Count*RowHeight);UpdateWidth(true);InvalidateVisual();}
    public void UpdateWidth(bool measureRows=false)
    {
        if(Header)return;
        if(measureRows){
        double longest=0;
        if(Columns.Contains("message"))foreach(var row in Rows){if(!widths.TryGetValue(row.Id,out var cached)||cached.Text!=row.Message){cached=(row.Message,Paint.Text(row.DisplayMessage.Replace('\n',' '),TextSize,Palette.Text).WidthIncludingTrailingWhitespace);widths[row.Id]=cached;}longest=Math.Max(longest,cached.Width);}
        // Width cache stores numbers only, not thousands of shaped text objects.
        if(widths.Count>Rows.Count+1000){var ids=Rows.Select(r=>r.Id).ToHashSet();foreach(var id in widths.Keys.Where(id=>!ids.Contains(id)).ToArray())widths.Remove(id);}
        maximumMessageWidth=longest;}
        double fixedWidth=Columns.Sum(id=>id switch{"level"=>50,"time"=>148,"tag"=>220,"pid"=>80,_=>0})*TextSize/14;
        ContentWidth=Math.Max(Viewer?.Viewport.Width??0,fixedWidth+(Columns.Contains("message")?maximumMessageWidth+32:0));Width=Math.Max(1,ContentWidth);
        InvalidateVisual();
    }
    public List<(string Id,double X,double Width)> Layout()
    {
        var result=new List<(string,double,double)>();var ids=new[]{"level","time","tag","pid","message"}.Where(Columns.Contains).ToArray();
        double available=Math.Max(0,Header?ContentWidth:Bounds.Width),fixedWidth=ids.Sum(id=>id switch{"level"=>50,"time"=>148,"tag"=>220,"pid"=>80,_=>0})*TextSize/14;
        double scale=1;double x=0;
        foreach(var id in ids){double w=id switch{"level"=>50,"time"=>148,"tag"=>220,"pid"=>80,_=>0};w=id=="message"?Math.Max(0,available-x):w*TextSize/14*scale;result.Add((id,x,w));x+=w;}return result;
    }
    public override void Render(DrawingContext context)
    {
        base.Render(context);double top=Header?0:Viewer?.Offset.Y??0;double height=Header?30:Viewer?.Viewport.Height??Bounds.Height;
        context.FillRectangle(Header?Palette.Panel:Palette.Canvas,new Rect(0,top,Bounds.Width,height));var columns=Layout();
        if(Header){foreach(var c in columns)context.DrawText(Paint.Text(c.Id switch{"level"=>"等级","time"=>"时间","tag"=>"Tag","pid"=>"PID",_=>"消息"},12,Palette.Muted),new Point(c.X+8-HorizontalOffset,7));return;}
        int first=Math.Max(0,(int)(top/RowHeight)),last=Math.Min(Rows.Count,(int)Math.Ceiling((top+height)/RowHeight)+1);
        for(int i=first;i<last;i++)
        {
            var row=Rows[i];double y=i*RowHeight;bool chosen=Selection.Contains(row.Id)||row.Id==Selected;var rect=new Rect(0,y,Bounds.Width,RowHeight);
            context.FillRectangle(chosen?Palette.Selection:(i%2==0?Palette.Canvas:Palette.Stripe),rect);
            if(chosen){context.FillRectangle(Palette.Accent,new Rect(0,y,3,RowHeight));context.DrawLine(new Pen(Palette.Accent,0.5),new Point(0,y+RowHeight-.5),new Point(Bounds.Width,y+RowHeight-.5));}
            foreach(var c in columns)
            {
                if(c.Width<3)continue;bool msg=c.Id=="message";string value=c.Id switch{"level"=>row.Letter,"time"=>row.Time,"tag"=>row.Tag,"pid"=>row.Pid,_=>row.DisplayMessage.Replace('\n',' ')};
                FormattedText f;if(msg){if(!messages.TryGetValue(row.Id,out f!)){f=Paint.Styled(value,TextSize,Palette,Palette.Severity(row.Level));messages[row.Id]=f;}}else f=Paint.Text(value,TextSize,Palette.Severity(row.Level));
                double dx=0;
                using(context.PushClip(new Rect(c.X+6,y,Math.Max(0,c.Width-(msg?22:12)),RowHeight)))Paint.Draw(context,f,new Point(c.X+8-dx,y+4),value,Query);

            }
        }
        if(messages.Count>300){var keep=Rows.Skip(first).Take(last-first).Select(r=>r.Id).ToHashSet();foreach(var id in messages.Keys.Where(k=>!keep.Contains(k)).ToArray())messages.Remove(id);}
    }
    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);if(Header)return;var point=e.GetPosition(this);int i=(int)(point.Y/RowHeight);if(i<0||i>=Rows.Count)return;// Focus must not scroll the huge canvas into view.
        Focus();var row=Rows[i];
        if(e.KeyModifiers.HasFlag(KeyModifiers.Shift)&&Selected is {} anchor){int a=Rows.ToList().FindIndex(r=>r.Id==anchor);if(a>=0)for(int n=Math.Min(a,i);n<=Math.Max(a,i);n++)Selection.Add(Rows[n].Id);}
        else if(e.KeyModifiers.HasFlag(KeyModifiers.Control)||e.KeyModifiers.HasFlag(KeyModifiers.Meta)){if(!Selection.Add(row.Id))Selection.Remove(row.Id);}
        else{Selection.Clear();Selection.Add(row.Id);}Selected=row.Id;Picked?.Invoke(row);InvalidateVisual();e.Handled=true;
    }
    public void SyncHeader(double width,double offset){ContentWidth=width;HorizontalOffset=offset;InvalidateVisual();}
    public void HandleWheel(PointerWheelEventArgs e)
    {
        bool horizontal=Math.Abs(e.Delta.X)>Math.Abs(e.Delta.Y)||e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        if(horizontal)Slide(-(Math.Abs(e.Delta.X)>Math.Abs(e.Delta.Y)?e.Delta.X:e.Delta.Y)*48);
        else if(Viewer is {} v)v.Offset=new Vector(v.Offset.X,Math.Max(0,v.Offset.Y-e.Delta.Y*RowHeight*3));
        e.Handled=true;ManualScroll?.Invoke();
    }
    void Slide(double amount)
    {
        if(Viewer is {} v)v.Offset=new Vector(Math.Clamp(v.Offset.X+amount,0,Math.Max(0,ContentWidth-v.Viewport.Width)),v.Offset.Y);
    }
    public void Reveal(int index)
    {
        if(index<0||index>=Rows.Count)return;var r=Rows[index];Selected=r.Id;Selection.Clear();Selection.Add(r.Id);
        if(Viewer is {} v){double x=v.Offset.X;int hit=string.IsNullOrEmpty(Query)?-1:r.DisplayMessage.IndexOf(Query,StringComparison.OrdinalIgnoreCase);if(hit>=0&&Columns.Contains("message")){var col=Layout().First(c=>c.Id=="message");double left=col.X+8+Paint.Text(r.DisplayMessage[..hit],TextSize,Palette.Text).Width;double right=left+Paint.Text(Query,TextSize,Palette.Text).Width;if(left<x||right>x+v.Viewport.Width)x=Math.Max(0,left-40);}v.Offset=new Vector(x,Math.Max(0,index*RowHeight-v.Viewport.Height/3));}
        Picked?.Invoke(r);InvalidateVisual();
    }
    protected override void OnKeyDown(KeyEventArgs e)
    {
        if(e.Key is Key.Left or Key.Right && Selected is {} id && Rows.FirstOrDefault(r=>r.Id==id) is {} row){Slide(e.Key==Key.Right?180:-180);ManualScroll?.Invoke();e.Handled=true;}
        else if(e.Key is Key.Up or Key.Down){int i=Rows.ToList().FindIndex(r=>r.Id==Selected);Reveal(Math.Clamp(i+(e.Key==Key.Down?1:-1),0,Math.Max(0,Rows.Count-1)));e.Handled=true;}
        base.OnKeyDown(e);
    }
}
