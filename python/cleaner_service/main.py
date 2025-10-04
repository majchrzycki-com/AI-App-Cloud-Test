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
