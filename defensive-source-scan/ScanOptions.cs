namespace DefensiveSourceScan;

internal sealed class ScanOptions
{
    public const string Usage = """
        DefensiveSourceScan — offline source-code indicator scanner

        Usage:
          dotnet run -- [--json] [--no-recursive] [--exclude DIRNAME] <file-or-directory>...
          dotnet run -- --help

        Options:
          --json           Write a machine-readable JSON report to standard output.
          --no-recursive   Scan only files directly inside each supplied directory.
          --exclude NAME   Skip directories with this name (may be specified more than once).
          --help           Display this help text.

        Returns 0 when no indicators are found, 1 when findings are present,
        and 2 when an input or scan error occurs. Scanning is local and read-only.
        """;

    public bool Json { get; private set; }
    public bool Recursive { get; private set; } = true;
    public bool ShowHelp { get; private set; }
    public List<string> Paths { get; } = new();
    public HashSet<string> ExcludedDirectoryNames { get; } = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", ".vs", "bin", "obj", "node_modules", "packages", "vendor"
    };

    public static ScanOptions Parse(string[] args)
    {
        var options = new ScanOptions();

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            switch (arg)
            {
                case "--help":
                case "-h":
                    options.ShowHelp = true;
                    break;
                case "--json":
                    options.Json = true;
                    break;
                case "--no-recursive":
                    options.Recursive = false;
                    break;
                case "--exclude":
                    if (++i >= args.Length || string.IsNullOrWhiteSpace(args[i]))
                    {
                        throw new ArgumentException("--exclude requires a directory name.");
                    }

                    options.ExcludedDirectoryNames.Add(args[i]);
                    break;
                default:
                    if (arg.StartsWith("-", StringComparison.Ordinal))
                    {
                        throw new ArgumentException($"Unknown option: {arg}");
                    }

                    options.Paths.Add(arg);
                    break;
            }
        }

        return options;
    }
}
