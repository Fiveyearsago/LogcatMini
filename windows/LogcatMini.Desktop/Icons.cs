using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Layout;
using Avalonia.Automation;
namespace LogcatMini.Desktop;

/// Font-independent, monochrome 24-point vector symbols shared by every toolbar.
public sealed class Symbol : Control
{
    public static readonly StyledProperty<IBrush?> ForegroundProperty = Avalonia.Controls.Primitives.TemplatedControl.ForegroundProperty.AddOwner<Symbol>();
    public IBrush? Foreground { get=>GetValue(ForegroundProperty); set=>SetValue(ForegroundProperty,value); }
    public string SymbolName { get; }
    static readonly Dictionary<string,string> Paths = new()
    {
        ["play"]="M7 4 L20 12 L7 20 Z", ["pause"]="M6 4 L10 4 L10 20 L6 20 Z M14 4 L18 4 L18 20 L14 20 Z", ["stop"]="M5 5 L19 5 L19 19 L5 19 Z",
        ["trash"]="M3 6 L21 6 M9 6 L9 3 L15 3 L15 6 M5 6 L6.5 21 L17.5 21 L19 6 M9 9 L9.5 18 M15 9 L14.5 18",
        ["export"]="M12 15 L12 2 M8 6 L12 2 L16 6 M7 9 L5 9 Q3 9 3 11 L3 20 Q3 22 5 22 L19 22 Q21 22 21 20 L21 11 Q21 9 19 9 L17 9",
        ["search"]="M16 16 L22 22 M18 10 A8 8 0 1 1 2 10 A8 8 0 1 1 18 10",
        ["chevronRight"]="M8 4 L16 12 L8 20",["chevronDown"]="M4 8 L12 16 L20 8",
        ["filter"]="M3 5 L21 5 M6 12 L18 12 M9 19 L15 19", ["close"]="M5 5 L19 19 M19 5 L5 19",
        ["expand"]="M3 9 L3 3 L9 3 M3 3 L10 10 M15 21 L21 21 L21 15 M21 21 L14 14",
        ["restore"]="M3 10 L10 10 L10 3 M10 10 L3 3 M14 21 L14 14 L21 14 M14 14 L21 21",
        ["copy"]="M9 7 L20 7 L20 21 L9 21 Z M15 7 L15 3 L4 3 L4 17 L9 17",
        ["format"]="M8 3 L6 3 Q4 3 4 5 L4 9 Q4 12 2 12 Q4 12 4 15 L4 19 Q4 21 6 21 L8 21 M16 3 L18 3 Q20 3 20 5 L20 9 Q20 12 22 12 Q20 12 20 15 L20 19 Q20 21 18 21 L16 21",
        ["refresh"]="M20 5 L20 11 L14 11 M20 10 A8 8 0 1 0 20 16", ["down"]="M12 3 L12 21 M6 15 L12 21 L18 15", ["up"]="M12 21 L12 3 M6 9 L12 3 L18 9",
        ["check"]="M4 12 L9 17 L20 6", ["star"]="M12 2 L15 8 L22 9 L17 14 L18 22 L12 18 L6 22 L7 14 L2 9 L9 8 Z",
        ["camera"]="M3 7 L7 7 L9 4 L15 4 L17 7 L21 7 L21 21 L3 21 Z M16 13 A4 4 0 1 1 8 13 A4 4 0 1 1 16 13",
        ["record"]="M22 12 A10 10 0 1 1 2 12 A10 10 0 1 1 22 12 M16 12 A4 4 0 1 1 8 12 A4 4 0 1 1 16 12",
        ["history"]="M6 3 L21 3 L21 18 L6 18 Z M3 6 L3 21 L18 21 M8 14 L12 10 L16 14 L18 12 L21 15",
        ["folder"]="M2 5 L9 5 L12 8 L22 8 L22 21 L2 21 Z", ["apps"]="M3 3 L10 3 L10 10 L3 10 Z M14 3 L21 3 L21 10 L14 10 Z M3 14 L10 14 L10 21 L3 21 Z M14 14 L21 14 L21 21 L14 21 Z",
        ["terminal"]="M2 3 L22 3 L22 21 L2 21 Z M6 8 L10 12 L6 16 M13 16 L18 16",
        ["settings"]="M9 2 L15 2 L16 5 L19 5 L22 10 L20 12 L22 14 L19 19 L16 19 L15 22 L9 22 L8 19 L5 19 L2 14 L4 12 L2 10 L5 5 L8 5 Z M16 12 A4 4 0 1 1 8 12 A4 4 0 1 1 16 12",
        ["columns"]="M3 4 L21 4 L21 20 L3 20 Z M9 4 L9 20 M15 4 L15 20", ["plus"]="M12 4 L12 20 M4 12 L20 12", ["minus"]="M4 12 L20 12"
    };
    readonly Geometry geometry;
    readonly bool filled;
    static Symbol(){AffectsRender<Symbol>(ForegroundProperty);}
    public Symbol(string name,bool fill=false){SymbolName=name;filled=fill||name is "pause" or "play" or "stop";geometry=Geometry.Parse(Paths[name]);Width=Height=18;VerticalAlignment=VerticalAlignment.Center;IsHitTestVisible=false;}
    public override void Render(DrawingContext context)
    {
        using(context.PushTransform(Matrix.CreateScale(Bounds.Width/24,Bounds.Height/24)))context.DrawGeometry(filled?Foreground:null,filled?null:new Pen(Foreground,1.7,lineCap:PenLineCap.Round,lineJoin:PenLineJoin.Round),geometry);
    }
    public static void Set(Button button,string icon,string title,bool filled=false,string? shortcut=null)
    {
        var signature=(icon,title,filled,shortcut);if(button.Tag is ValueTuple<string,string,bool,string?> old&&old==signature)return;button.Tag=signature;
        var panel=new StackPanel{Orientation=Orientation.Horizontal,Spacing=8,VerticalAlignment=VerticalAlignment.Center};panel.Children.Add(new Symbol(icon,filled));
        if(title.Length>0)panel.Children.Add(new TextBlock{Text=title,VerticalAlignment=VerticalAlignment.Center});
        if(shortcut is not null)panel.Children.Add(new TextBlock{Text=shortcut,FontSize=10,Opacity=.65,VerticalAlignment=VerticalAlignment.Center});
        button.Content=panel;AutomationProperties.SetName(button,title.Length>0?title:icon);
    }
}
