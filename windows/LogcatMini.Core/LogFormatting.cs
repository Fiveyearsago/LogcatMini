using System.Text;
namespace LogcatMini.Core;

/// Same whitespace-only formatter as the Mac client. Source records are never rewritten.
public sealed record FormattedLog(string Text, JsonLog? Json)
{
    public static FormattedLog? Parse(string message)
    {
        if (Encoding.UTF8.GetByteCount(message) > 2 * 1024 * 1024) return null;
        if (JsonLog.Parse(message) is {} json)
        {
            json = new(json.Fragments.Select(f => new JsonFragment(KeyValueFormatter.Format(f.Prefix) ?? f.Prefix, f.Root)).ToList(), KeyValueFormatter.Format(json.Suffix) ?? json.Suffix);
            return new(json.FormattedText, json);
        }
        return new(KeyValueFormatter.Format(message) ?? message, null);
    }
}
public static class KeyValueFormatter
{
    public static string? Format(string text) => Encoding.UTF8.GetByteCount(text) > 2 * 1024 * 1024 ? null : new Scanner(text).Format();
    sealed class Scanner(string text)
    {
        sealed record Group(char Opening, int[] Ancestors) { public int? Close; }
        readonly List<Group> groups = [];
        readonly List<int> stack = [];
        readonly List<(int Start, int[] Ancestors)> fields = [];
        static bool Space(char c) => c is ' ' or '\t' or '\r' or '\n';
        bool Boundary(int i) => i == 0 || Space(text[i-1]) || ",;#{[(".Contains(text[i-1]);
        static bool KeyStart(char c) => c == '_' || char.IsAsciiLetter(c) || c >= 128;
        static bool KeyBody(char c) => KeyStart(c) || char.IsAsciiDigit(c) || c is '.' or '-';
        int QuoteEnd(int start)
        {
            for (int i=start+1;i<text.Length;i++) { if(text[i]=='\\'){i++;continue;} if(text[i]==text[start])return i+1; }
            return -1;
        }
        int FieldEnd(int start)
        {
            int i=start;
            if(text[i] is '\"' or '\''){i=QuoteEnd(i);if(i<start+3)return -1;}
            else {if(!KeyStart(text[i]))return -1;while(i<text.Length&&KeyBody(text[i]))i++;}
            while(i<text.Length&&Space(text[i]))i++;
            if(i>=text.Length||text[i] is not ('=' or ':'))return -1;
            if(i+1<text.Length)
            {
                if(text[i]==':'&&char.IsAsciiDigit(text[i+1])&&new[]{".kt",".java",".swift",".m",".mm",".c",".cpp",".h",".cs",".py",".js",".ts"}.Any(s=>text[start..i].EndsWith(s,StringComparison.Ordinal)))return -1;
                if(text[i+1]=='='||text[i]==':'&&(text[i+1] is ':' or '/'||i==start+1&&text[i+1]=='\\'))return -1;
            }
            return i+1;
        }
        int UrlEnd(int start)
        {
            if(!KeyStart(text[start])||start>0&&KeyBody(text[start-1]))return -1;
            int i=start;while(i<text.Length&&(KeyBody(text[i])||text[i]=='+'))i++;
            if(i+2>=text.Length||text[i..(i+3)]!="://")return -1;
            i+=3;var nested=new Stack<char>();
            while(i<text.Length&&!Space(text[i])&&text[i] is not ('\"' or '\''))
            {
                char c=text[i];if("{[(".Contains(c))nested.Push(c);
                if("}])".Contains(c)){if(nested.Count==0||!Matches(nested.Peek(),c))break;nested.Pop();}i++;
            }
            return i;
        }
        static bool Matches(char a,char b) => (a,b) is ('{','}') or ('[',']') or ('(',')');
        public string? Format()
        {
            int i=0;
            while(i<text.Length)
            {
                int end=UrlEnd(i);if(end>=0){i=end;continue;}
                if(Boundary(i)&&(end=FieldEnd(i))>=0){if(fields.Count>=20000)return null;fields.Add((i,stack.ToArray()));i=end;continue;}
                char c=text[i];
                if(c is '\"' or '\''&&(Boundary(i)||i>0&&text[i-1] is '=' or ':')){end=QuoteEnd(i);if(end<0)return null;i=end;continue;}
                if("{[(".Contains(c)){if(stack.Count>=128||groups.Count>=20000)return null;groups.Add(new(c,stack.ToArray()));stack.Add(groups.Count-1);}
                else if("}])".Contains(c)&&stack.Count>0){var group=groups[stack[^1]];if(!Matches(group.Opening,c))return null;group.Close=i;stack.RemoveAt(stack.Count-1);}
                i++;
            }
            if(stack.Count>0||fields.Count==0)return null;
            var active=fields.SelectMany(f=>f.Ancestors).ToHashSet();
            var breaks=fields.Select(f=>(Index:f.Start,Depth:f.Ancestors.Length)).ToList();
            foreach(int id in active)if(groups[id].Close is {} close)breaks.Add((close,groups[id].Ancestors.Length));
            var result=new StringBuilder();int previous=0;
            foreach(var point in breaks.OrderBy(p=>p.Index)){result.Append(text[previous..point.Index].Trim());if(result.Length>0)result.Append('\n');result.Append(' ',point.Depth*2);previous=point.Index;}
            result.Append(text[previous..].Trim());return result.ToString();
        }
    }
}
