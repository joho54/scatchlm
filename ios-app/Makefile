DEVICE_ID := 00008103-000C65D43AEB001E
SIM_ID := E9FA98C5-3953-4CAF-9076-81000B685E2F
SCHEME := ScatchLM
PROJECT := ScatchLM.xcodeproj
# mtime 기준 가장 최근 build만 — 옛 DerivedData가 남아있어도 안전.
# `=` (지연 평가)로 install 시점에 평가되도록.
APP_PATH = $(shell ls -td $(HOME)/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Release-iphoneos/ScatchLM.app 2>/dev/null | head -1)
SIM_APP_PATH = $(shell ls -td $(HOME)/Library/Developer/Xcode/DerivedData/ScatchLM-*/Build/Products/Debug-iphonesimulator/ScatchLM.app 2>/dev/null | head -1)
BUNDLE_ID := com.joho54.scatchlm

.PHONY: gen build build-sim install reinstall clean run-sim

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration Release \
	  -destination 'id=$(DEVICE_ID)' \
	  -allowProvisioningUpdates build

build-sim: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'id=$(SIM_ID)' build

install:
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP_PATH)

# 7일 만료 시 한 줄로 재설치
reinstall: build install

clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/ScatchLM-*

# 시뮬레이터 부팅 → 빌드 → 설치 → 실행
run-sim: build-sim
	@xcrun simctl boot $(SIM_ID) 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted $(SIM_APP_PATH)
	xcrun simctl launch booted $(BUNDLE_ID)
