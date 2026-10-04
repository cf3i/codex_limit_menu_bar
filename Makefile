.PHONY: build test app dmg clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh release

dmg:
	./scripts/build-dmg.sh

clean:
	swift package clean
	rm -rf dist
