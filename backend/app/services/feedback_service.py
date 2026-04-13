import base64
import json

import anthropic

from app.core.config import settings

client = anthropic.AsyncAnthropic(api_key=settings.ANTHROPIC_API_KEY)

SYSTEM_PROMPT = (
    "You are a foreign language learning assistant. "
    "The user submits handwritten notes as images. "
    "Recognize the handwriting and provide structured feedback.\n"
    "Respond ONLY with valid JSON in this format:\n"
    '{"recognized_text":"...","corrections":[{"position":1,"original":"...","corrected":"...","reason":"..."}],"summary":"..."}\n'
    "Keep corrections concise. Write summary in Korean."
)


def _select_model(task_type: str) -> str:
    """작업 복잡도에 따라 모델을 선택한다."""
    if task_type == "simple":
        return "claude-haiku-4-5-20251001"
    return "claude-sonnet-4-6-20250514"


async def get_feedback(
    image_bytes: bytes,
    language: str = "en",
    textbook_context: str | None = None,
    previous_context: str | None = None,
    task_type: str = "complex",
) -> dict:
    """캔버스 이미지를 Claude Vision API에 전송하여 피드백을 받는다."""
    image_b64 = base64.b64encode(image_bytes).decode("utf-8")

    user_content = []

    # 이미지 (캔버스 캡처)
    user_content.append({
        "type": "image",
        "source": {
            "type": "base64",
            "media_type": "image/png",
            "data": image_b64,
        },
    })

    # 텍스트 프롬프트 구성
    prompt_parts = [f"Language: {language}."]

    if textbook_context:
        prompt_parts.append(f"Textbook reference:\n{textbook_context}")

    if previous_context:
        prompt_parts.append(f"Previous context: {previous_context}")

    prompt_parts.append("Read the handwriting in the image and provide feedback as JSON.")

    user_content.append({"type": "text", "text": "\n".join(prompt_parts)})

    response = await client.messages.create(
        model=_select_model(task_type),
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_content}],
    )

    raw_text = response.content[0].text.strip()

    # JSON 블록 추출 (```json ... ``` 감싸진 경우 대응)
    if raw_text.startswith("```"):
        lines = raw_text.split("\n")
        raw_text = "\n".join(lines[1:-1])

    return json.loads(raw_text)
