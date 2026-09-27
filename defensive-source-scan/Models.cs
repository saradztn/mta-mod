namespace DefensiveSourceScan;

internal sealed class Finding
{
    public string Path { get; init; } = "";
    public int Line { get; init; }
    public string Category { get; init; } = "";
    public string Description { get; init; } = "";
    public string Indicator { get; init; } = "";
    public string Snippet { get; init; } = "";
}

internal sealed class ScanReport
{
    public int FilesScanned { get; set; }
    public List<Finding> Findings { get; } = new();
    public List<string> Errors { get; } = new();
}
