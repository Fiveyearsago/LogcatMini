using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Threading;
using LogcatMini.Core;
namespace LogcatMini.Desktop;

public sealed partial class MainWindow
{
    readonly ComboBox filterHistory=new(){PlaceholderText="历史 / 收藏",Width=130,MaxDropDownHeight=420,HorizontalAlignment=HorizontalAlignment.Stretch};
    readonly Button filterFavorite=new();
    readonly List<Button> levelButtons=[];
    bool updatingHistory,restoringFilter;
    SavedLogFilter? lastRememberedFilter;
    SavedLogFilter CurrentFilter=>new SavedLogFilter(filterQuery.Text??"",tagQuery.Text??"",regex.IsChecked==true,(Level)Math.Max(0,level.SelectedIndex)).Normalized();

    Control BuildFilters()
    {
        var filters=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto,Auto,Auto,170")};
        var field=new Grid{ColumnDefinitions=new ColumnDefinitions("26,*"),Margin=new Thickness(8,0)};
        At(field,new Symbol("filter"),0);At(field,filterQuery,0,1);At(filters,field,0,0);
        At(filters,regex,0,1);
        Setup(filterFavorite,"☆",ToggleFilterFavorite,"收藏整组过滤条件，再次点击取消收藏");filterFavorite.Margin=new Thickness(6,0);At(filters,filterFavorite,0,2);
        At(filters,Horizontal(filterHistory,IconButton("search","",OpenFilterHistory,"搜索历史与收藏")),0,3);tagQuery.Margin=new Thickness(8,0,0,0);At(filters,tagQuery,0,4);
        RefreshFilterHistory();
        filterHistory.DropDownOpened+=(_,_)=>RememberFilter();
        filterHistory.SelectionChanged+=(_,_)=>{
            if(updatingHistory||filterHistory.SelectedItem is not ComboBoxItem item)return;
            filterHistory.IsDropDownOpen=false;
            if(item.Tag is SavedLogFilter saved)RestoreFilter(saved);
            else if(item.Tag is string action&&action=="clear"){prefs.FilterHistory.ClearRecent();lastRememberedFilter=CurrentFilter;Save();RefreshFilterHistory();}
        };
        foreach(var input in new[]{filterQuery,tagQuery})input.KeyDown+=(_,e)=>{if(e.Key==Key.Enter){RememberFilter();e.Handled=true;}};
        // Leaving the group saves one completed combination, including Tag/regex/level edits.
        foreach(var control in new Control[]{filterQuery,tagQuery,regex,level})control.LostFocus+=(_,_)=>Dispatcher.UIThread.Post(()=>{
            if(!filterQuery.IsKeyboardFocusWithin&&!tagQuery.IsKeyboardFocusWithin&&!regex.IsKeyboardFocusWithin&&!level.IsKeyboardFocusWithin)RememberFilter();
        });
        var panel=new StackPanel{Spacing=10};
        var top=new Grid{ColumnDefinitions=new ColumnDefinitions("*,Auto")};
        // The level selector stays in the same filter group in normal and fullscreen layouts.
        var levels=Horizontal();
        foreach(var title in new[]{"全部","Debug+","Info+","Warn+","Error+","Fatal+"}){int index=levelButtons.Count;var button=Button(title,()=>level.SelectedIndex=index);button.Padding=new Thickness(9,5);levelButtons.Add(button);levels.Children.Add(button);}At(top,levels,0);
        At(top,Horizontal(IconButton("search","查找",()=>ToggleFind(false),"Ctrl+F",shortcut:"Ctrl+F"),followButton),0,1);
        panel.Children.Add(top);panel.Children.Add(filters);return panel;
    }
    void OpenFilterHistory()
    {
        RememberFilter();var window=Auxiliary("过滤历史与收藏",650,520);
        var panel=new Grid{RowDefinitions=new RowDefinitions("Auto,*,Auto"),Margin=new Thickness(18)};var query=Input("搜索关键词、Tag 或等级");var list=new ListBox{Margin=new Thickness(0,12)};
        void Reload(){var q=query.Text??"";list.ItemsSource=prefs.FilterHistory.Ordered.Where(e=>e.Filter.Title.Contains(q,StringComparison.OrdinalIgnoreCase)).Select(e=>new ComboBoxItem{Content=(e.Favorite?"★  ":"")+e.Filter.Title,Tag=e.Filter}).ToArray();}
        void Apply(){if(list.SelectedItem is ComboBoxItem{Tag:SavedLogFilter saved}){RestoreFilter(saved);window.Close();}}
        query.TextChanged+=(_,_)=>Reload();list.DoubleTapped+=(_,_)=>Apply();list.KeyDown+=(_,e)=>{if(e.Key==Key.Enter)Apply();};
        At(panel,query,0);At(panel,list,1);At(panel,Horizontal(Button("应用",Apply),IconButton("star","收藏 / 取消收藏",()=>{if(list.SelectedItem is ComboBoxItem{Tag:SavedLogFilter saved}){prefs.FilterHistory.ToggleFavorite(saved);Save();RefreshFilterHistory();Reload();}})),2);
        Reload();window.Content=panel;window.Show(this);query.Focus();
    }
    void UpdateLevelButtons(){for(int i=0;i<levelButtons.Count;i++){levelButtons[i].Background=i==level.SelectedIndex?colors.Selection:colors.Chip;levelButtons[i].Foreground=i==level.SelectedIndex?colors.Accent:colors.Muted;}}
    void RememberFilter(){var current=CurrentFilter;if(initializing||!current.CanSave||current==lastRememberedFilter)return;lastRememberedFilter=current;if(prefs.FilterHistory.Remember(current)){Save();RefreshFilterHistory();}}
    void ToggleFilterFavorite(){prefs.FilterHistory.ToggleFavorite(CurrentFilter);Save();RefreshFilterHistory();}
    void RestoreFilter(SavedLogFilter filter)
    {
        RememberFilter();
        restoringFilter=true;
        try{filterQuery.Text=filter.Query;tagQuery.Text=filter.Tag;regex.IsChecked=filter.Regex;level.SelectedIndex=(int)filter.Minimum;}
        finally{restoringFilter=false;}
        RememberFilter();RefreshFilterHistory();Refilter();
    }
    void RefreshFilterHistory()
    {
        updatingHistory=true;
        try {
            var items=new List<ComboBoxItem>();
            foreach(var entry in prefs.FilterHistory.Ordered)items.Add(new ComboBoxItem{Content=(entry.Favorite?"★  ":"↶  ")+entry.Filter.Title,Tag=entry.Filter,MaxWidth=760});
            if(items.Count==0)items.Add(new ComboBoxItem{Content="暂无历史，输入后按回车保存",IsEnabled=false});
            if(prefs.FilterHistory.Entries.Any(e=>!e.Favorite))items.Add(new ComboBoxItem{Content="清空历史（保留收藏）",Tag="clear"});
            filterHistory.ItemsSource=items;filterHistory.SelectedIndex=-1;UpdateFilterFavorite();
        } finally {updatingHistory=false;}
    }
    void UpdateFilterFavorite()
    {
        Symbol.Set(filterFavorite,"star","",prefs.FilterHistory.IsFavorite(CurrentFilter));
        filterFavorite.Foreground=prefs.FilterHistory.IsFavorite(CurrentFilter)?colors.Accent:colors.Muted;
        filterFavorite.IsEnabled=CurrentFilter.CanSave;
    }
}
