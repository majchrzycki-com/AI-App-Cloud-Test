# AI-App-Cloud-Test — Streszczacz Notatek/Transkryptów

Stack:
- Backend: .NET 9, Microsoft Aspire (AppHost), Microsoft Orleans (Job Grain), Semantic Kernel (pipeline), Azure OpenAI (gpt-5)
- Python: FastAPI mikroserwis do czyszczenia i segmentacji tekstu
- Frontend: Next.js (App Router), TailwindCSS, Radix UI
- Styl pracy: monorepo

## Architektura (MVP)
- apps/web — frontend (formularz wklejenia/uploadu, wynik streszczenia, polling statusu joba)
- src/Api — minimal API:
  - POST /api/summary/start — uruchamia job streszczenia, zwraca jobId
  - GET /api/summary/status/{jobId} — zwraca status i wynik (summary/decisions/actionItems/risks)
  - Orkiestracja: Python cleaner → SK pipeline → zapis w Orleans Grain
- python/cleaner_service — POST /clean (oczyszcza tekst, sekcje, detekcja języka)
- src/AppHost — Microsoft Aspire uruchamia całość (API + kontener dla Python)

## Wymagane narzędzia
- .NET 9 SDK
- Node.js 20+
- Python 3.11+
- Docker Desktop
- Azure OpenAI (wdrożenie modelu gpt-5, embeddings opcjonalnie)

## Zmienne środowiskowe
Ustaw lokalnie (przykład dla API):
- AZURE_OPENAI_ENDPOINT
- AZURE_OPENAI_API_KEY
- AZURE_OPENAI_DEPLOYMENT_GPT5
- CLEANER_SERVICE_URL (np. http://localhost:8000)

Frontend:
- NEXT_PUBLIC_API_BASE_URL (np. http://localhost:5299)

## Szybki start (lokalnie)
1) Python cleaner
   ```bash
   cd python/cleaner_service
   python -m venv .venv && source .venv/bin/activate # Windows: .venv\Scripts\activate
   pip install -r requirements.txt
   uvicorn main:app --host 0.0.0.0 --port 8000
   ```
2) API
   ```bash
   cd src/Api
   dotnet restore
   # Ustaw zmienne środowiskowe (patrz wyżej)
   dotnet run
   # Domyślnie: http://localhost:5299
   ```
3) Frontend
   ```bash
   cd apps/web
   npm i
   # stwórz plik .env.local na bazie .env.local.example
   npm run dev
   # http://localhost:3000
   ```

Alternatywnie — Microsoft Aspire (AppHost) uruchamia całość (API + kontener Pythona):
```bash
cd src/AppHost
dotnet run
```
Uwaga: wymagany Docker (AppHost zbuduje i uruchomi kontener cleaner_service).

## Przepływ
- Frontend POST do /api/summary/start z tekstem → jobId
- Frontend polluje /api/summary/status/{jobId} aż status = done → render wyników
- API: dzwoni do Python /clean → SK pipeline (summary → decisions → actionItems → risks)

## TODO po MVP
- Upload plików (PDF/MD/TXT)
- Retry i reminders w Orleans (ponawianie niedokończonych jobów)
- Logowanie/telemetria w Aspire (OpenTelemetry)
- Testy jednostkowe pipeline’u
