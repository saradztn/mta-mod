using System.Text.Json;

namespace DefensiveSourceScan;

internal static class Program
{
    private static int Main(string[] args)
    {
        ScanOptions options;
        try
        {
            options = ScanOptions.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine($"Error: {ex.Message}");
            Console.Error.WriteLine(ScanOptions.Usage);
            return 2;
        }

        if (options.ShowHelp)
        {
            Console.WriteLine(ScanOptions.Usage);
            return 0;
        }

        if (options.Paths.Count == 0)
        {
            Console.Error.WriteLine("Error: specify at least one source file or directory.");
            Console.Error.WriteLine(ScanOptions.Usage);
            return 2;
        }

        var scanner = new SourceScanner(options);
        ScanReport report = scanner.Run();

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(report, new JsonSerializerOptions
            {
                WriteIndented = true
            }));
        }
        else
        {
            foreach (Finding finding in report.Findings)
            {
                Console.WriteLine($"{finding.Path}:{finding.Line}: [{finding.Category}] " +
                                  $"{finding.Description} ({finding.Indicator}): {finding.Snippet}");
            }

            foreach (string error in report.Errors)
            {
                Console.Error.WriteLine($"Error: {error}");
            }

            Console.WriteLine($"Scanned {report.FilesScanned} file(s); " +
                              $"found {report.Findings.Count} indicator(s); " +
                              $"{report.Errors.Count} error(s).");
        }

        // Exit codes: 0 = no indicators, 1 = indicators found, 2 = scan errors.
        if (report.Errors.Count > 0)
        {
            return 2;
        }

        return report.Findings.Count > 0 ? 1 : 0;
    }
}
