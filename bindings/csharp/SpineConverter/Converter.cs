using System;
using System.Collections.Generic;
using System.Text;

namespace SpineConverter
{
    /// <summary>Values mirror spc_status</summary>
    public enum Status
    {
        Ok,
        InvalidArgument,
        UnknownFormat,
        UnsupportedVersion,
        Malformed,
        OutOfMemory,
        LossyRejected,
    }

    /// <summary>Values mirror spc_format</summary>
    public enum Format
    {
        Unknown,
        Json,
        Binary,
        Atlas,
    }

    /// <summary>Values mirror spc_impact, ordered by severity</summary>
    public enum Impact
    {
        None,
        Editor,
        Control,
        Pose,
        Render,
    }

    /// <summary>Values mirror the SPC_FLAG_ bits</summary>
    [Flags]
    public enum ConvertFlags : uint
    {
        None = 0,
        FailOnLoss = 1u << 0,
        PrettyJson = 1u << 1,
        NoRewrite = 1u << 2,
    }

    /// <summary>Values mirror spc_remedy</summary>
    public enum Remedy
    {
        None,
        Rewrite,
        Runtime,
    }

    public sealed record Detection(Format Format, string Version, int Major, int Minor, int Patch);

    /// <summary>Fields of one docs/report.md entry</summary>
    public sealed record ReportEntry(string Code, string Severity, Impact Impact, string Step, string Path, string Message, Remedy Remedy);

    public sealed record Conversion(byte[] Data, string ReportJson, IReadOnlyList<ReportEntry> Report, int LossCount, Impact MaxImpact);

    public sealed class ConverterException : Exception
    {
        public ConverterException(Status status, string message) : base(message)
        {
            Status = status;
        }

        public Status Status { get; }
    }

    public static unsafe class Converter
    {
        private static readonly Lazy<uint> Abi = new Lazy<uint>(() =>
        {
            uint version = Native.AbiVersionOf();
            if (version != Native.AbiVersion)
            {
                throw new ConverterException(Status.InvalidArgument, $"{Native.Library} ABI {version}, binding expects {Native.AbiVersion}");
            }
            return version;
        });

        public static uint AbiVersion => Abi.Value;

        public static string LibraryVersion
        {
            get
            {
                _ = Abi.Value;
                return Utf8(Native.LibraryVersion());
            }
        }

        public static string Describe(Status status)
        {
            _ = Abi.Value;
            return Utf8(Native.StatusString(status));
        }

        /// <summary>Format Unknown when the data is not Spine data</summary>
        public static Detection Detect(ReadOnlySpan<byte> data)
        {
            _ = Abi.Value;
            Native.DetectResult result;
            Status status;
            fixed (byte* bytes = data)
            {
                status = Native.Detect(bytes, (nuint)data.Length, &result);
            }
            if (status == Status.UnknownFormat) return new Detection(Format.Unknown, "", 0, 0, 0);
            if (status != Status.Ok) throw new ConverterException(status, Describe(status));
            return new Detection(result.Format, Utf8(result.Version), result.Major, result.Minor, result.Patch);
        }

        /// <summary>
        /// Null target version and Unknown target format keep the source version and format.
        /// The atlas of a 3.5 or 3.6 skeleton keeps mesh UVs of stripped regions.
        /// </summary>
        public static Conversion Convert(ReadOnlySpan<byte> data, string? targetVersion = null,
            Format targetFormat = Format.Unknown, ConvertFlags flags = ConvertFlags.None,
            ReadOnlySpan<byte> atlas = default)
        {
            _ = Abi.Value;
            byte[]? version = targetVersion == null ? null : Encoding.UTF8.GetBytes(targetVersion + "\0");
            nint result = 0;
            try
            {
                Status status;
                fixed (byte* bytes = data)
                fixed (byte* text = version)
                fixed (byte* atlasBytes = atlas)
                {
                    var options = new Native.Options
                    {
                        StructSize = (uint)sizeof(Native.Options),
                        TargetVersion = text,
                        TargetFormat = targetFormat,
                        Flags = (uint)flags,
                        Atlas = atlas.IsEmpty ? null : atlasBytes,
                        AtlasLength = (nuint)atlas.Length,
                    };
                    status = Native.Convert(bytes, (nuint)data.Length, &options, null, &result);
                }
                if (status != Status.Ok)
                {
                    string message = result == 0 ? Describe(status) : Utf8(Native.ResultError(result));
                    throw new ConverterException(status, message);
                }

                nuint length, reportLength;
                byte* output = Native.ResultData(result, &length);
                byte* report = Native.ResultReport(result, &reportLength);
                string reportJson = Encoding.UTF8.GetString(report, checked((int)reportLength));
                return new Conversion(
                    new ReadOnlySpan<byte>(output, checked((int)length)).ToArray(),
                    reportJson,
                    ReportReader.Parse(reportJson),
                    checked((int)Native.ResultLossCount(result)),
                    Native.ResultMaxImpact(result));
            }
            finally
            {
                Native.ResultFree(result);
            }
        }

