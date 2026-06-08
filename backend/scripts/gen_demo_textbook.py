"""온보딩 데모 교재 PDF 생성기 (가이드된 첫 성공 spec / Track C).

자작 2쪽, 텍스트 레이어 포함(스캔본 아님 — 백엔드 챕터 텍스트 추출용), 저작권 안전.
페이지 내용 ↔ "써보세요" 프롬프트 ↔ 기대 피드백을 한 세트로 설계한다(spec §4.5):
  - p.1 기초 단어: 한국어 단어 → 영어 빈칸 (사과/책/물)
  - p.2 짧은 문장: 빈칸 채우기 (am/goes)
사용자는 빈칸에 손글씨로 답을 쓰고, 그 교재 기준으로 AI 피드백을 받는다.

산출물을 두 곳에 동일 파일로 저장:
  - backend/app/assets/demo-template.pdf  (백엔드 텍스트 추출용 복사 원본)
  - ios-app/ScatchLM/Resources/demo-template.pdf  (앱 번들 표시용)

재생성: cd backend && source venv/bin/activate && python scripts/gen_demo_textbook.py
"""
import os

import fitz  # PyMuPDF

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND_ROOT = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(BACKEND_ROOT)

OUT_BACKEND = os.path.join(BACKEND_ROOT, "app", "assets", "demo-template.pdf")
OUT_IOS = os.path.join(REPO_ROOT, "ios-app", "ScatchLM", "Resources", "demo-template.pdf")

# 세로 학습지. korea CJK 폰트의 Latin advance가 넓어 좁은 페이지에선 우측 클리핑되므로
# 넉넉한 폭을 준다. 좌표는 pt(72dpi).
PAGE_W, PAGE_H = 540.0, 720.0


# 한국어 글리프는 Helvetica에 없어 점(··)으로 깨진다 → PyMuPDF 내장 CJK 폰트 "korea"
# (Latin 글리프도 포함)로 모든 텍스트를 그린다. 텍스트 레이어에 한국어가 정상 추출돼야
# 백엔드가 "사과/책/물을 영어로" 라는 의도를 LLM 컨텍스트로 줄 수 있다.
KFONT = "korea"


def _page1(page: fitz.Page) -> None:
    page.insert_text((48, 70), "ScatchLM Demo Workbook", fontsize=16, fontname=KFONT)
    page.insert_text((48, 96), "Lesson 1 - Everyday Words", fontsize=14, fontname=KFONT)
    page.insert_text(
        (48, 128),
        "다음 한국어 단어를 영어로 번역해 빈칸에 손글씨로 써보세요.\nTranslate each Korean word into English. Write by hand.",
        fontsize=10,
        fontname=KFONT,
    )
    # 정답(영어)은 인쇄하지 않는다 — 사용자가 직접 쓰는 연습. 텍스트 레이어엔 한국어만.
    items = ["1.  사과  →", "2.  책    →", "3.  물    →"]
    y = 200
    for prompt in items:
        page.insert_text((56, y), prompt, fontsize=13, fontname=KFONT)
        page.insert_text((200, y), "_______________", fontsize=13, fontname=KFONT)
        y += 56
    page.insert_text(
        (48, PAGE_H - 48), "Page 1 of 2 - Beginner English",
        fontsize=9, fontname=KFONT, color=(0.5, 0.5, 0.5),
    )


def _page2(page: fitz.Page) -> None:
    page.insert_text((48, 70), "ScatchLM Demo Workbook", fontsize=16, fontname=KFONT)
    page.insert_text((48, 96), "Lesson 2 - Simple Sentences", fontsize=14, fontname=KFONT)
    page.insert_text(
        (48, 128),
        "빈칸에 알맞은 단어를 골라 손글씨로 문장을 완성하세요.\nComplete each sentence by writing the missing word.",
        fontsize=10,
        fontname=KFONT,
    )
    items = [
        ("1.  I ____ a student.", "(am / is / are)"),
        ("2.  She ____ to school.", "(go / goes)"),
        ("3.  We ____ books.", "(read / reads)"),
    ]
    y = 200
    for prompt, hint in items:
        page.insert_text((56, y), prompt, fontsize=13, fontname=KFONT)
        page.insert_text((230, y), hint, fontsize=10, fontname=KFONT, color=(0.5, 0.5, 0.5))
        y += 56
    page.insert_text(
        (48, PAGE_H - 48), "Page 2 of 2 - Beginner English",
        fontsize=9, fontname=KFONT, color=(0.5, 0.5, 0.5),
    )


def main() -> None:
    doc = fitz.open()
    _page1(doc.new_page(width=PAGE_W, height=PAGE_H))
    _page2(doc.new_page(width=PAGE_W, height=PAGE_H))

    for out in (OUT_BACKEND, OUT_IOS):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        doc.save(out, deflate=True)
        print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    doc.close()


if __name__ == "__main__":
    main()
