using System.Text.Json.Serialization;
namespace LogcatMini.Core;

public sealed record SavedLogFilter(string Query="",string Tag="",bool Regex=false,Level Minimum=Level.Verbose)
{
    public SavedLogFilter Normalized()=>this with{Query=Regex?Query??"":(Query??"").Trim(),Tag=(Tag??"").Trim()};
    [JsonIgnore] public bool CanSave {
        get {
            if(!Enum.IsDefined(Minimum)||(string.IsNullOrEmpty(Query)&&string.IsNullOrEmpty(Tag)&&Minimum==Level.Verbose))return false;
            try{_ = new LogFilter(Minimum,Query??"",Tag??"",Regex);return true;}catch(ArgumentException){return false;}
        }
    }
    [JsonIgnore] public string Title=>(string.IsNullOrEmpty(Query)?"全部消息":Query.Replace('\n',' '))+(string.IsNullOrEmpty(Tag)?"":" · Tag: "+Tag)+(Minimum==Level.Verbose?"":" · "+Minimum+"+")+(Regex?" · 正则":"");
}
public sealed record FilterHistoryEntry(SavedLogFilter Filter,bool Favorite=false);
public sealed class FilterHistory
{
    public List<FilterHistoryEntry> Entries {get;set;}=[];
    [JsonIgnore] public IEnumerable<FilterHistoryEntry> Ordered=>Entries.Where(e=>e.Favorite).Concat(Entries.Where(e=>!e.Favorite));
    public bool IsFavorite(SavedLogFilter filter)=>Entries.Any(e=>e.Filter==filter&&e.Favorite);
    public bool Remember(SavedLogFilter filter)
    {
        filter=filter.Normalized();if(!filter.CanSave)return false;
        var entry=new FilterHistoryEntry(filter,IsFavorite(filter));if(Entries.FirstOrDefault()==entry)return false;
        Entries.RemoveAll(e=>e.Filter==filter);Entries.Insert(0,entry);Normalize();return true;
    }
    public void ToggleFavorite(SavedLogFilter filter)
    {
        filter=filter.Normalized();if(!filter.CanSave)return;
        var entry=new FilterHistoryEntry(filter,!IsFavorite(filter));Entries.RemoveAll(e=>e.Filter==filter);Entries.Insert(0,entry);Normalize();
    }
    public void ClearRecent()=>Entries.RemoveAll(e=>!e.Favorite);
    public void Normalize()
    {
        var seen=new HashSet<SavedLogFilter>();int recent=0;
        Entries=(Entries??[]).Where(e=>e?.Filter is not null).Select(e=>e with{Filter=e.Filter.Normalized()})
            .Where(e=>e.Filter.CanSave&&seen.Add(e.Filter)&&(e.Favorite||++recent<=30)).ToList();
    }
}