        private static string Utf8(byte* text)
        {
            int length = 0;
            while (text[length] != 0) length++;
            return Encoding.UTF8.GetString(text, length);
        }
    }

    /// <summary>Reads the flat report array without a JSON dependency</summary>
    internal static class ReportReader
    {
        public static ReportEntry[] Parse(string json)
        {
            var entries = new List<ReportEntry>();
            int i = 0;
            Expect(json, ref i, '[');
            if (TryTake(json, ref i, ']')) return entries.ToArray();
            do
            {
                var fields = new Dictionary<string, string>();
                Expect(json, ref i, '{');
                if (!TryTake(json, ref i, '}'))
                {
                    do
                    {
                        string key = ReadString(json, ref i);
                        Expect(json, ref i, ':');
                        fields[key] = ReadString(json, ref i);
                    } while (TryTake(json, ref i, ','));
                    Expect(json, ref i, '}');
                }
                entries.Add(new ReportEntry(
                    fields["code"],
                    fields["severity"],
                    ParseImpact(fields["impact"]),
                    fields["step"],
                    fields["path"],
                    fields["message"],
                    ParseRemedy(fields["remedy"])));
            } while (TryTake(json, ref i, ','));
            Expect(json, ref i, ']');
            return entries.ToArray();
        }

        private static Impact ParseImpact(string text)
        {
            switch (text)
            {
                case "none": return Impact.None;
                case "editor": return Impact.Editor;
                case "control": return Impact.Control;
                case "pose": return Impact.Pose;
                case "render": return Impact.Render;
                default: throw new FormatException($"unknown impact {text}");
            }
        }

        private static Remedy ParseRemedy(string text)
        {
            switch (text)
            {
                case "none": return Remedy.None;
                case "rewrite": return Remedy.Rewrite;
                case "runtime": return Remedy.Runtime;
                default: throw new FormatException($"unknown remedy {text}");
            }
        }

        private static bool TryTake(string json, ref int i, char c)
        {
            if (i >= json.Length || json[i] != c) return false;
            i++;
            return true;
        }

        private static void Expect(string json, ref int i, char c)
        {
            if (!TryTake(json, ref i, c)) throw new FormatException($"report expects '{c}' at {i}");
        }

        private static string ReadString(string json, ref int i)
        {
            Expect(json, ref i, '"');
            var text = new StringBuilder();
            while (true)
            {
                if (i >= json.Length) throw new FormatException("unterminated report string");
                char c = json[i++];
                if (c == '"') return text.ToString();
                if (c != '\\')
                {
                    text.Append(c);
                    continue;
                }
                char escaped = json[i++];
                switch (escaped)
                {
                    case 'b': text.Append('\b'); break;
                    case 'f': text.Append('\f'); break;
                    case 'n': text.Append('\n'); break;
                    case 'r': text.Append('\r'); break;
                    case 't': text.Append('\t'); break;
                    case 'u':
                        text.Append((char)System.Convert.ToUInt16(json.Substring(i, 4), 16));
                        i += 4;
                        break;
                    default: text.Append(escaped); break;
                }
            }
        }
    }
}

#if !NET5_0_OR_GREATER
namespace System.Runtime.CompilerServices
{
    /// <summary>Lets records compile for netstandard2.1 and Unity</summary>
    internal static class IsExternalInit
    {
    }
}
#endif
