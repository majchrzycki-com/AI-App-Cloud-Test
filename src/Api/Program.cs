using System.Net.Http.Json;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using Microsoft.SemanticKernel.Connectors.OpenAI;
using Orleans;
using Orleans.Hosting;

var builder = WebApplication.CreateBuilder(args);

// Orleans (silo in-proc)
builder.Host.UseOrleans(silo =>
{
    silo.UseLocalhostClustering();
    silo.AddMemoryGrainStorageAsDefault();
});

builder.Services.AddHttpClient("cleaner", client =>
{
    var url = Environment.GetEnvironmentVariable("CLEANER_SERVICE_URL") ?? "http://localhost:8000";
    client.BaseAddress = new Uri(url);
});

// Semantic Kernel + Azure OpenAI
builder.Services.AddKernel();
builder.Services.AddSingleton<IChatCompletionService>(sp =>
{
    var endpoint = Environment.GetEnvironmentVariable("AZURE_OPENAI_ENDPOINT") ?? "";
    var deployment = Environment.GetEnvironmentVariable("AZURE_OPENAI_DEPLOYMENT_GPT5") ?? "";
    var key = Environment.GetEnvironmentVariable("AZURE_OPENAI_API_KEY") ?? "";

    return new AzureOpenAIChatCompletionService(
        deploymentName: deployment,
        endpoint: endpoint,
        apiKey: key
    );
});

builder.Services.AddSingleton<SummaryPipeline>();

var app = builder.Build();

app.MapGet("/", () => Results.Ok("API up"));

app.MapPost("/api/summary/start", async (SummaryRequest req, IGrainFactory grains, IHttpClientFactory http, SummaryPipeline pipeline) =>
{
    if (string.IsNullOrWhiteSpace(req.Text))
        return Results.BadRequest(new { error = "Empty text" });

    // 1) Clean via Python
    var client = http.CreateClient("cleaner");
    var cleanResp = await client.PostAsJsonAsync("/clean", new { text = req.Text });
    if (!cleanResp.IsSuccessStatusCode)
        return Results.Problem("Cleaner service error", statusCode: 502);

    var clean = await cleanResp.Content.ReadFromJsonAsync<CleanerResponse>() ?? new();

    // 2) Create job and start
    var jobId = Guid.NewGuid().ToString("N");
    var job = grains.GetGrain<INoteSummaryJobGrain>(jobId);
    await job.StartJob(new NoteSummaryJobInput
    {
        OriginalText = req.Text,
        CleanedText = clean.cleaned_text ?? req.Text,
        Sections = clean.sections ?? Array.Empty<string>(),
        DetectedLanguage = clean.detected_language ?? "unknown"
    });

    return Results.Ok(new { jobId });
});

app.MapGet("/api/summary/status/{jobId}", async (string jobId, IGrainFactory grains) =>
{
    var job = grains.GetGrain<INoteSummaryJobGrain>(jobId);
    var status = await job.GetStatus();
    return Results.Ok(status);
});

app.Run();

record SummaryRequest(string Text);

record CleanerResponse(string? cleaned_text, string[]? sections, string? detected_language);

// Orleans abstractions
public interface INoteSummaryJobGrain : IGrainWithStringKey
{
    Task StartJob(NoteSummaryJobInput input);
    Task<NoteSummaryJobStatus> GetStatus();
}

[GenerateSerializer]
public record NoteSummaryJobInput
{
    [Id(0)] public string OriginalText { get; init; } = "";
    [Id(1)] public string CleanedText { get; init; } = "";
    [Id(2)] public string[] Sections { get; init; } = Array.Empty<string>();
    [Id(3)] public string DetectedLanguage { get; init; } = "unknown";
}

public enum JobState { Queued, Running, Done, Error }

