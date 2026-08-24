.PHONY: build test app install lint clean

build:
	swift build

test:
	./run-tests.sh

app:
	./Scripts/build-app.sh release

install:
	./Scripts/install.sh

clean:
	rm -rf .build dist
