using Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);

// API jako projekt .NET
var api = builder.AddProject<Projects.Api>("api");

// Kontener z Python FastAPI (cleaner_service)
var cleaner = builder.AddContainer("python-cleaner", "python:3.11")
    .WithHttpEndpoint(targetPort: 8000, name: "http")
    .WithBindMount(Path.GetFullPath("../../python/cleaner_service"), "/app")
    .WithWorkingDirectory("/app")
    .WithEntrypoint(["bash", "-lc", "pip install -r requirements.txt && uvicorn main:app --host 0.0.0.0 --port 8000"]);

// API musi znać URL cleanera
api.WithEnvironment("CLEANER_SERVICE_URL", cleaner.GetEndpoint("http")!.Url);

// Przekaż zmienne Azure OpenAI do API (jeśli ustawione lokalnie)
foreach (var key in new[] { "AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_DEPLOYMENT_GPT5" })
{
    var val = Environment.GetEnvironmentVariable(key);
    if (!string.IsNullOrWhiteSpace(val))
        api.WithEnvironment(key, val);
}

builder.Build().Run();
