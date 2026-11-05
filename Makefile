.PHONY: app test run install release

app:
	./scripts/build-app.sh

test:
	swift test

run: app
	open build/PodMouse.app

install: app
	mkdir -p ~/Applications
	rm -rf ~/Applications/PodMouse.app
	cp -R build/PodMouse.app ~/Applications/
	open ~/Applications/PodMouse.app

release:
	./scripts/build-app.sh --universal
	ditto -c -k --keepParent build/PodMouse.app build/PodMouse.zip
