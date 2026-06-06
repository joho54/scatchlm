DEVICE_ID := 00008103-000C65D43AEB001E
# iPhone 컴패니언 실기기. 연결돼 있으면 UDID를 자동 감지한다(연결된 첫 iPhone).
# 고정하려면 override: `make reinstall-iphone IPHONE_ID=00008XXX-XXXXXXXXXXXXXXXX`
# 확인: `make iphone-id` (연결+잠금해제+신뢰 후).
IPHONE_ID ?= $(shell xcrun xctrace list devices 2>/dev/null | grep -i 'iPhone' | grep -v 'Simulator' | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1)
SIM_ID := E9FA98C5-3953-4CAF-9076-81000B685E2F
SCHEME := ScatchLM
PROJECT := ScatchLM.xcodeproj
# mtime 기준 가장 최근 build만 — 옛 DerivedData가 남아있어도 안전.
# `=` (지연 평가)로 install 시점에 평가되도록.
APP_PATH = $(shell ls -td $(HOME)/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Release-iphoneos/ScatchLM.app 2>/dev/null | head -1)
DEV_APP_PATH = $(shell ls -td $(HOME)/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Debug-iphoneos/ScatchLM.app 2>/dev/null | head -1)
SIM_APP_PATH = $(shell ls -td $(HOME)/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Debug-iphonesimulator/ScatchLM.app 2>/dev/null | head -1)
BUNDLE_ID := com.joho54.scatchlm

.PHONY: gen build build-dev build-sim build-iphone install install-dev install-iphone reinstall reinstall-dev reinstall-iphone iphone-id clean run-sim

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Release \
	  -destination 'id=$(DEVICE_ID)' \
	  -allowProvisioningUpdates build

# 실기기 Debug 빌드 — 로컬 개발용. Release와 달리 #if DEBUG가 켜져 debug 로그(canvas/indicator 등)가
# 콘솔·백엔드로 흐른다. 대신 -Onone이라 per-stroke 로직 성능은 Release보다 떨어질 수 있음.
build-dev: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Debug \
	  -destination 'id=$(DEVICE_ID)' \
	  -allowProvisioningUpdates build

build-sim: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'id=$(SIM_ID)' build

# iPhone 실기기 Release 빌드 — `build`와 동일 설정, 기기만 IPHONE_ID.
build-iphone: gen
	@test -n "$(IPHONE_ID)" || { echo "✗ iPhone 미인식 — 연결·잠금해제·신뢰 후 'make iphone-id'로 확인하세요."; exit 1; }
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Release \
	  -destination 'id=$(IPHONE_ID)' \
	  -allowProvisioningUpdates build

install:
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP_PATH)

install-dev:
	xcrun devicectl device install app --device $(DEVICE_ID) $(DEV_APP_PATH)

install-iphone:
	@test -n "$(IPHONE_ID)" || { echo "✗ iPhone 미인식 — 연결·잠금해제·신뢰 후 'make iphone-id'로 확인하세요."; exit 1; }
	xcrun devicectl device install app --device $(IPHONE_ID) $(APP_PATH)

# 7일 만료 시 한 줄로 재설치 (Release — 성능/출시 parity)
reinstall: build install

# 로컬 개발용 재설치 (Debug — debug 로그 관측). 실기기에서 렌더 로그 보고 싶을 때.
reinstall-dev: build-dev install-dev

# iPhone 컴패니언 실기기 재설치 (Release — reinstall과 동일, 기기만 아이폰).
reinstall-iphone: build-iphone install-iphone

# 연결된 iPhone UDID 출력 — IPHONE_ID 고정값 확인용.
iphone-id:
	@echo "감지된 iPhone UDID: $(IPHONE_ID)"
	@test -n "$(IPHONE_ID)" || echo "(없음 — iPhone을 USB 연결하고 잠금해제·'이 컴퓨터를 신뢰'를 누르세요)"

clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/ScatchLM-*

# 시뮬레이터 부팅 → 빌드 → 설치 → 실행
run-sim: build-sim
	@xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted $(SIM_APP_PATH)
	xcrun simctl launch booted $(BUNDLE_ID)
