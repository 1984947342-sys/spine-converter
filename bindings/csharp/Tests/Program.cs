using System.Text;
using SpineConverter;

int failed = 0;

void Check(bool condition, string name)
{
    if (condition) return;
    Console.WriteLine($"FAIL {name}");
    failed++;
}

Status Throws(Action action)
{
    try
    {
        action();
    }
    catch (ConverterException e)
    {
        return e.Status;
    }
    return Status.Ok;
}

byte[] skeleton = Encoding.UTF8.GetBytes(
    "{\"skeleton\":{\"spine\":\"4.2.43\"},\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\"}],\"physics\":[{\"name\":\"p\",\"bone\":\"b\"}]}");
byte[] atlas = Encoding.UTF8.GetBytes("page.png\nsize: 64, 64\nfilter: Linear, Linear\npma: true\nr\nbounds: 0, 0, 8, 8\n");

Check(Converter.AbiVersion == 1, "abi version");
Check(Converter.LibraryVersion.Length > 0, "library version");
Check(Converter.Describe(Status.Malformed).Length > 0, "status string");

var json = Converter.Detect(skeleton);
Check(json == new Detection(Format.Json, "4.2.43", 4, 2, 43), $"detect json {json}");
Check(Converter.Detect(atlas).Format == Format.Atlas, "detect atlas");
Check(Converter.Detect("not spine"u8).Format == Format.Unknown, "detect unknown");

var binary = Converter.Convert(skeleton, null, Format.Binary);
Check(Converter.Detect(binary.Data) == new Detection(Format.Binary, "4.2.43", 4, 2, 43), "detect binary");
Check(binary.LossCount == 0 && binary.MaxImpact == Impact.None && binary.Report.Count == 0, "exact conversion");
var back = Converter.Convert(binary.Data, "4.3", Format.Json, ConvertFlags.PrettyJson);
Check(Converter.Detect(back.Data).Minor == 3 && back.Data.Contains((byte)'\n'), "binary to pretty 4.3 json");

var lossy = Converter.Convert(skeleton, "4.1");
Check(lossy.LossCount == 1 && lossy.MaxImpact == Impact.Pose, $"lossy {lossy.ReportJson}");
Check(lossy.Report.Count == 1 && lossy.Report[0] is { Code: "physics.dropped", Severity: "dropped", Impact: Impact.Pose, Step: "4.2-4.1" }, "report entry");
Check(Throws(() => Converter.Convert(skeleton, "4.1", Format.Unknown, ConvertFlags.FailOnLoss)) == Status.LossyRejected, "fail on loss");

var legacy = Converter.Convert(atlas, "3.8");
Check(Encoding.UTF8.GetString(legacy.Data).Contains("format: RGBA8888"), "atlas to 3.8");
Check(legacy.MaxImpact == Impact.Render && legacy.Report.Any(e => e.Code == "atlas.pma.dropped"), "atlas pma loss");

Check(Throws(() => Converter.Convert("not spine"u8, "4.3")) == Status.UnknownFormat, "unknown format");
Check(Throws(() => Converter.Convert(binary.Data.AsSpan(0, binary.Data.Length / 2), "4.3")) == Status.Malformed, "truncated");
Check(Throws(() => Converter.Convert(skeleton, "9.9")) == Status.UnsupportedVersion, "unsupported version");
Check(Throws(() => Converter.Convert(atlas, "4.3", Format.Json)) == Status.InvalidArgument, "atlas to json");

byte[] old = Encoding.UTF8.GetBytes(
    "{\"skeleton\":{\"spine\":\"3.8.99\"},\"bones\":[{\"name\":\"root\"},{\"name\":\"b\",\"parent\":\"root\"}],\"transform\":[{\"name\":\"t\",\"bones\":[\"b\"],\"target\":\"root\",\"scaleMix\":-1}]}");
var rewritten = Converter.Convert(old, "4.3");
Check(rewritten.LossCount == 0 && rewritten.Report.Count == 1 && rewritten.Report[0] is { Code: "transform.scaleMix.rewritten" }, $"rewrite by default {rewritten.ReportJson}");
var plain = Converter.Convert(old, "4.3", Format.Unknown, ConvertFlags.NoRewrite);
Check(plain.Report.Count == 1 && plain.Report[0] is { Code: "transform.scaleMix.approximated", Remedy: Remedy.Rewrite }, $"rewritable {plain.ReportJson}");
Check(Throws(() => Converter.Convert(old, "4.3", Format.Unknown, (ConvertFlags)(1u << 3))) == Status.InvalidArgument, "unknown flag");

byte[] page = Encoding.UTF8.GetBytes(
    "\na.png\nsize: 64,64\nformat: RGBA8888\nfilter: Linear,Linear\nrepeat: none\n" +
    "r\n  rotate: false\n  xy: 2, 2\n  size: 20, 30\n  orig: 32, 40\n  offset: 5, 3\n  index: -1\n");
byte[] stripped = Encoding.UTF8.GetBytes(
    "{\"skeleton\":{\"spine\":\"3.6.53\"},\"bones\":[{\"name\":\"root\"}],\"slots\":[{\"name\":\"s\",\"bone\":\"root\"}]," +
    "\"skins\":{\"default\":{\"s\":{\"r\":{\"type\":\"mesh\",\"uvs\":[0,0,1,0,1,1,0.25,0.7],\"triangles\":[0,1,2,0,2,3]," +
    "\"vertices\":[0,0,10,0,10,10,0,10],\"hull\":4}}}}}");
Check(Converter.Convert(stripped, "3.7").LossCount == 1, "stripped region without atlas");
var uvs = Converter.Convert(stripped, "3.7", Format.Unknown, ConvertFlags.None, page);
Check(uvs.LossCount == 0 && Encoding.UTF8.GetString(uvs.Data).Contains("0.15625,0.175"), $"stripped region with atlas {uvs.ReportJson}");

byte[] named = Encoding.UTF8.GetBytes(
    "{\"skeleton\":{\"spine\":\"4.2.43\"},\"bones\":[{\"name\":\"root\"}],\"physics\":[{\"name\":\"p\\\"é\\t\\u0001\",\"bone\":\"root\"}]}");
var escaped = Converter.Convert(named, "4.1");
Check(escaped.Report.Any(e => e.Path.EndsWith("p\"é\t\u0001")), $"report escapes {escaped.ReportJson}");

Console.WriteLine(failed == 0 ? "csharp binding: all passed" : $"csharp binding: {failed} failed");
return failed == 0 ? 0 : 1;
