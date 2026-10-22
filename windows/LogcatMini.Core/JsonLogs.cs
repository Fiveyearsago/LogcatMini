using System.Text.Json;
namespace LogcatMini.Core;

public sealed record JsonNode(int Id, string? Key, string Value, char Container, List<JsonNode> Children)
{
    public bool IsContainer => Container is '{' or '[';
    public char Closing => Container=='{'?'}':']';
    public string SearchText => (Key is null?"":Key+": ")+Value;
}
public sealed record JsonFragment(string Prefix, JsonNode Root);
public sealed record JsonLog(List<JsonFragment> Fragments,string Suffix)
{
    public string FormattedText => string.Join('\n', JsonRows.Visible(this, AllNodes().Where(n=>n.IsContainer).Select(n=>n.Id).ToHashSet()).Select(r=>new string(' ',r.Depth*2)+r.Text));
    public IEnumerable<JsonNode> AllNodes() { foreach(var f in Fragments) foreach(var n in Walk(f.Root))yield return n; }
    static IEnumerable<JsonNode> Walk(JsonNode root) { yield return root;foreach(var child in root.Children)foreach(var n in Walk(child))yield return n; }
    public static JsonLog? Parse(string text)
    {
        if(System.Text.Encoding.UTF8.GetByteCount(text)>2*1024*1024)return null;
        var fragments=new List<JsonFragment>(); int previous=0,nextId=0;
        for(int i=0;i<text.Length;i++)
        {
            if(text[i] is not ('{' or '['))continue;
            int end=End(text,i);if(end<0)break;
            try
            {
                var bytes=System.Text.Encoding.UTF8.GetBytes(text[i..end]);
                var reader=new Utf8JsonReader(bytes,new JsonReaderOptions{MaxDepth=128});reader.Read();
                var root=Build(ref reader,bytes,ref nextId);
                fragments.Add(new(text[previous..i],root));previous=end;
            }
            catch(JsonException) { if(nextId>=20000)return null; }
            i=end-1;
        }
        return fragments.Count==0?null:new(fragments,text[previous..]);
    }
    static JsonNode Build(ref Utf8JsonReader reader,byte[] bytes,ref int nextId,string? key=null)
    {
        if(nextId>=20000)throw new JsonException("节点过多");int id=nextId++;
        var children=new List<JsonNode>();char container=reader.TokenType==JsonTokenType.StartObject?'{':reader.TokenType==JsonTokenType.StartArray?'[':'\0';
        if(container=='\0')return new(id,key,System.Text.Encoding.UTF8.GetString(bytes.AsSpan((int)reader.TokenStartIndex,(int)(reader.BytesConsumed-reader.TokenStartIndex))),container,children);
        while(reader.Read()&&reader.TokenType is not (JsonTokenType.EndObject or JsonTokenType.EndArray))
        {
            string? childKey=null;
            if(container=='{'){if(reader.TokenType!=JsonTokenType.PropertyName)throw new JsonException();childKey=System.Text.Encoding.UTF8.GetString(bytes.AsSpan((int)reader.TokenStartIndex,reader.ValueSpan.Length+2));if(!reader.Read())throw new JsonException();}
            children.Add(Build(ref reader,bytes,ref nextId,childKey));
        }
        return new(id,key,container.ToString(),container,children);
    }
    static int End(string text,int start)
    {
        var stack=new Stack<char>();bool quoted=false,escaped=false;
        for(int i=start;i<text.Length;i++)
        {
            char c=text[i];if(quoted){if(escaped)escaped=false;else if(c=='\\')escaped=true;else if(c=='"')quoted=false;continue;}
            if(c=='"')quoted=true;else if(c is '{' or '[')stack.Push(c);
            else if(c is '}' or ']'){if(stack.Count==0 || (stack.Pop()=='{'?c!='}':c!=']'))return i+1;if(stack.Count==0)return i+1;}
        }
        return -1;
    }
}
public sealed record JsonRow(string Id,string Text,int Depth,JsonNode? Node,bool Closing=false);
public static class JsonRows
{
    public static List<JsonRow> Visible(JsonLog doc,HashSet<int> expanded)
    {
        List<JsonRow> rows=[];
        void Add(JsonNode n,int depth,bool member=false,bool comma=false)
        {
            bool open=n.Children.Count>0&&expanded.Contains(n.Id);
            var value=n.IsContainer?(n.Children.Count==0?$"{n.Container}{n.Closing}":open?n.Container.ToString():$"{n.Container} … {n.Closing}"):n.Value;
            rows.Add(new($"n{n.Id}",(member&&n.Key is not null?n.Key+": ":"")+value+(!open&&comma?",":""),depth,n));
            if(open){for(int i=0;i<n.Children.Count;i++)Add(n.Children[i],depth+1,n.Container=='{',i<n.Children.Count-1);rows.Add(new($"c{n.Id}",n.Closing+(comma?",":""),depth,n,true));}
        }
        foreach(var f in doc.Fragments){if(!string.IsNullOrWhiteSpace(f.Prefix))rows.Add(new($"p{f.Root.Id}",f.Prefix.Trim(),0,null));Add(f.Root,0);}
        if(!string.IsNullOrWhiteSpace(doc.Suffix))rows.Add(new("suffix",doc.Suffix.Trim(),0,null));return rows;
    }
    public static List<(int Node,HashSet<int> Ancestors)> Find(JsonLog doc,string query)
    {
        List<(int,HashSet<int>)> hits=[];if(query.Length==0)return hits;
        void Visit(JsonNode n,HashSet<int> path){if(n.SearchText.Contains(query,StringComparison.OrdinalIgnoreCase))hits.Add((n.Id,new(path)));var p=new HashSet<int>(path){n.Id};foreach(var c in n.Children)Visit(c,p);}
        foreach(var f in doc.Fragments)Visit(f.Root,[]);return hits;
    }
}
