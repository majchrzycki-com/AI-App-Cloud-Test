#!/usr/bin/env bash
set -euo pipefail

# Wymagane: uruchom w katalogu AI-App-Cloud-Test, na gałęzi feat/bootstrap-app
REPO_URL="https://github.com/majchrzycki-com/AI-App-Cloud-Test.git"
BRANCH="feat/bootstrap-app"

echo ">>> Sprawdzam, czy to repo Git i czy jesteś na ${BRANCH}"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Uruchom w katalogu repo"; exit 1; }
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "$BRANCH" ]; then
  echo "Przełączam na ${BRANCH}"
  git fetch origin $BRANCH || true
  git checkout -B $BRANCH origin/$BRANCH || git checkout -B $BRANCH
fi

echo ">>> Tworzę strukturę katalogów"
mkdir -p src/AppHost src/Api apps/web/app python/cleaner_service

echo ">>> Zapisuję pliki"

cat > .gitignore <<'EOF'
# Node
node_modules
.next
out
npm-debug.log*
yarn-debug.log*
yarn-error.log*
.pnpm-debug.log*
.env.local

# Python
__pycache__/
*.pyc
.venv/
.env

# .NET
bin/
obj/
*.user
*.suo
*.userosscache
*.sln.docstates

# OS
.DS_Store
Thumbs.db
EOF

cat > Directory.Build.props <<'EOF'
<Project>
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>preview</LangVersion>
  </PropertyGroup>
</Project>
EOF

cat > src/AppHost/AppHost.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Aspire.Hosting.AppHost" Version="8.0.1" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\Api\Api.csproj" />
  </ItemGroup>
</Project>
EOF

cat > src/AppHost/Program.cs <<'EOF'
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
EOF

cat > src/Api/Api.csproj <<'EOF'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <ItemGroup>
    <PackageReference Include="Microsoft.Orleans.Server" Version="8.1.0" />
    <PackageReference Include="Microsoft.Orleans.Serialization" Version="8.1.0" />
    <PackageReference Include="Microsoft.Orleans.Persistence.AdoNet" Version="8.1.0" />
    <PackageReference Include="Microsoft.Orleans.Persistence.Memory" Version="8.1.0" />
    <PackageReference Include="Microsoft.SemanticKernel" Version="1.23.0" />
    <PackageReference Include="Microsoft.SemanticKernel.Connectors.OpenAI" Version="1.23.0" />
    <PackageReference Include="Azure.Identity" Version="1.11.4" />
  </ItemGroup>
</Project>
EOF

cat > src/Api/appsettings.json <<'EOF'
{
  "AllowedHosts": "*",
  "Kestrel": {
    "Endpoints": {
      "Http": { "Url": "http://0.0.0.0:5299" }
    }
  }
}
EOF

cat > src/Api/Program.cs <<'EOF'
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
EOF

cat > python/cleaner_service/main.py <<'EOF'
from fastapi import FastAPI
from pydantic import BaseModel
from langdetect import detect
import re

app = FastAPI(title="Cleaner Service")

class CleanReq(BaseModel):
    text: str

class CleanResp(BaseModel):
    cleaned_text: str
    sections: list[str]
    detected_language: str

def basic_clean(text: str) -> str:
    t = text.replace("\r\n", "\n")
    t = re.sub(r"[ \t]+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()

def split_sections(text: str) -> list[str]:
    parts = re.split(r"\n\s*\n", text)  # blank-line split
    return [p.strip() for p in parts if p.strip()]

@app.post("/clean", response_model=CleanResp)
def clean(req: CleanReq):
    cleaned = basic_clean(req.text)
    try:
        lang = detect(cleaned) if cleaned else "unknown"
    except:
        lang = "unknown"
    sections = split_sections(cleaned)
    return CleanResp(cleaned_text=cleaned, sections=sections, detected_language=lang)
EOF

cat > python/cleaner_service/requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn==0.30.6
langdetect==1.0.9
EOF

cat > python/cleaner_service/Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > apps/web/package.json <<'EOF'
{
  "name": "ai-app-cloud-test-web",
  "private": true,
  "version": "0.1.0",
  "scripts": {
    "dev": "next dev -p 3000",
    "build": "next build",
    "start": "next start -p 3000",
    "lint": "next lint"
  },
  "dependencies": {
    "next": "14.2.6",
    "react": "18.3.1",
    "react-dom": "18.3.1",
    "@radix-ui/react-card": "1.0.4",
    "@radix-ui/react-label": "2.0.2",
    "tailwindcss": "3.4.10",
    "classnames": "2.5.1"
  },
  "devDependencies": {
    "autoprefixer": "10.4.20",
    "postcss": "8.4.47",
    "typescript": "5.5.4"
  }
}
EOF

cat > apps/web/next.config.mjs <<'EOF'
/** @type {import('next').NextConfig} */
const nextConfig = {};
export default nextConfig;
EOF

cat > apps/web/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "preserve",
    "strict": true,
    "baseUrl": ".",
    "paths": {}
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx"]
}
EOF

