import json, base64, urllib.request

with open("/home/drh/Pictures/screenshot-2026-06-10_17-11-57.png", "rb") as f:
    img = base64.b64encode(f.read()).decode()

payload = {
    "model": "gemma3:12b",
    "system": "You are a JSON extraction API. You receive alcohol label images and return structured JSON only. Your response must begin with { and end with }. Do not use markdown. Do not use code fences.",
    "prompt": "Extract these fields from the label. Return null for missing fields. Normalize all whitespace to single spaces.\n\n{\"brand_name\": null, \"class_type\": null, \"abv\": null, \"net_contents\": null, \"producer\": null, \"country_of_origin\": null, \"government_warning\": null}",
    "stream": False,
    "num_predict": 400,
    "temperature": 0,
    "images": [img]
}

req = urllib.request.Request(
    "http://localhost:11434/api/generate",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"}
)

with urllib.request.urlopen(req) as res:
    body = json.load(res)
    print(body["response"])
