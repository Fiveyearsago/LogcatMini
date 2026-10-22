using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace LogcatMini.Core;

public enum Level { Verbose, Debug, Info, Warn, Error, Fatal }
public sealed record LogRecord(long Id, string Date, string Time, string Pid, string Tid, Level Level, string Tag, string Message, string Raw, long[]? SourceIds = null)
{
    public int Parts => SourceIds?.Length ?? 1;
    public string Letter => "VDIWEF"[(int)Level].ToString();
    public string DisplayMessage => LogParser.Clean(Message);
    public string FullText => Parts == 1 ? Raw : $"{Date} {Time} {Pid} {Tid} {Letter} {Tag}: {Message}";
}
public static class LogParser
{
    static readonly Regex Pattern = new(@"^(\d{4}-\d{2}-\d{2}|\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFA])\s+(.+?)\s*:\s?(.*)$", RegexOptions.Singleline, TimeSpan.FromMilliseconds(100));
    static readonly Regex DuplicateTime = new(@"^[\t ]*(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d\.\d{3,6}\[\d+\][\t ]+(?=\S)", RegexOptions.None, TimeSpan.FromMilliseconds(100));
    public static string Clean(string message) => DuplicateTime.Replace(message, "", 1);
    public static LogRecord? Parse(string line, long id)
    {
        var m = Pattern.Match(line); if (!m.Success) return null;
        var n = "VDIWEFA".IndexOf(m.Groups[5].Value, StringComparison.Ordinal);
        return new(id, m.Groups[1].Value, m.Groups[2].Value, m.Groups[3].Value, m.Groups[4].Value,
            (Level)Math.Min(n, 5), m.Groups[6].Value.Trim(), m.Groups[7].Value, line);
    }
}
/// Session-only storage. No fixed count eviction and no history is loaded from disk.
public sealed class LogBuffer
{
    public List<LogRecord> Entries { get; } = [];
    static readonly Regex Chunk = new(@"^(.*?)\b([A-Za-z][A-Za-z0-9_]*)_part=(\d+)/(\d+)\s+\2=(.*)$", RegexOptions.Singleline, TimeSpan.FromMilliseconds(100));
    public void Clear() => Entries.Clear();
    public int Append(IEnumerable<LogRecord> batch)
    {
        int firstChange = Entries.Count;
        foreach (var entry in batch) { Entries.Add(entry); firstChange = Math.Min(firstChange, MergeTail()); }
        return firstChange;
    }
    int MergeTail()
    {
        var last = Entries[^1]; int unchanged = Entries.Count - 1;
        if (last.Parts > 1 || !last.Message.Contains("_part=")) return unchanged;
        var end = Chunk.Match(last.DisplayMessage);
        if (!end.Success || !int.TryParse(end.Groups[3].Value, out var index) || !int.TryParse(end.Groups[4].Value, out var total)
            || index != total || total < 2 || total > 256 || Entries.Count < total) return unchanged;
        int start = Entries.Count - total; var first = Entries[start];
        if (!TimeSpan.TryParse(first.Time, CultureInfo.InvariantCulture, out var startTime) || !TimeSpan.TryParse(last.Time, CultureInfo.InvariantCulture, out var endTime)
            || endTime < startTime || (endTime-startTime).TotalSeconds > 2) return unchanged;
        var payload = new StringBuilder(); var raw = new List<string>(); long bytes = 0; var previous = startTime;
        for (int i=0; i<total; i++)
        {
            var p = Entries[start+i]; var m = Chunk.Match(p.DisplayMessage);
            if (p.Parts != 1 || p.Id != first.Id+i || p.Date != first.Date || p.Pid != first.Pid || p.Tid != first.Tid || p.Tag != first.Tag || p.Level != first.Level
                || !m.Success || m.Groups[3].Value != (i+1).ToString() || m.Groups[4].Value != total.ToString()
                || m.Groups[1].Value != end.Groups[1].Value || m.Groups[2].Value != end.Groups[2].Value
                || !TimeSpan.TryParse(p.Time, CultureInfo.InvariantCulture, out var time) || time < previous) return unchanged;
            previous = time; bytes += Encoding.UTF8.GetByteCount(p.Raw); if (bytes > 2*1024*1024) return unchanged;
            payload.Append(m.Groups[5].Value); raw.Add(p.Raw);
        }
        var merged = first with { Message=end.Groups[1].Value+end.Groups[2].Value+"="+payload, Raw=string.Join('\n',raw), SourceIds=Enumerable.Range(0,total).Select(i=>Entries[start+i].Id).ToArray() };
        Entries.RemoveRange(start,total); Entries.Add(merged); return start;
    }
}
public sealed class LogFilter
{
    readonly Level minimum; readonly string[] words, tags; readonly Regex? expression;
    public LogFilter(Level minimum = Level.Verbose, string query = "", string tag = "", bool regex = false)
    {
        this.minimum = minimum; words = regex ? [] : Segments(query); tags = Segments(tag);
        if (regex && query.Length > 0) expression = new Regex(query,RegexOptions.IgnoreCase,TimeSpan.FromMilliseconds(100));
    }
    static string[] Segments(string value) => value.Split('|',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    public bool Matches(LogRecord e)
    {
        if (e.Level<minimum || (tags.Length>0 && !tags.Any(t=>e.Tag.Contains(t,StringComparison.OrdinalIgnoreCase)))) return false;
        string text=e.Parts>1?e.Raw+"\n"+e.Message:e.Raw;
        return expression?.IsMatch(text) ?? (words.Length==0 || words.Any(w=>text.Contains(w,StringComparison.OrdinalIgnoreCase)));
    }
}
public readonly record struct TextRange(int Start, int Length);
public static class FindText
{
    public static List<TextRange> Ranges(string text,string query)
    {
        List<TextRange> result=[]; if(query.Length==0)return result;
        for(int start=0; start<text.Length;)
        {
            int i=text.IndexOf(query,start,StringComparison.OrdinalIgnoreCase);if(i<0)break;
            result.Add(new(i,query.Length)); start=i+query.Length;
        }
        return result;
    }
}
