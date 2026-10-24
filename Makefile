.PHONY: test lint

test:
	bats test/

lint:
	shellcheck -x -P hooks hooks/pre-receive hooks/post-receive hooks/stargate-lib.sh scripts/*.sh test/helpers.bash
