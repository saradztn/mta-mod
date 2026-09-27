using System.Text;
using System.Text.RegularExpressions;

namespace DefensiveSourceScan;

internal sealed class SourceScanner
{
    private const int RegexTimeoutMilliseconds = 250;
    private const int MaximumSnippetLength = 240;

    private static readonly HashSet<string> SourceExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".cs", ".csx", ".vb", ".fs", ".fsx", ".c", ".h", ".cc", ".cpp", ".cxx",
        ".hpp", ".hh", ".java", ".js", ".jsx", ".ts", ".tsx", ".go", ".rs", ".py",
        ".ps1", ".psm1", ".bat", ".cmd", ".lua", ".php", ".rb", ".swift", ".kt"
    };

    private static readonly IndicatorRule[] Rules =
    {
        new("Input capture", "Keyboard hook or raw-input API",
            @"\b(?:SetWindowsHookEx(?:A|W)?|GetAsyncKeyState|GetKeyState|RegisterRawInputDevices)\b"),
        new("Screen capture", "Desktop or window capture API",
            @"\b(?:CopyFromScreen|BitBlt|PrintWindow|GetDesktopWindow|CreateCompatibleBitmap)\b"),
        new("Network communication", "Socket or network stream API",
            @"\b(?:TcpClient|TcpListener|UdpClient|Socket|NetworkStream|WebSocket)\b"),
        new("File access", "File-reading, copying, or enumeration API",
            @"\b(?:File\.(?:ReadAllBytes|ReadAllText|OpenRead|Copy|Move)|Directory\.GetFiles|FileStream)\b"),
        new("Process execution", "Process or shell launch API",
            @"\b(?:Process\.Start|CreateProcess(?:A|W)?|ShellExecute(?:Ex)?(?:A|W)?)\b"),
        new("Persistence", "Registry or scheduled-task indicator",
            @"\b(?:Microsoft\.Win32\.Registry|RegistryKey|schtasks(?:\.exe)?)\b|CurrentVersion\\Run")
    };

    private readonly ScanOptions _options;

    public SourceScanner(ScanOptions options)
    {
        _options = options;
    }

    public ScanReport Run()
    {
        var report = new ScanReport();
        var files = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (string inputPath in _options.Paths)
        {
            string fullPath;
            try
            {
                fullPath = Path.GetFullPath(inputPath);
            }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
            {
                report.Errors.Add($"Invalid path '{inputPath}': {ex.Message}");
                continue;
            }

            if (File.Exists(fullPath))
            {
                AddFile(fullPath, files, report);
            }
            else if (Directory.Exists(fullPath))
            {
                CollectDirectory(fullPath, files, report);
            }
            else
            {
                report.Errors.Add($"Path does not exist: {inputPath}");
            }
        }

        foreach (string file in files)
        {
            ScanFile(file, report);
        }

        return report;
    }

    private void CollectDirectory(string root, SortedSet<string> files, ScanReport report)
    {
        var pending = new Stack<string>();
        pending.Push(root);

        while (pending.Count > 0)
        {
            string directory = pending.Pop();
            IEnumerable<string> entries;
            try
            {
                entries = Directory.EnumerateFileSystemEntries(directory).ToArray();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                report.Errors.Add($"Could not enumerate '{directory}': {ex.Message}");
                continue;
            }

            foreach (string entry in entries)
            {
                FileAttributes attributes;
                try
                {
                    attributes = File.GetAttributes(entry);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    report.Errors.Add($"Could not inspect '{entry}': {ex.Message}");
                    continue;
                }

                if ((attributes & FileAttributes.Directory) != 0)
                {
                    string name = Path.GetFileName(entry) ?? string.Empty;
                    if (!_options.ExcludedDirectoryNames.Contains(name) &&
                        _options.Recursive &&
                        (attributes & FileAttributes.ReparsePoint) == 0)
                    {
                        pending.Push(entry);
                    }
                }
                else
                {
                    AddFile(entry, files, report);
                }
            }
        }
    }

    private static void AddFile(string path, SortedSet<string> files, ScanReport report)
    {
        if (!SourceExtensions.Contains(Path.GetExtension(path)))
        {
            return;
        }

        try
        {
            files.Add(Path.GetFullPath(path));
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            report.Errors.Add($"Invalid file path '{path}': {ex.Message}");
        }
    }

    private static void ScanFile(string path, ScanReport report)
    {
        try
        {
            using var reader = new StreamReader(path);
            int lineNumber = 0;
            while (reader.ReadLine() is { } line)
            {
                lineNumber++;
                foreach (IndicatorRule rule in Rules)
                {
                    try
                    {
                        Match match = rule.Pattern.Match(line);
                        if (match.Success)
                        {
                            report.Findings.Add(new Finding
                            {
                                Path = path,
                                Line = lineNumber,
                                Category = rule.Category,
                                Description = rule.Description,
                                Indicator = match.Value,
                                Snippet = Truncate(line.Trim())
                            });
                        }
                    }
                    catch (RegexMatchTimeoutException)
                    {
                        report.Errors.Add($"Pattern matching timed out at {path}:{lineNumber}.");
                    }
                }
            }

            report.FilesScanned++;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DecoderFallbackException)
        {
            report.Errors.Add($"Could not read '{path}': {ex.Message}");
        }
    }

    private static string Truncate(string text)
    {
        if (text.Length <= MaximumSnippetLength)
        {
            return text;
        }

        return text[..MaximumSnippetLength] + "…";
    }

    private sealed class IndicatorRule
    {
        public string Category { get; }
        public string Description { get; }
        public Regex Pattern { get; }

        public IndicatorRule(string category, string description, string expression)
        {
            Category = category;
            Description = description;
            Pattern = new Regex(expression,
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
                TimeSpan.FromMilliseconds(RegexTimeoutMilliseconds));
        }
    }
}
