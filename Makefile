ICED=node_modules/.bin/iced
BUILD_STAMP=build-stamp
TEST_STAMP=test-stamp
WD=`pwd`
BROWSERIFY=node_modules/.bin/browserify
BROWSER=browser/blockchain.js

default: build
all: build

lib/%.js: src/%.iced
	$(ICED) -I browserify -c -o `dirname $@` $<

$(BUILD_STAMP): \
	lib/base.js \
	lib/cmd.js \
	lib/browser.js
	date > $@

$(BROWSER): lib/browser.js
	$(BROWSERIFY) -s blockchain $< > $@

browser: $(BROWSER)

build: $(BUILD_STAMP) 

clean:
	rm -rf lib/* $(BUILD_STAMP) $(TEST_STAMP)

test:
	$(ICED) test/run.iced

setup:
	npm install -d

.PHONY: clean setup test test-browser browser