[GenerateSerializer]
public record NoteSummaryResult
{
    [Id(0)] public string Summary { get; init; } = "";
    [Id(1)] public string[] Decisions { get; init; } = Array.Empty<string>();
    [Id(2)] public string[] ActionItems { get; init; } = Array.Empty<string>();
    [Id(3)] public string[] Risks { get; init; } = Array.Empty<string>();
}

[GenerateSerializer]
public record NoteSummaryJobStatus
{
    [Id(0)] public JobState State { get; init; } = JobState.Queued;
    [Id(1)] public NoteSummaryResult? Result { get; init; }
    [Id(2)] public string? Error { get; init; }
    [Id(3)] public DateTimeOffset? StartedAt { get; init; }
    [Id(4)] public DateTimeOffset? CompletedAt { get; init; }
}

public class NoteSummaryJobGrain : Grain, INoteSummaryJobGrain
{
    private readonly SummaryPipeline _pipeline;
    private NoteSummaryJobStatus _status = new() { State = JobState.Queued };

    public NoteSummaryJobGrain(SummaryPipeline pipeline) => _pipeline = pipeline;

    public async Task StartJob(NoteSummaryJobInput input)
    {
        if (_status.State is JobState.Running or JobState.Done) return;

        _status = _status with { State = JobState.Running, StartedAt = DateTimeOffset.UtcNow };

        try
        {
            var result = await _pipeline.RunAsync(input.CleanedText);
            _status = _status with
            {
                State = JobState.Done,
                Result = result,
                CompletedAt = DateTimeOffset.UtcNow
            };
        }
        catch (Exception ex)
        {
            _status = _status with { State = JobState.Error, Error = ex.Message, CompletedAt = DateTimeOffset.UtcNow };
        }
    }

    public Task<NoteSummaryJobStatus> GetStatus() => Task.FromResult(_status);
}

// SK pipeline
public class SummaryPipeline
{
    private readonly IChatCompletionService _chat;

    public SummaryPipeline(IChatCompletionService chat) => _chat = chat;

    public async Task<NoteSummaryResult> RunAsync(string text)
    {
        var sys = """
        You are an assistant that extracts structured meeting outcomes. 
        Always return strict JSON in this schema:
        {
          "summary": "string",
          "decisions": ["string", "..."],
          "actionItems": ["string", "..."],
          "risks": ["string", "..."]
        }
        """;

        var user = $$"""
        Input text:
        {{text}}

        Task:
        1) Provide a concise summary (<= 7 bullet points).
        2) Extract clear decisions (if none, return []).
        3) Extract actionable action items starting with a verb, include owner if present.
        4) Extract risks or unknowns (if none, return []).
        """;

        var history = new ChatHistory();
        history.AddSystemMessage(sys);
        history.AddUserMessage(user);

        var res = await _chat.GetChatMessageContentAsync(history);

        var json = res.Content?.Trim() ?? "{}";
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            return new NoteSummaryResult
            {
                Summary = root.GetPropertyOrDefault("summary", ""),
                Decisions = root.GetPropertyArray("decisions"),
                ActionItems = root.GetPropertyArray("actionItems"),
                Risks = root.GetPropertyArray("risks"),
            };
    }
        catch
        {
            return new NoteSummaryResult
            {
                Summary = json,
                Decisions = Array.Empty<string>(),
                ActionItems = Array.Empty<string>(),
                Risks = Array.Empty<string>()
            };
        }
    }
}

static class JsonExt
{
    public static string GetPropertyOrDefault(this System.Text.Json.JsonElement el, string name, string def)
        => el.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() ?? def : def;

    public static string[] GetPropertyArray(this System.Text.Json.JsonElement el, string name)
    {
        if (el.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.Array)
        {
            var list = new List<string>();
            foreach (var i in v.EnumerateArray())
                if (i.ValueKind == System.Text.Json.JsonValueKind.String) list.Add(i.GetString() ?? "");
            return list.ToArray();
        }
        return Array.Empty<string>();
    }
}