cat > apps/web/postcss.config.js <<'EOF'
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
EOF

cat > apps/web/tailwind.config.ts <<'EOF'
import type { Config } from "tailwindcss";
export default {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: { extend: {} },
  plugins: [],
} satisfies Config;
EOF

mkdir -p apps/web/app

cat > apps/web/app/globals.css <<'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;

:root { color-scheme: light dark; }
EOF

cat > apps/web/app/layout.tsx <<'EOF'
export const metadata = { title: "Streszczacz Notatek" };
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="pl">
      <body className="min-h-screen bg-neutral-50 text-neutral-900">{children}</body>
    </html>
  );
}
EOF

cat > apps/web/app/page.tsx <<'EOF'
"use client";
import { useState, useEffect } from "react";

type StartResp = { jobId: string };
type StatusResp = {
  state: "Queued" | "Running" | "Done" | "Error";
  result?: {
    summary: string;
    decisions: string[];
    actionItems: string[];
    risks: string[];
  };
  error?: string;
};

const API = process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://localhost:5299";

export default function Page() {
  const [text, setText] = useState("");
  const [jobId, setJobId] = useState<string | null>(null);
  const [status, setStatus] = useState<StatusResp | null>(null);
  const [loading, setLoading] = useState(false);

  async function start() {
    setLoading(true);
    setStatus(null);
    setJobId(null);
    const resp = await fetch(`${API}/api/summary/start`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    const data: StartResp = await resp.json();
    setJobId(data.jobId);
    setLoading(false);
  }

  useEffect(() => {
    if (!jobId) return;
    const t = setInterval(async () => {
      const r = await fetch(`${API}/api/summary/status/${jobId}`);
      const s: StatusResp = await r.json();
      setStatus(s);
      if (s.state === "Done" || s.state === "Error") clearInterval(t);
    }, 1000);
    return () => clearInterval(t);
  }, [jobId]);

  return (
    <main className="mx-auto max-w-3xl p-6 space-y-6">
      <h1 className="text-2xl font-semibold">Streszczacz Notatek</h1>

      <div className="space-y-2">
        <label className="block text-sm font-medium">Wklej tekst</label>
        <textarea
          className="w-full min-h-[180px] rounded border border-neutral-300 p-3 focus:outline-none focus:ring-2 focus:ring-blue-500"
          value={text}
          onChange={e => setText(e.target.value)}
          placeholder="Wklej notatki lub transkrypt..."
        />
        <button
          onClick={start}
          disabled={loading || text.trim().length < 20}
          className="rounded bg-blue-600 px-4 py-2 text-white disabled:opacity-50"
        >
          {loading ? "Wysyłanie..." : "Streszcz"}
        </button>
      </div>

      {jobId && <p className="text-sm text-neutral-600">jobId: {jobId}</p>}

      {status && (
        <section className="rounded border border-neutral-200 p-4 space-y-3 bg-white">
          <div className="text-sm">
            Status: <span className="font-medium">{status.state}</span>
            {status.error && <span className="text-red-600"> — {status.error}</span>}
          </div>
          {status.result && (
            <>
              <div>
                <h2 className="font-semibold">Podsumowanie</h2>
                <p className="whitespace-pre-wrap">{status.result.summary}</p>
              </div>
              <div>
                <h2 className="font-semibold">Decyzje</h2>
                <ul className="list-disc pl-6">
                  {status.result.decisions.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
              <div>
                <h2 className="font-semibold">Action items</h2>
                <ul className="list-disc pl-6">
                  {status.result.actionItems.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
              <div>
                <h2 className="font-semibold">Ryzyka</h2>
                <ul className="list-disc pl-6">
                  {status.result.risks.map((d, i) => <li key={i}>{d}</li>)}
                </ul>
              </div>
            </>
          )}
        </section>
      )}
    </main>
  );
}
EOF

cat > apps/web/.env.local.example <<'EOF'
NEXT_PUBLIC_API_BASE_URL=http://localhost:5299
EOF

echo ">>> Git add/commit/push"
git add .
git commit -m "feat: bootstrap API (.NET + SK + Orleans), Python cleaner, Next.js web, Aspire AppHost"
git push -u origin $BRANCH

echo ">>> Gotowe. Otwórz PR:"
echo "https://github.com/majchrzycki-com/AI-App-Cloud-Test/compare/main...feat/bootstrap-app?expand=1"
EOF

chmod +x bootstrap.sh

echo
echo "Uruchom skrypt:"
echo "  ./bootstrap.sh"
echo
echo "Po pushu wejdź w link do PR, aby go otworzyć:"
echo "  https://github.com/majchrzycki-com/AI-App-Cloud-Test/compare/main...feat/bootstrap-app?expand=1"
