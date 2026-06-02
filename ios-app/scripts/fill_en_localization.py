#!/usr/bin/env python3
"""String Catalog English 컬럼 채우기 (eng-localization-infra-spec 트리거 작업).

한국어 소스 키에 대한 자연스러운 앱 영어 번역을 en 로컬라이제이션으로 주입한다.
이미 영어이거나 포맷/기호뿐인 키(예: "Sign In", "%lld", "or")는 en 로케일에서
키 그대로 렌더되므로 건드리지 않는다. 포맷 지정자(%@, %lld)는 그대로 보존.
"""
import json
import sys

CATALOG = "ScatchLM/Resources/Localizable.xcstrings"

# 한국어 소스 키 → 영어 번역 (포맷 지정자 보존)
EN = {
    "%@ / 월 구독하기": "%@ / month",
    "%@ 로 보낸 코드를 입력하세요. 코드가 안 보이면 스팸함도 확인해 주세요.":
        "Enter the code sent to %@. If you don't see it, check your spam folder.",
    "6자리 코드": "6-digit code",
    "AI 피드백이 이 언어로 작성됩니다.": "AI feedback will be written in this language.",
    "Pro 구독하기": "Subscribe to Pro",
    "p.%lld 가이드": "p.%lld guide",
    "⚠️ 자주 하는 실수": "⚠️ Common mistakes",
    "가이드": "Guide",
    "가이드를 불러올 수 없습니다.": "Couldn't load the guide.",
    "가입에 사용한 이메일로 6자리 재설정 코드를 보내드려요.":
        "We'll send a 6-digit reset code to the email you signed up with.",
    "개인정보 처리방침": "Privacy Policy",
    "검색 결과가 없어요": "No results",
    "계정 삭제": "Delete account",
    "계정과 모든 데이터(노트·피드백·교재)가 영구히 삭제됩니다. 되돌릴 수 없어요.":
        "Your account and all data (notes, feedback, textbooks) will be permanently deleted. This can't be undone.",
    "계정과 모든 데이터가 영구히 삭제됩니다. 이 작업은 되돌릴 수 없어요.":
        "Your account and all data will be permanently deleted. This action can't be undone.",
    "계정을 삭제하지 못했어요. 잠시 후 다시 시도해 주세요.":
        "Couldn't delete your account. Please try again in a moment.",
    "계정을 삭제할까요?": "Delete account?",
    "구독": "Subscription",
    "구독 검증에 실패했어요.": "Subscription verification failed.",
    "구독 관리": "Manage subscription",
    "구독은 월 단위로 자동 갱신되며, 현재 기간 종료 24시간 이전에 해지하지 않으면 갱신됩니다. 구매 후 Apple ID 설정에서 관리·해지할 수 있어요.":
        "Your subscription renews monthly and will renew unless you cancel at least 24 hours before the end of the current period. After purchase, you can manage or cancel it anytime in your Apple ID settings.",
    "구독이 복원되었어요.": "Your subscription has been restored.",
    "구독하기": "Subscribe",
    "구매 복원": "Restore purchases",
    "구매 승인 대기 중이에요. 승인되면 자동으로 적용돼요.":
        "Your purchase is awaiting approval. It will be applied automatically once approved.",
    "기타": "Other",
    "너무 김": "Too long",
    "너무 짧음": "Too short",
    "넉넉한 일일 AI 피드백 한도": "A generous daily AI feedback limit",
    "다른 검색어를 입력해 보세요.": "Try a different search term.",
    "닫기": "Close",
    "답변을 받지 못했어요. 잠시 후 다시 시도해 주세요.":
        "Couldn't get a response. Please try again in a moment.",
    "대화": "Chat",
    "도움 안 됨": "Not helpful",
    "동기화": "Sync",
    "되돌리기": "Undo",
    "로그인이 만료되었어요. 다시 로그인해 주세요.": "Your session has expired. Please sign in again.",
    "로그인이 필요해요.": "You need to sign in.",
    "메시지를 저장하지 못했어요.": "Couldn't save the message.",
    "목차": "Contents",
    "무료": "Free",
    "버전": "Version",
    "복원 중…": "Restoring…",
    "복원할 구독을 찾지 못했어요.": "No subscription to restore was found.",
    "비밀번호 변경": "Change password",
    "비밀번호 재설정": "Reset password",
    "비밀번호를 잊으셨나요?": "Forgot your password?",
    "사실 오류": "Factual error",
    "사유 (복수 선택)": "Reasons (select all that apply)",
    "삭제 중…": "Deleting…",
    "상품을 불러오지 못했어요. 잠시 후 다시 시도해 주세요.":
        "Couldn't load the product. Please try again in a moment.",
    "새 비밀번호 (6자 이상)": "New password (6+ characters)",
    "서버에 일시적인 문제가 생겼어요. 잠시 후 다시 시도해 주세요.":
        "A temporary server problem occurred. Please try again in a moment.",
    "손글씨 인식 · 교재 기반 RAG 채팅": "Handwriting recognition · textbook-based RAG chat",
    "수식 렌더링": "Math rendering",
    "수식 보기": "Show math",
    "수식 안 보기": "Hide math",
    "스크랩": "Pin",
    "아직 노트가 없어요": "No notes yet",
    "알림": "Notice",
    "약관 및 정책": "Terms & Policies",
    "어조 부적절": "Inappropriate tone",
    "언어 오류": "Language error",
    "오늘 무료 사용량을 모두 사용했어요. Pro로 업그레이드하면 더 많은 피드백을 받을 수 있어요.":
        "You've used all of today's free quota. Upgrade to Pro to get more feedback.",
    "오늘 사용량을 모두 사용했어요. 내일 다시 시도해 주세요.":
        "You've used all of today's quota. Please try again tomorrow.",
    "오른쪽 위 + 버튼을 눌러 첫 노트를 만들어 보세요.":
        "Tap the + button in the top right to create your first note.",
    "요약": "Summary",
    "요청을 처리하지 못했어요. 잠시 후 다시 시도해 주세요.":
        "Couldn't process your request. Please try again in a moment.",
    "요청한 항목을 찾을 수 없어요.": "The requested item couldn't be found.",
    "월 자동 갱신 · 언제든 해지": "Auto-renews monthly · cancel anytime",
    "이 영역은 피드백이 완료됐습니다. 되돌리려면 카드의 ↩︎를 누르세요":
        "Feedback is complete for this area. Tap ↩︎ on the card to undo.",
    "이 작업을 수행할 권한이 없어요.": "You don't have permission to do this.",
    "이 피드백을 되돌리시겠습니까?": "Undo this feedback?",
    "이용약관": "Terms of Service",
    "자동": "Auto",
    "자동: 수식이 있으면 KaTeX로 렌더. 수식 안 보기는 가볍게 텍스트만 표시합니다.":
        "Auto: renders with KaTeX when math is present. Hide math shows text only, more lightly.",
    "자세히": "Details",
    "재설정 코드 받기": "Get reset code",
    "제출": "Submit",
    "질문을 입력하세요...": "Enter your question...",
    "질문하기...": "Ask a question...",
    "챕터 가이드": "Chapter guide",
    "챕터 가이드를 불러올 수 없습니다.": "Couldn't load the chapter guide.",
    "취소": "Cancel",
    "카드가 사라지고 해당 영역에 다시 필기할 수 있게 됩니다. 필기 자체는 남습니다.":
        "The card disappears and you can write in that area again. Your handwriting itself stays.",
    "코드 다시 받기": "Resend code",
    "코드가 올바르지 않거나 만료됐어요. 다시 시도해 주세요.":
        "The code is incorrect or expired. Please try again.",
    "코드를 보냈어요. 이메일을 확인해 주세요.": "Code sent. Please check your email.",
    "코멘트 (선택)": "Comment (optional)",
    "파일이 너무 커요. 더 작은 파일을 사용해 주세요.": "The file is too large. Please use a smaller file.",
    "페이지": "Page",
    "평가": "Rating",
    "피드백 대화": "Feedback chat",
    "피드백 평가": "Rate feedback",
    "피드백을 받지 못했어요. 잠시 후 다시 시도해 주세요.":
        "Couldn't get feedback. Please try again in a moment.",
    "피드백을 삭제하지 못했어요.": "Couldn't delete the feedback.",
    "피드백을 저장하지 못했어요.": "Couldn't save the feedback.",
    "필기를 저장하지 못했어요. 네트워크/저장 공간을 확인해 주세요.":
        "Couldn't save your handwriting. Check your network and storage.",
    "현재 플랜": "Current plan",
    "확인": "OK",
    "👍 좋음": "👍 Good",
    "👎 아쉬움": "👎 Needs work",
    "📋 학습 순서": "📋 Study order",
    "📌 핵심 개념": "📌 Key concepts",
    # 노트 생성/편집 모달 — 영어 소스로 작성돼 있던 것을 한국어 소스로 정정 후 영어 번역
    "제목": "Title",
    "제목 없음": "Untitled note",
    "주제": "Subject",
    "예: 일본어, 물리학, 세계사": "e.g. Japanese, Physics, World History",
    "교재 (선택)": "Textbook (optional)",
    "교재": "Textbook",
    "새 노트": "New Note",
    "노트 편집": "Edit Note",
    "만들기": "Create",
    "저장": "Save",
    "업로드 중…": "Uploading…",
    "새 PDF 업로드": "Upload new PDF",
    "%lld페이지": "%lld pages",
    # 로그인/홈/설정 — 영어 소스로 작성돼 있던 것을 한국어 소스로 정정 후 영어 번역
    "손글씨로 배우는 언어 학습": "Handwriting-based language learning",
    "이메일": "Email",
    "비밀번호": "Password",
    "로그인": "Sign In",
    "회원가입": "Sign Up",
    "이미 계정이 있으신가요? 로그인": "Already have an account? Sign In",
    "계정이 없으신가요? 회원가입": "Don't have an account? Sign Up",
    "또는": "or",
    "Google로 계속하기": "Continue with Google",
    "Apple로 로그인": "Sign in with Apple",
    "필기 분석 중…": "Analyzing handwriting…",
    "편집": "Edit",
    "삭제": "Delete",
    "노트": "Notes",
    "노트 검색": "Search notes",
    "피드백 언어": "Feedback Language",
    "예: 한국어, English, 日本語": "e.g. Korean, English, 日本語",
    "로그아웃": "Sign Out",
    "설정": "Settings",
    "완료": "Done",
    "불러오는 중…": "Loading…",
}


def main():
    with open(CATALOG, encoding="utf-8") as f:
        data = json.load(f)

    strings = data["strings"]
    added, missing_in_catalog = 0, []
    for ko_key, en_val in EN.items():
        if ko_key not in strings:
            missing_in_catalog.append(ko_key)
            continue
        entry = strings[ko_key]
        loc = entry.setdefault("localizations", {})
        loc["en"] = {"stringUnit": {"state": "translated", "value": en_val}}
        added += 1

    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"en translations injected: {added}")
    if missing_in_catalog:
        print("WARNING — keys in EN map not found in catalog:")
        for k in missing_in_catalog:
            print("  ", repr(k))

    # 미번역 한국어 키(영어 컬럼 누락) 점검 → 누락 0이어야 함
    import re
    untranslated = [
        k for k in strings
        if re.search(r"[가-힣]", k)
        and "en" not in strings[k].get("localizations", {})
    ]
    if untranslated:
        print(f"WARNING — {len(untranslated)} Korean keys still without en:")
        for k in untranslated:
            print("  ", repr(k))
    else:
        print("OK — every Korean key now has an en translation.")


if __name__ == "__main__":
    sys.exit(main())
